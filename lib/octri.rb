# frozen_string_literal: true

# Octri: server-side error monitoring for Ruby backends.
#
# Add it to your live API; it reports backend errors to your Octri monitoring
# project (with original-source context per stack frame) and links each one to
# the client SDK error for the same request via the W3C `traceparent` header,
# so the dashboard shows the full client -> server stack under one trace. It also
# times requests (and any sub-spans you open) into the request waterfall.
#
#   require "octri"
#   require "octri/rack"
#   Octri.init(url: "https://monitoring.example.com", token: ENV["OCTRI_TOKEN"], environment: "<project id>")
#   use Octri::Rack

require "securerandom"
require "set"
require "net/http"
require "uri"
require "json"
require "time"

module Octri
  Config = Struct.new(:url, :token, :environment, :release)
  Trace = Struct.new(:trace_id, :parent_span_id)

  CONTEXT_LINES = 5
  MAX_SOURCE_BYTES = 512 * 1024
  MAX_CACHED_SOURCES = 256
  REQUEST_TIMEOUT_SECONDS = 5
  MAX_IDEMPOTENCY_KEY_LENGTH = 256
  TRACEPARENT_RE = /\A00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}\z/i.freeze

  # Keys whose value never leaves the process. Compared against the key with case
  # and separators removed, so `api_key`, `apiKey` and `API-KEY` all match
  # `apikey`, and the test is a substring one, so `stripe_secret_key` matches too.
  # Credentials, then direct identifiers, matched the same way: `phone` also
  # covers `phoneNumber` and `customerPhone`, `address` covers `ipAddress` and
  # `billingAddress`. Bare `ip`, `url` and `name` are deliberately absent: as
  # substrings they would take `zip`, `curl` and the error name with them.
  SCRUB_KEYS = %w[
    password passwd passphrase secret token apikey authorization credential
    cookie session privatekey accesskey cardnumber creditcard cvv ssn
    email phone address firstname lastname fullname username useragent passport taxid
    nationalid dateofbirth birthdate birthday postalcode zipcode latitude longitude socialsecurity ipaddress
  ].freeze

  REDACTED = "[redacted]"
  TRUNCATED = "[truncated]"
  CIRCULAR = "[circular]"
  # Deep enough for real context objects, shallow enough to stay cheap.
  MAX_SCRUB_DEPTH = 8

  BEARER_RE = %r{\bbearer\s+[\w.~+/-]+=*}i.freeze
  JWT_RE = /\beyJ[\w-]+\.[\w-]+\.[\w-]+/.freeze
  DIGIT_RUN_RE = /\b(?:\d[ -]?){12,18}\d\b/.freeze
  EMAIL_RE = /[\w.%+-]+@[\w-]+(?:\.[\w-]+)+/.freeze

  class << self
    # Configure the reporter. Call once at startup before mounting the middleware.
    def init(url:, token: nil, environment:, release: nil)
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
        unless all_zeros?(m[1]) || all_zeros?(m[2])
          return Trace.new(m[1].downcase, m[2].downcase)
        end
        Trace.new(SecureRandom.hex(16), nil)
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

    # ── Automatic instrumentation ─────────────────────────────────────────────
    # Wrap the given methods so every call becomes a sub-span. Point it at a DB
    # client, cache, or util class once and all calls are traced without per-call
    # code. `target` may be a Class/Module (wraps instance methods) or an object
    # (wraps its singleton methods).
    #
    #   Octri.instrument(PG::Connection, [:exec, :exec_params], op: "db")
    #   Octri.instrument(cache, [:get, :set], op: "cache")
    def instrument(target, methods, op: nil, name: nil)
      mod = Module.new
      owner = target.is_a?(Module) ? target : target.singleton_class
      methods.each do |method_name|
        next unless owner.method_defined?(method_name) || owner.private_method_defined?(method_name)

        mod.define_method(method_name) do |*args, **kwargs, &blk|
          span_name = name ? name.call(method_name, args) : method_name.to_s
          Octri.span(span_name, op: op) { super(*args, **kwargs, &blk) }
        end
      end
      owner.prepend(mod)
      target
    end

    # Turn on zero-config tracing for outbound HTTP (Net::HTTP). Calls to your
    # monitoring backend are never traced (no feedback loop).
    def auto_instrument(http: true)
      patch_net_http if http
    end

    # ── Scrubbing ─────────────────────────────────────────────────────────────

    # Redact more key names, on top of the built-in list. Matching ignores case
    # and separators and is a substring test, so `account` also covers
    # `account_number`.
    #
    #   Octri.add_scrub_fields("account_number", "otp")
    def add_scrub_fields(*fields)
      @extra_scrub_keys ||= []
      fields.flatten.each do |field|
        key = normalize_key(field)
        @extra_scrub_keys << key unless key.empty? || @extra_scrub_keys.include?(key)
      end
      @extra_scrub_keys
    end

    # Run a block on every payload just before it is sent. Return the payload
    # (editing it in place is fine) to send it, or nil to drop the event:
    #
    #   Octri.set_before_send { |payload| payload[:path] == "/health" ? nil : payload }
    #
    # Redaction still runs afterwards, so a hook cannot leak a credential by
    # accident. Call it without a block to remove the hook.
    def set_before_send(&hook)
      @before_send = hook
    end

    # ── Reporting ──────────────────────────────────────────────────────────────
    # Log an application event directly, without a generated Octri API SDK.
    # Delivery is fire-and-forget; event_id may be supplied for idempotency.
    def capture_event(message, level: "info", timestamp: nil, operation_id: nil,
                      method: nil, path: nil, status_code: nil, latency_ms: nil,
                      attempt: nil, request_id: nil, user: nil, tags: nil,
                      context: nil, breadcrumbs: nil, fingerprint: nil, trace: nil,
                      span_id: nil, event_id: nil)
      return if @config.nil?

      resolved_event_id = resolve_event_id(event_id)
      payload = {
        eventId: resolved_event_id,
        timestamp: timestamp || now_iso,
        level: level,
        message: message,
        environment: @config.environment,
        tags: { "octri.origin" => "standalone" }.merge(tags || {})
      }
      payload[:release] = @config.release if @config.release
      payload[:operationId] = operation_id if operation_id
      payload[:method] = method if method
      payload[:path] = path if path
      payload[:statusCode] = status_code unless status_code.nil?
      payload[:latencyMs] = latency_ms unless latency_ms.nil?
      payload[:attempt] = attempt unless attempt.nil?
      payload[:requestId] = request_id if request_id
      payload[:user] = user if user
      payload[:context] = context if context
      payload[:breadcrumbs] = breadcrumbs if breadcrumbs
      payload[:fingerprint] = fingerprint if fingerprint
      payload[:traceId] = trace.trace_id if trace
      payload[:spanId] = span_id if span_id
      post_json("/ingest", payload, idempotency_key: resolved_event_id)
    rescue StandardError
      # Invalid caller data must never affect the host application.
      nil
    end

    def capture_error(exception, trace: nil, method: nil, path: nil, status_code: nil, level: "error")
      return if @config.nil?

      tr = trace || trace_from_current
      event_id = SecureRandom.hex(16)
      payload = {
        eventId: event_id,
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
      post_json("/ingest", payload, idempotency_key: event_id)
    rescue StandardError
      # Invalid exception-like objects must not affect the host application.
      nil
    end

    def capture_span(trace_id:, span_id:, name:, start_time:, parent_span_id: nil,
                     service: "server", operation_id: nil, end_time: nil, status: "ok")
      return if @config.nil?
      return unless valid_required_span_value?(trace_id) && valid_required_span_value?(span_id) &&
                    valid_required_span_value?(name) && valid_iso_time?(start_time)
      return if end_time && !valid_iso_time?(end_time)
      return if (trace_id.length == 32 && all_zeros?(trace_id)) ||
                (span_id.length == 16 && all_zeros?(span_id))

      payload = { traceId: trace_id, spanId: span_id, environment: @config.environment,
                  name: name, service: service, startTime: start_time, status: status }
      payload[:parentSpanId] = parent_span_id if parent_span_id
      payload[:endTime] = end_time if end_time
      payload[:operationId] = operation_id if operation_id
      post_json("/traces", payload, idempotency_key: "#{trace_id}:#{span_id}")
    rescue StandardError
      # Invalid caller data must never affect the host application.
      nil
    end

    def now_iso
      Time.now.utc.iso8601(3)
    end

    # True when host:port is the monitoring backend, used to avoid tracing our
    # own reporting requests (which would recurse).
    def monitoring_endpoint?(host, port)
      return false if @config.nil? || @config.url.nil?

      uri = URI(@config.url)
      uri.host == host && uri.port == port
    rescue StandardError
      false
    end

    private

    def all_zeros?(value)
      value.is_a?(String) && !value.empty? && value.each_char.all? { |char| char == "0" }
    end

    def safe_header_value?(value)
      value.is_a?(String) && !value.empty? && !value.include?("\r") && !value.include?("\n")
    end

    def safe_idempotency_key?(value)
      safe_header_value?(value) && value.bytesize <= MAX_IDEMPOTENCY_KEY_LENGTH
    end

    def resolve_event_id(value)
      candidate = value.is_a?(String) ? value.strip : ""
      safe_idempotency_key?(candidate) ? candidate : SecureRandom.hex(16)
    end

    def valid_required_span_value?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def valid_iso_time?(value)
      return false unless valid_required_span_value?(value)

      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    def patch_net_http
      require "net/http"
      return if Net::HTTP.instance_variable_get(:@octri_patched)

      Net::HTTP.prepend(NetHTTPPatch)
      Net::HTTP.instance_variable_set(:@octri_patched, true)
    end

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
        # Only your own files: the dashboard shows them, gem source is noise.
        lines = frame[:inApp] ? read_source(path) : nil
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
        # Big files are skipped, not truncated, so line numbers keep lining up.
        File.size(path) <= MAX_SOURCE_BYTES ? File.readlines(path, chomp: true) : nil
      rescue StandardError
        nil
      end
      # A stack can name any number of files, so the cache is bounded too.
      @source_cache.shift if @source_cache.size >= MAX_CACHED_SOURCES
      @source_cache[path] = lines
      lines
    end

    def normalize_key(key)
      key.to_s.downcase.gsub(/[^a-z0-9]/, "")
    end

    def secret_key?(key)
      normalized = normalize_key(key)
      return false if normalized.empty?

      SCRUB_KEYS.any? { |candidate| normalized.include?(candidate) } ||
        (@extra_scrub_keys || []).any? { |candidate| normalized.include?(candidate) }
    end

    # Tells a card number from the order ids and timestamps that look like one.
    def passes_luhn?(digits)
      sum = 0
      double = false
      digits.reverse.each_char do |char|
        digit = char.ord - 48
        if double
          digit *= 2
          digit -= 9 if digit > 9
        end
        sum += digit
        double = !double
      end
      (sum % 10).zero?
    end

    # Removes credentials and personal data that leaked into free text.
    def scrub_text(value)
      return value if value.empty?

      value
        .gsub(BEARER_RE, REDACTED)
        .gsub(JWT_RE, REDACTED)
        .gsub(DIGIT_RUN_RE) { |run| passes_luhn?(run.delete("^0-9")) ? REDACTED : run }
        .gsub(EMAIL_RE, REDACTED)
    end

    # Redacts credential-shaped keys anywhere in the payload, and strips secrets
    # out of the free text around them. `user` is the field you deliberately fill
    # with an identity, so its strings are left alone; its keys are still checked.
    def scrub_value(value, depth, text, seen)
      case value
      when String
        text ? scrub_text(value) : value
      when Hash, Array
        return TRUNCATED if depth >= MAX_SCRUB_DEPTH
        # Walking a copy means a cycle would recurse forever, and a context hash
        # holding a reference back to itself is worth surviving.
        return CIRCULAR if seen.include?(value.object_id)

        seen.add(value.object_id)
        begin
          scrub_collection(value, depth, text, seen)
        ensure
          seen.delete(value.object_id)
        end
      else
        value
      end
    end

    def scrub_collection(value, depth, text, seen)
      return value.map { |item| scrub_value(item, depth + 1, text, seen) } if value.is_a?(Array)

      value.each_with_object({}) do |(key, nested), out|
        out[key] = if secret_key?(key)
                     REDACTED
                   else
                     scrub_value(nested, depth + 1, text && key.to_s != "user", seen)
                   end
      end
    end

    # The last thing every payload passes through. Both the hook and the
    # redaction live here rather than in the capture methods, so nothing can be
    # reported around them.
    def scrub_payload(payload)
      hooked = @before_send ? @before_send.call(payload) : payload
      return nil unless hooked.is_a?(Hash)

      scrub_value(hooked, 0, true, Set.new)
    end

    def post_json(path, payload, idempotency_key:)
      cfg = @config
      return if cfg.nil?
      return unless safe_idempotency_key?(idempotency_key)
      return if cfg.token && cfg.token != "" && !safe_header_value?(cfg.token)

      scrubbed = scrub_payload(payload)
      return if scrubbed.nil?

      begin
        Thread.new do
          body = JSON.generate(scrubbed)
          uri = URI("#{cfg.url}#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = REQUEST_TIMEOUT_SECONDS
          http.read_timeout = REQUEST_TIMEOUT_SECONDS
          http.write_timeout = REQUEST_TIMEOUT_SECONDS if http.respond_to?(:write_timeout=)
          req = Net::HTTP::Post.new(uri)
          req["content-type"] = "application/json"
          req["idempotency-key"] = idempotency_key
          req["authorization"] = "Bearer #{cfg.token}" if cfg.token && cfg.token != ""
          req.body = body
          http.request(req)
        rescue StandardError
          # A reporting failure must never affect the app.
        end
      rescue StandardError
        # Thread exhaustion must not make monitoring affect the application.
        nil
      end
    end
  end

  # Prepended to Net::HTTP by auto_instrument: wraps outbound requests in an
  # `http` span (skipping requests to the monitoring backend, and when there's no
  # active request span).
  module NetHTTPPatch
    def request(req, body = nil, &block)
      cfg = Octri.config
      if cfg.nil? || Octri.current_span.nil? || Octri.monitoring_endpoint?(address, port)
        return super
      end

      path = req.respond_to?(:path) ? req.path : ""
      method = req.respond_to?(:method) ? req.method : "GET"
      Octri.span("#{method} #{address}:#{port}#{path}", op: "http") { super }
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
