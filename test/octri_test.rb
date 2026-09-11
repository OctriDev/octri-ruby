# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/octri"

class OctriStandaloneEventTest < Minitest::Test
  def test_capture_event_has_stable_idempotency_key
    captured = nil
    singleton = Octri.singleton_class
    singleton.alias_method(:original_post_json_for_test, :post_json)
    singleton.define_method(:post_json) do |path, payload, idempotency_key:|
      captured = { path: path, payload: payload, idempotency_key: idempotency_key }
    end

    Octri.init(url: "https://monitoring.example.com", environment: "project-1")
    Octri.capture_event(
      "checkout.completed",
      event_id: "event-123",
      tags: { plan: "growth" },
      context: { orderId: "order-1" }
    )

    assert_equal "/ingest", captured[:path]
    assert_equal "event-123", captured[:idempotency_key]
    assert_equal "checkout.completed", captured[:payload][:message]
    assert_equal "project-1", captured[:payload][:environment]
    assert_equal({ "octri.origin" => "standalone", plan: "growth" }, captured[:payload][:tags])
  ensure
    if singleton && (singleton.method_defined?(:original_post_json_for_test) ||
                     singleton.private_method_defined?(:original_post_json_for_test))
      singleton.alias_method(:post_json, :original_post_json_for_test)
      singleton.remove_method(:original_post_json_for_test)
      singleton.send(:private, :post_json)
    end
  end

  def test_traceparent_is_trimmed_and_zero_identifiers_are_rejected
    valid = Octri.trace_from_header(
      "  00-4BF92F3577B34DA6A3CE929D0E0E4736-00F067AA0BA902B7-01  "
    )
    assert_equal "4bf92f3577b34da6a3ce929d0e0e4736", valid.trace_id
    assert_equal "00f067aa0ba902b7", valid.parent_span_id

    [
      "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
      "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"
    ].each do |header|
      fresh = Octri.trace_from_header(header)
      assert_match(/\A[0-9a-f]{32}\z/, fresh.trace_id)
      refute_equal("0" * 32, fresh.trace_id)
      assert_nil fresh.parent_span_id
    end
  end

  def test_event_ids_are_non_blank_safe_and_bounded
    captured = []
    singleton = Octri.singleton_class
    singleton.alias_method(:original_post_json_for_id_test, :post_json)
    singleton.define_method(:post_json) do |_path, payload, idempotency_key:|
      captured << [payload, idempotency_key]
    end

    Octri.init(url: "https://monitoring.example.com", environment: "project-1")
    ["  event-123  ", " \t ", "bad\r\nX: true", "x" * 257].each do |event_id|
      Octri.capture_event("test", event_id: event_id)
    end

    assert_equal "event-123", captured[0][0][:eventId]
    assert_equal "event-123", captured[0][1]
    captured.drop(1).each do |payload, key|
      assert_match(/\A[0-9a-f]{32}\z/, key)
      assert_equal key, payload[:eventId]
    end
  ensure
    if singleton && (singleton.method_defined?(:original_post_json_for_id_test) ||
                     singleton.private_method_defined?(:original_post_json_for_id_test))
      singleton.alias_method(:post_json, :original_post_json_for_id_test)
      singleton.remove_method(:original_post_json_for_id_test)
      singleton.send(:private, :post_json)
    end
  end

  def test_source_context_is_limited_to_in_app_frames
    frames = begin
      JSON.parse("{")
    rescue StandardError => error
      Octri.send(:build_frames, error)
    end

    assert frames.any? { |frame| frame[:inApp] && frame[:contextLine] }
    refute frames.any? { |frame| !frame[:inApp] && frame[:contextLine] }
  end

  def test_invalid_spans_are_suppressed
    captured = []
    singleton = Octri.singleton_class
    singleton.alias_method(:original_post_json_for_span_test, :post_json)
    singleton.define_method(:post_json) do |_path, payload, idempotency_key:|
      captured << [payload, idempotency_key]
    end

    Octri.init(url: "https://monitoring.example.com", environment: "project-1")
    now = "2026-07-13T12:00:00Z"
    Octri.capture_span(trace_id: "", span_id: "span-1", name: "test", start_time: now)
    Octri.capture_span(trace_id: "trace-1", span_id: "span-1", name: " ", start_time: now)
    Octri.capture_span(trace_id: "trace-1", span_id: "span-1", name: "test", start_time: "bad")
    Octri.capture_span(
      trace_id: "0" * 32, span_id: "0" * 16, name: "test", start_time: now
    )
    assert_empty captured
  ensure
    if singleton && (singleton.method_defined?(:original_post_json_for_span_test) ||
                     singleton.private_method_defined?(:original_post_json_for_span_test))
      singleton.alias_method(:post_json, :original_post_json_for_span_test)
      singleton.remove_method(:original_post_json_for_span_test)
      singleton.send(:private, :post_json)
    end
  end

  def test_unsafe_auth_and_thread_exhaustion_are_best_effort
    called = false
    thread_singleton = Thread.singleton_class
    thread_singleton.alias_method(:original_new_for_octri_test, :new)
    thread_singleton.define_method(:new) do |*args, &block|
      called = true
      raise ThreadError, "thread limit"
    end

    Octri.init(
      url: "https://monitoring.example.com",
      environment: "project-1",
      token: "bad\r\nX: true"
    )
    Octri.capture_event("suppressed")
    refute called

    Octri.init(url: "https://monitoring.example.com", environment: "project-1")
    Octri.capture_event("thread exhaustion")
    hostile_error = Class.new(StandardError) do
      def message
        raise "broken error message"
      end
    end.new
    Octri.capture_error(hostile_error)
    assert called
    assert_equal 5, Octri::REQUEST_TIMEOUT_SECONDS
  ensure
    if thread_singleton&.method_defined?(:original_new_for_octri_test)
      thread_singleton.alias_method(:new, :original_new_for_octri_test)
      thread_singleton.remove_method(:original_new_for_octri_test)
    end
  end
end
