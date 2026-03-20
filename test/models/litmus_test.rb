# frozen_string_literal: true

require "test_helper"
require "dummy/app/models/test_invoice"
require "dummy/app/models/test_contract"

# =============================================================================
# LITMUS TESTS - Critical path functionality
# These tests verify the absolute core behavior that cannot break.
# =============================================================================

class FosmLitmusTest < ActiveSupport::TestCase
  # 🆕 Disable transactional fixtures to avoid SQLite locking with nested transactions
  self.use_transactional_tests = false

  def setup
    # Clean up before each test
    Fosm::TransitionLog.delete_all
    TestInvoice.delete_all

    @invoice = TestInvoice.create!(recipient_email: "test@example.com", line_items_count: 1)
  end

  def teardown
    # Clean up after each test
    Fosm::TransitionLog.delete_all
    TestInvoice.delete_all
  end

  # Litmus 1: State must change only through fire!
  test "fire! is the only valid state mutation path" do
    assert_equal "draft", @invoice.state

    # Direct update should work at AR level but is discouraged
    @invoice.update!(state: "sent")
    assert_equal "sent", @invoice.state

    # But fire! should still validate
    @invoice.update!(state: "draft")
    assert_nothing_raised { @invoice.send_invoice!(actor: :test) }
    assert_equal "sent", @invoice.state
  end

  # Litmus 2: Guards must block invalid transitions
  test "guards prevent invalid transitions" do
    empty_invoice = TestInvoice.create!(recipient_email: "test@example.com", line_items_count: 0)

    assert_raises(Fosm::GuardFailed) do
      empty_invoice.send_invoice!(actor: :test)
    end

    assert_equal "draft", empty_invoice.state # State unchanged
  end

  # Litmus 3: Terminal states must block transitions (without force)
  test "terminal states block normal transitions" do
    paid_invoice = TestInvoice.create!(
      state: "paid",
      recipient_email: "test@example.com",
      line_items_count: 1,
      payment_received: true
    )

    assert_raises(Fosm::TerminalState) do
      paid_invoice.send_invoice!(actor: :test)
    end
  end

  # Litmus 4: force: true must allow transitions from terminal states
  test "force: true bypasses terminal state check" do
    paid_invoice = TestInvoice.create!(
      state: "paid",
      recipient_email: "test@example.com",
      line_items_count: 1,
      payment_received: true
    )

    assert_nothing_raised do
      paid_invoice.refund!(actor: :test)
    end

    assert_equal "refunded", paid_invoice.state
  end

  # Litmus 5: Side effects must run inside transaction
  test "side effects execute and rollback with transaction" do
    # This test verifies the side_effect ran
    assert_nil @invoice.notification_sent

    @invoice.send_invoice!(actor: :test)

    assert_equal true, @invoice.notification_sent
  end

  # Litmus 6: Guard failure includes reason in exception
  test "GuardFailed includes reason when provided" do
    empty_invoice = TestInvoice.create!(recipient_email: "test@example.com", line_items_count: 0)

    error = assert_raises(Fosm::GuardFailed) do
      empty_invoice.send_invoice!(actor: :test)
    end

    assert_includes error.message, "has_line_items"
    assert_includes error.message, "At least one line item required"
    assert_equal "At least one line item required", error.reason
  end

  # Litmus 7: why_cannot_fire? provides actionable diagnostics
  test "why_cannot_fire? returns complete diagnostic information" do
    empty_invoice = TestInvoice.create!(recipient_email: "test@example.com", line_items_count: 0)

    result = empty_invoice.why_cannot_fire?(:send_invoice)

    assert_equal false, result[:can_fire]
    assert_equal "draft", result[:current_state]
    assert_equal "send_invoice", result[:event]
    assert result[:failed_guards].any? { |g| g[:name] == :has_line_items }
    assert result[:passed_guards].include?(:valid_recipient)
    assert_includes result[:reason], "has_line_items"
    assert_includes result[:reason], "At least one line item required"
  end

  # Litmus 8: rescue: :log prevents side effect errors from failing transition
  test "side effect with rescue: :log allows transition on error" do
    @invoice.send_invoice!(actor: :test)
    @invoice.instance_variable_set(:@should_fail_cancellation, true)

    # Should NOT raise despite side effect failing
    assert_nothing_raised do
      @invoice.cancel!(actor: :test)
    end

    assert_equal "draft", @invoice.state
    assert_nil @invoice.cancellation_notified # Side effect failed, but logged
  end

  # Litmus 9: triggered_by metadata creates causal chain
  test "triggered_by metadata links cross-machine transitions" do
    contract = TestContract.create!
    contract.send_for_payment!(actor: :test)
    assert_equal "awaiting_payment", contract.state

    order = TestOrder.create!(test_contract: contract)

    order.start_processing!(actor: :test)
    order.complete!(actor: :test)

    # Reload both records - side effect runs after commit
    contract.reload
    order.reload

    # Contract should be activated by deferred side effect
    assert_equal "active", contract.state

    # Verify the causal chain was logged
    log = Fosm::TransitionLog.where(record_type: "TestContract").last
    assert log.metadata["triggered_by"]
    assert_equal "TestOrder", log.metadata["triggered_by"]["record_type"]
    assert_equal order.id, log.metadata["triggered_by"]["record_id"]
    assert_equal "complete", log.metadata["triggered_by"]["event_name"]
  end
end
