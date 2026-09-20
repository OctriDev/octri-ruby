# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/octri"

# The scrubber is what stands between the host application and the wire, so it
# is exercised directly rather than through a stubbed transport.
class OctriScrubTest < Minitest::Test
  def setup
    Octri.init(url: "https://monitoring.example.com", environment: "project-1")
  end

  def teardown
    Octri.set_before_send
    Octri.instance_variable_set(:@extra_scrub_keys, [])
  end

  def scrub(payload)
    Octri.send(:scrub_payload, payload)
  end

  # ── Keys ────────────────────────────────────────────────────────────────────

  def test_credential_shaped_keys_are_redacted_however_they_are_spelled
    context = scrub(context: {
      api_key: "sk_live_1",
      apiKey: "sk_live_2",
      "X-API-KEY" => "sk_live_3",
      stripe_secret_key: "sk_live_4",
      Authorization: "Bearer abc",
      refresh_token: "rt_1",
      cookie: "sid=1",
      orderId: "A-1024",
      author: "ada"
    })[:context]

    [:api_key, :apiKey, "X-API-KEY", :stripe_secret_key, :Authorization,
     :refresh_token, :cookie].each do |key|
      assert_equal "[redacted]", context[key], key.to_s
    end
    assert_equal "A-1024", context[:orderId]
    assert_equal "ada", context[:author]
  end

  def test_nested_and_array_values_are_redacted_too
    payload = scrub(context: { upstream: { headers: [{ authorization: "Bearer abc" }] } })

    assert_equal "[redacted]", payload[:context][:upstream][:headers][0][:authorization]
  end

  def test_add_scrub_fields_is_additive
    Octri.add_scrub_fields("account_number")
    context = scrub(context: { accountNumber: "12345678", orderId: "A-1024" })[:context]

    assert_equal "[redacted]", context[:accountNumber]
    assert_equal "A-1024", context[:orderId]
  end

  # ── Free text ───────────────────────────────────────────────────────────────

  def test_secrets_that_leaked_into_a_message_are_stripped
    message = scrub(
      message: "401 from billing: Authorization: Bearer sk_live_abc123 rejected"
    )[:message]

    refute_includes message, "sk_live_abc123"
    assert_includes message, "[redacted]"
  end

  def test_a_jwt_in_a_message_is_stripped
    payload = scrub(message: "token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.7Hk2 expired")

    assert_equal "token [redacted] expired", payload[:message]
  end

  def test_an_email_in_a_message_is_stripped
    payload = scrub(message: "no account for ada@example.com")

    assert_equal "no account for [redacted]", payload[:message]
  end

  def test_a_card_number_is_stripped_but_an_order_number_is_not
    message = scrub(
      message: "charge 4242 4242 4242 4242 failed for order 1234567890123"
    )[:message]

    refute_includes message, "4242"
    assert_includes message, "1234567890123"
  end

  # ── The user field ──────────────────────────────────────────────────────────

  # The identity the dashboard keys on is `id`, which survives. Direct
  # identifiers under the user are redacted like they are in every generated SDK.
  def test_user_id_survives_but_user_credentials_and_identifiers_do_not
    user = scrub(user: { id: "u_1", email: "ada@example.com", session_token: "st_1", customerPhone: "+1 555 0100" })[:user]

    assert_equal "u_1", user[:id]
    assert_equal "[redacted]", user[:email]
    assert_equal "[redacted]", user[:session_token]
    assert_equal "[redacted]", user[:customerPhone]
  end

  def test_identifier_words_inside_longer_keys_are_redacted
    context = scrub(context: { billingAddress: { line1: "1 High St" }, shipping_first_name: "Ada",
                               avatarUrl: "https://cdn.example.com/a.png", queryTimeMs: 12 })[:context]

    assert_equal "[redacted]", context[:billingAddress]
    assert_equal "[redacted]", context[:shipping_first_name]
    assert_equal "https://cdn.example.com/a.png", context[:avatarUrl]
    assert_equal 12, context[:queryTimeMs]
  end

  # ── before_send ─────────────────────────────────────────────────────────────

  def test_before_send_can_edit_a_payload_and_redaction_still_runs_after_it
    Octri.set_before_send do |payload|
      payload[:context] = { note: "call ada@example.com" }
      payload
    end

    assert_equal "call [redacted]", scrub(message: "build failed")[:context][:note]
  end

  def test_before_send_returning_nil_drops_the_event
    Octri.set_before_send { |payload| payload[:message] == "noise" ? nil : payload }

    assert_nil scrub(message: "noise")
    refute_nil scrub(message: "signal")
  end

  # ── Cycles ──────────────────────────────────────────────────────────────────

  def test_a_cyclic_context_is_marked_instead_of_losing_the_event
    circular = {}
    circular[:self] = circular

    assert_equal "[circular]", scrub(context: circular)[:context][:self]
  end
end
