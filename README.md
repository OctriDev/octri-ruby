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

`Octri::Rack` captures any exception raised by the app (linked to the request's
trace) and re-raises, and times the request as a server span.

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
