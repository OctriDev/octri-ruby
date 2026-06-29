# frozen_string_literal: true

# Octri — server-side error monitoring for Ruby backends.
#
# Add it to your live API; it reports backend errors to your Octri monitoring
# project (with original-source context per stack frame) and links each one to
# the client SDK error for the same request via the W3C `traceparent` header —
# so the dashboard shows the full client -> server stack under one trace. It also
# times requests (and any sub-spans you open) into the request waterfall.
#
#   require "octri"
#   require "octri/rack"
#   Octri.init(url: "https://monitoring.example.com", token: ENV["OCTRI_TOKEN"], environment: "<project id>")
#   use Octri::Rack

require "securerandom"
require "net/http"
require "uri"
require "json"
require "time"

module Octri
  Config = Struct.new(:url, :token, :environment, :release)
  Trace = Struct.new(:trace_id, :parent_span_id)

  CONTEXT_LINES = 5
  TRACEPARENT_RE = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}\z/i.freeze

  class << self
    # Configure the reporter. Call once at startup before mounting the middleware.
    def init(url:, token:, environment:, release: nil)
      @config = Config.new(url.sub(%r{/+\z}, ""), token, environment, release)
      @source_cache = {}
      @config
    end

    attr_reader :config

    def new_span_id
      SecureRandom.hex(8)
    end

    # ── Trace context (W3C) ──────────────────────────────────────────────────
    def trace_from_header(traceparent)
      if traceparent && (m = traceparent.to_s.strip.match(TRACEPARENT_RE))
        Trace.new(m[1], m[2])
      else
        Trace.new(SecureRandom.hex(16), nil)
      end
    end

    # ── Sub-span context (thread-local) ───────────────────────────────────────
    def current_span
      Thread.current[:octri_span]
    end

    def set_current_span(trace_id, span_id)
      prev = Thread.current[:octri_span]
      Thread.current[:octri_span] = { trace_id: trace_id, span_id: span_id }
      prev
    end

    def reset_current_span(prev)
      Thread.current[:octri_span] = prev
    end

    # Open a sub-span under the active request span; call #finish when done.
    # Returns a no-op handle outside a request or before init.
    def start_span(name, op: nil)
      ctx = current_span
      return NoopSpan.new if @config.nil? || ctx.nil?

      ActiveSpan.new(ctx[:trace_id], new_span_id, ctx[:span_id], name, op || "server")
    end

    # Time a block as a sub-span under the active request span (nests correctly).
    #
    #   Octri.span("orders.list", op: "db") { db.query(sql) }
    def span(name, op: nil)
      ctx = current_span
      return yield if @config.nil? || ctx.nil?

      span_id = new_span_id
      start = now_iso
      prev = set_current_span(ctx[:trace_id], span_id)
      status = "ok"
      begin
        yield
      rescue Exception # rubocop:disable Lint/RescueException
        status = "error"
        raise
      ensure
        reset_current_span(prev)
        capture_span(
          trace_id: ctx[:trace_id], span_id: span_id, parent_span_id: ctx[:span_id],
          name: name, service: op || "server", start_time: start, end_time: now_iso, status: status
        )
      end
    end

    # ── Reporting ──────────────────────────────────────────────────────────────
    def capture_error(exception, trace: nil, method: nil, path: nil, status_code: nil, level: "error")
      return if @config.nil?

      tr = trace || trace_from_current
      payload = {
        eventId: SecureRandom.hex(8),
        timestamp: now_iso,
        level: level,
        environment: @config.environment,
        traceId: tr.trace_id,
        spanId: new_span_id,
        tags: { "octri.origin" => "server" },
        error: {
          name: exception.class.name,
          message: exception.message.to_s,
          frames: build_frames(exception)
        }
      }
      payload[:release] = @config.release if @config.release
      payload[:method] = method if method
      payload[:path] = path if path
      payload[:statusCode] = status_code if status_code
      post_json("/ingest", payload)
    end

    def capture_span(trace_id:, span_id:, name:, start_time:, parent_span_id: nil,
                     service: "server", operation_id: nil, end_time: nil, status: "ok")
      return if @config.nil?

      payload = { traceId: trace_id, spanId: span_id, name: name, service: service,
                  startTime: start_time, status: status }
      payload[:parentSpanId] = parent_span_id if parent_span_id
      payload[:endTime] = end_time if end_time
      payload[:operationId] = operation_id if operation_id
      post_json("/traces", payload)
    end

    def now_iso
      Time.now.utc.iso8601(3)
    end

    private

    def trace_from_current
      ctx = current_span
      return Trace.new(ctx[:trace_id], ctx[:span_id]) if ctx

      Trace.new(SecureRandom.hex(16), nil)
    end

    # An exception's backtrace is innermost-first, matching the dashboard's
    # culprit = top frame.
    def build_frames(exception)
      locations = exception.backtrace_locations
      return [] if locations.nil?

      locations.map do |loc|
        path = loc.absolute_path || loc.path
        lineno = loc.lineno
        frame = { function: loc.label, filename: path, lineno: lineno, colno: 0, inApp: in_app?(path) }
        lines = read_source(path)
        if lines && lineno >= 1 && lineno <= lines.length
          idx = lineno - 1
          frame[:contextLine] = lines[idx]
          pre = lines[[0, idx - CONTEXT_LINES].max...idx]
          post = lines[(idx + 1)...(idx + 1 + CONTEXT_LINES)]
          frame[:preContext] = pre if pre && !pre.empty?
          frame[:postContext] = post if post && !post.empty?
        end
        frame
      end
    end

    def in_app?(path)
      return false if path.nil?

      !path.include?("/gems/") && !path.include?("/ruby/") &&
        !path.start_with?(RbConfig::CONFIG["libdir"].to_s)
    end

    def read_source(path)
      return nil if path.nil?

      @source_cache ||= {}
      return @source_cache[path] if @source_cache.key?(path)

      lines = begin
        File.readlines(path, chomp: true)
      rescue StandardError
        nil
      end
      @source_cache[path] = lines
      lines
    end

    def post_json(path, payload)
      cfg = @config
      return if cfg.nil?

      body = JSON.generate(payload)
      Thread.new do
        uri = URI("#{cfg.url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 5
        req = Net::HTTP::Post.new(uri)
        req["content-type"] = "application/json"
        req["authorization"] = "Bearer #{cfg.token}"
        req.body = body
        http.request(req)
      rescue StandardError
        # A reporting failure must never affect the app.
      end
    end
  end

  # A sub-span handle for manual control; #finish reports it (named `finish`
  # rather than `end`, which is a Ruby keyword).
  class ActiveSpan
    def initialize(trace_id, span_id, parent_span_id, name, service)
      @trace_id = trace_id
      @span_id = span_id
      @parent_span_id = parent_span_id
      @name = name
      @service = service
      @start = Octri.now_iso
      @status = "ok"
      @ended = false
    end

    def fail
      @status = "error"
    end

    def finish(status = nil)
      return if @ended

      @ended = true
      Octri.capture_span(
        trace_id: @trace_id, span_id: @span_id, parent_span_id: @parent_span_id,
        name: @name, service: @service, start_time: @start,
        end_time: Octri.now_iso, status: status || @status
      )
    end
  end

  # No-op handle returned outside a request.
  class NoopSpan
    def fail; end

    def finish(_status = nil); end
  end
end
