# octri (Ruby)

**Error and performance monitoring for Ruby backends.** Report errors out of Rack
or Rails with original-source context per stack frame, time every request and any
sub-span you open into a waterfall, and join each server error to the client SDK
error for the same request through the W3C `traceparent` header. In the
dashboard you see the full client → server stack under one trace.

Octri turns an OpenAPI spec into a documentation site, client SDKs for ten
languages, an MCP server your AI assistant can call, and monitoring for the
API behind them. This gem is the Ruby monitoring runtime, and it works on its
own: a generated Octri API SDK is not required. See
[octri.dev/monitoring](https://octri.dev/monitoring).

Ruby 2.7 or newer. Standard library only. The Ruby sibling of
[`@octri/node`](https://github.com/octridev/octri-node).

## Install

```bash
gem install octri
```

## Setup (Rack / Rails)

```ruby
require "octri"
require "octri/rack"

Octri.init(
  url: "https://monitoring.example.com",
  token: ENV["OCTRI_TOKEN"],
  environment: "<your project id>",
  release: ENV["GIT_SHA"] # optional
)

# config.ru / Rails middleware stack:
use Octri::Rack
```

Hosted users can copy the project-scoped URL, token, and environment from the
Monitoring connection settings (or its API). Omit `token:` only when pointing
at an open self-hosted ingest endpoint. Every request carries an idempotency key.

## Standalone events

No generated API SDK is required to send your own events:

```ruby
Octri.capture_event(
  "checkout.completed",
  user: { id: customer.id },
  tags: { region: "eu-west", plan: "growth" },
  context: { order_id: order.id, total: order.total }
)
```

Delivery is best-effort and runs on a background thread. Pass `event_id:` to
make a retried delivery idempotent.

`Octri::Rack` captures any exception raised by the app (linked to the request's
trace) and re-raises, and times the request as a server span.

## Automatic instrumentation

```ruby
Octri.auto_instrument                            # traces outbound Net::HTTP calls
Octri.instrument(PG::Connection, [:exec], op: "db")  # your DB client / util class, once
Octri.instrument(cache, [:get, :set], op: "cache")
```

Every instrumented call (and every outbound HTTP request) becomes a sub-span
under the current request — no per-call code. Calls to your monitoring backend
are never traced (no feedback loop).

## Sub-spans (where time goes)

```ruby
Octri.span("orders.list", op: "db") do
  Order.where(status: "open").to_a
end

# or manual control:
s = Octri.start_span("cache.get", op: "cache")
value = cache.read(key)
s.finish
```

`op` ("db", "cache", "http", …) color-codes the waterfall; nested `Octri.span`
calls nest correctly.

## Manual error capture

```ruby
begin
  risky!
rescue => e
  Octri.capture_error(e)
  raise
end
```

---

## The rest of Octri

| Product | What it does |
|---|---|
| [API Studio](https://octri.dev/api-studio) | Your OpenAPI spec becomes a hosted documentation site with a live request playground, editable page by page. |
| [SDK Studio](https://octri.dev/sdk-studio) | The same spec becomes client libraries for ten languages, versioned and released together. |
| [MCP](https://octri.dev/mcp) | Your endpoints and docs become tools an AI assistant can call, generated from the same spec. |
| [Monitoring](https://octri.dev/monitoring) | Errors, traces, uptime and releases for the API, joined to the SDK calls that reached it. |

### Monitoring runtimes

[Node](https://github.com/octridev/octri-node) ·
[Python](https://github.com/octridev/octri-python) ·
[Go](https://github.com/octridev/octri-go) ·
[Ruby](https://github.com/octridev/octri-ruby) ·
[Rust](https://github.com/octridev/octri-rust) ·
[PHP](https://github.com/octridev/octri-php) ·
[Java](https://github.com/octridev/octri-java) ·
[Kotlin](https://github.com/octridev/octri-kotlin) ·
[Swift](https://github.com/octridev/octri-swift) ·
[Dart](https://github.com/octridev/octri-dart)

[Documentation](https://docs.octri.dev/docs) ·
[Pricing](https://octri.dev/pricing) ·
[Changelog](https://docs.octri.dev/changelog)

MIT licensed.
