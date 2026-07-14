# octri (Ruby)

Server-side error monitoring for **Ruby** backends. Add it to your live API and
it reports backend errors to your Octri monitoring project — with original-source
context per stack frame — and **links each one to the client SDK error for the
same request** via the W3C `traceparent` header. It also times requests (and any
sub-spans you open) into the request waterfall.

The Ruby sibling of [`@octri/node`](../octri-node). Standard library only.

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
