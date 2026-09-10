# Changelog

## 1.0.0

First public release.

- Error reporting with original source context for each in-app stack frame.
- Request and sub-span timing, drawn as a waterfall in the dashboard.
- W3C `traceparent` propagation, so a server error links to the client SDK
  error for the same request.
- Standalone events with idempotent, best-effort delivery.
- Rack middleware for Rack and Rails, plus automatic instrumentation of outbound HTTP.
