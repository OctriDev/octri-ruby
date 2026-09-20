# Changelog

## 1.2.0

- Direct identifiers are now redacted by key, the same way credentials are:
  `email`, `phone`, `address`, first/last/full name, `username`, `userAgent`,
  passport, tax and national ids, dates of birth, postal codes, coordinates
  and `ipAddress`, wherever the word appears in a key (`billingEmail`,
  `customer_phone_number`). This matches what every generated SDK already did.
- The user's `email` is therefore `[redacted]` before sending. The user's `id`
  still survives; it is the identity the dashboard counts affected users by.

## 1.1.0

- Payloads are now scrubbed before they are sent. Values under keys that name a
  credential (`password`, `secret`, `token`, `apiKey`, `authorization`,
  `cookie`, `ssn` and the rest) are replaced with `[redacted]` at any depth, and
  free text is swept for bearer tokens, JWTs, Luhn-valid card numbers and email
  addresses.
- `add_scrub_fields` adds your own key names to that list.
- `set_before_send` hands you each payload before it goes out; return
  `nil` to drop the event. Redaction runs after the hook.
- The `user` field keeps the identity you set, since that is the point of it.
  Credential-shaped keys inside it are still redacted.

## 1.0.1

- Source context is now read only for frames in your own code, skips files
  over 512 KB, and keeps a bounded cache, so a deep or unusual stack cannot
  pull dependency source into a report or grow memory without limit.

## 1.0.0

First public release.

- Error reporting with original source context for each in-app stack frame.
- Request and sub-span timing, drawn as a waterfall in the dashboard.
- W3C `traceparent` propagation, so a server error links to the client SDK
  error for the same request.
- Standalone events with idempotent, best-effort delivery.
- Rack middleware for Rack and Rails, plus automatic instrumentation of outbound HTTP.
