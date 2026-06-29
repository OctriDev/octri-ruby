# frozen_string_literal: true

require "octri"

module Octri
  # Rack middleware: times each request as a server span (a child of the client
  # SDK span via the incoming `traceparent`) and reports any raised exception as
  # an error linked to the same trace, then re-raises. Sub-spans opened with
  # Octri.span / Octri.start_span during the request nest under it.
  #
  #   use Octri::Rack
  class Rack
    def initialize(app)
      @app = app
    end

    def call(env)
      trace = Octri.trace_from_header(env["HTTP_TRACEPARENT"])
      span_id = Octri.new_span_id
      start = Octri.now_iso
      prev = Octri.set_current_span(trace.trace_id, span_id)
      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"]
      status = 500

      begin
        result = @app.call(env)
        status = result[0]
        result
      rescue Exception => e # rubocop:disable Lint/RescueException
        Octri.capture_error(e, trace: trace, method: method, path: path, status_code: 500)
        raise
      ensure
        Octri.reset_current_span(prev)
        Octri.capture_span(
          trace_id: trace.trace_id, span_id: span_id, parent_span_id: trace.parent_span_id,
          name: "#{method} #{path}", service: "server", start_time: start,
          end_time: Octri.now_iso, status: status.to_i >= 500 ? "error" : "ok"
        )
      end
    end
  end
end
