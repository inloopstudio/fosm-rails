# frozen_string_literal: true

require "test_helper"
require "dummy/app/models/test_invoice"
require "dummy/app/models/test_contract"

# =============================================================================
# INTEGRATION TESTS - Full feature coverage
# Comprehensive tests for all new features.
# =============================================================================

class FosmIntegrationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    Fosm::TransitionLog.delete_all
    TestOrder.delete_all
    TestInvoice.delete_all
    TestContract.delete_all

    @valid_invoice = TestInvoice.create!(
      recipient_email: "valid@example.com",
      line_items_count: 3,
      payment_received: false
    )
  end

  def teardown
    Fosm::TransitionLog.delete_all
    TestOrder.delete_all
    TestInvoice.delete_all
    TestContract.delete_all
  end

  # ============================================================================
  # Guard Definition Tests
  # ============================================================================

  class GuardDefinitionTest < ActiveSupport::TestCase
    test "evaluate returns [true, nil] for true" do
      guard = Fosm::Lifecycle::GuardDefinition.new(name: :test) { true }
      assert_equal [ true, nil ], guard.evaluate(nil)
    end

    test "evaluate returns [false, nil] for false" do
      guard = Fosm::Lifecycle::GuardDefinition.new(name: :test) { false }
      assert_equal [ false, nil ], guard.evaluate(nil)
    end

    test "evaluate returns [false, reason] for string" do
      guard = Fosm::Lifecycle::GuardDefinition.new(name: :test) { "Custom error" }
      assert_equal [ false, "Custom error" ], guard.evaluate(nil)
    end

    test "evaluate returns [false, reason] for [:fail, reason]" do
      guard = Fosm::Lifecycle::GuardDefinition.new(name: :test) { [ :fail, "Failed" ] }
      assert_equal [ false, "Failed" ], guard.evaluate(nil)
    end

    test "evaluate returns [true, nil] for truthy values" do
      guard = Fosm::Lifecycle::GuardDefinition.new(name: :test) { 42 }  # Truthy non-string
      assert_equal [ true, nil ], guard.evaluate(nil)
    end
  end

  # ============================================================================
  # Guard Failure Reason Tests
  # ============================================================================

  class GuardFailureReasonTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all

      @invoice = TestInvoice.create!(
        recipient_email: "",  # Will fail valid_recipient
        line_items_count: 0     # Will fail has_line_items
      )
    end

    def teardown
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all
    end

    test "GuardFailed exception includes reason" do
      error = assert_raises(Fosm::GuardFailed) do
        @invoice.send_invoice!(actor: :test)
      end

      assert_kind_of String, error.reason
      assert error.reason.length > 0
    end

    test "multiple guards - first failure reported" do
      # Both guards should fail - we should get the first one
      result = @invoice.why_cannot_fire?(:send_invoice)

      assert_equal 2, result[:failed_guards].length
      assert result[:failed_guards].any? { |g| g[:name] == :has_line_items }
      assert result[:failed_guards].any? { |g| g[:name] == :valid_recipient }
    end

    test "passed guards listed in diagnostics" do
      @invoice.update!(line_items_count: 1)  # Fix one guard

      result = @invoice.why_cannot_fire?(:send_invoice)

      assert result[:passed_guards].include?(:has_line_items)
      assert result[:failed_guards].any? { |g| g[:name] == :valid_recipient }
    end
  end

  # ============================================================================
  # why_cannot_fire? Comprehensive Tests
  # ============================================================================

  class WhyCannotFireTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all

      @invoice = TestInvoice.create!(
        recipient_email: "test@test.com",
        line_items_count: 1
      )
    end

    def teardown
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all
    end

    test "returns can_fire: true for valid transition" do
      result = @invoice.why_cannot_fire?(:send_invoice)

      assert_equal true, result[:can_fire]
      assert_equal "draft", result[:current_state]
      assert_equal "send_invoice", result[:event]
    end

    test "returns unknown event reason" do
      result = @invoice.why_cannot_fire?(:nonexistent_event)

      assert_equal false, result[:can_fire]
      assert_includes result[:reason], "Unknown event"
    end

    test "returns terminal state reason" do
      paid_invoice = TestInvoice.create!(
        state: "paid",
        recipient_email: "test@test.com",
        line_items_count: 1
      )

      result = paid_invoice.why_cannot_fire?(:send_invoice)

      assert_equal false, result[:can_fire]
      assert_equal true, result[:is_terminal]
      assert_includes result[:reason], "terminal"
    end

    test "returns invalid from state reason" do
      @invoice.update!(state: "sent")

      result = @invoice.why_cannot_fire?(:send_invoice)  # Can't send from sent

      assert_equal false, result[:can_fire]
      assert_includes result[:reason], "Cannot fire"
      assert_includes result[:reason], "sent"
      assert result[:valid_from_states].include?(:draft)
    end

    test "handles no lifecycle defined" do
      # Create a class without lifecycle
      class NoLifecycleRecord < ApplicationRecord
        self.table_name = "test_invoices"
      end

      record = NoLifecycleRecord.new

      # Models without Lifecycle module don't have why_cannot_fire? method
      assert_raises(NoMethodError) do
        record.why_cannot_fire?(:anything)
      end
    end
  end

  # ============================================================================
  # Terminal State Override Tests
  # ============================================================================

  class TerminalStateOverrideTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all

      @paid_invoice = TestInvoice.create!(
        state: "paid",
        recipient_email: "test@test.com",
        line_items_count: 1,
        payment_received: true
      )
    end

    def teardown
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all
    end

    test "normal events blocked from terminal" do
      assert_raises(Fosm::TerminalState) do
        @paid_invoice.send_invoice!(actor: :test)
      end

      assert_raises(Fosm::TerminalState) do
        @paid_invoice.pay!(actor: :test)
      end

      assert_raises(Fosm::TerminalState) do
        @paid_invoice.cancel!(actor: :test)
      end
    end

    test "force: true events allowed from terminal" do
      assert_nothing_raised do
        @paid_invoice.refund!(actor: :test)
      end

      assert_equal "refunded", @paid_invoice.reload.state
    end

    test "can_fire? respects terminal state" do
      refute @paid_invoice.can_send_invoice?
      refute @paid_invoice.can_pay?

      # Note: can_fire? doesn't know about force: true
      # It follows normal terminal state rules
      refute @paid_invoice.can_refund?
    end

    test "why_cannot_fire? shows terminal with force hint" do
      result = @paid_invoice.why_cannot_fire?(:send_invoice)

      assert_equal true, result[:is_terminal]
      assert_includes result[:reason], "terminal"
      assert_includes result[:reason], "force: true"
    end
  end

  # ============================================================================
  # Side Effect Error Handling Tests
  # ============================================================================

  class SideEffectRescueTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all

      @invoice = TestInvoice.create!(
        recipient_email: "test@test.com",
        line_items_count: 1
      )
      @invoice.send_invoice!(actor: :test)
    end

    def teardown
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all
    end

    test "rescue: :raise propagates errors" do
      # Default behavior - should raise
      side_effect = Fosm::Lifecycle::SideEffectDefinition.new(name: :failer) do
        raise "Intentional failure"
      end

      assert_raises(RuntimeError) do
        side_effect.call(nil, nil)
      end
    end

    test "rescue: :log catches and logs errors" do
      side_effect = Fosm::Lifecycle::SideEffectDefinition.new(name: :failer, rescue_strategy: :log) do
        raise "Should be logged"
      end

      # Should not raise
      result = side_effect.call(nil, nil)
      assert_nil result
    end

    test "rescue: :ignore silently drops errors" do
      side_effect = Fosm::Lifecycle::SideEffectDefinition.new(name: :failer, rescue_strategy: :ignore) do
        raise "Should be ignored"
      end

      # Should not raise, should not log
      result = side_effect.call(nil, nil)
      assert_nil result
    end

    test "cancel event with rescue: :log allows transition despite error" do
      @invoice.instance_variable_set(:@should_fail_cancellation, true)

      # This should succeed even though notify_cancellation fails
      assert_nothing_raised do
        @invoice.cancel!(actor: :test)
      end

      assert_equal "draft", @invoice.state
    end

    test "successful side effects still run" do
      @invoice.instance_variable_set(:@should_fail_cancellation, false)

      @invoice.cancel!(actor: :test)

      # Both side effects should have run
      assert_equal true, @invoice.cancellation_notified
      assert_equal true, @invoice.inventory_updated
    end
  end

  # ============================================================================
  # Causal Chain (triggered_by) Tests
  # ============================================================================

  class CausalChainTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    def setup
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all

      @contract = TestContract.create!
      @contract.send_for_payment!(actor: :test)
      @order = TestOrder.create!(test_contract: @contract)
    end

    def teardown
      Fosm::TransitionLog.delete_all
      TestOrder.delete_all
      TestInvoice.delete_all
      TestContract.delete_all
    end

    test "cross-machine trigger updates target state" do
      @order.start_processing!(actor: :test)
      @order.complete!(actor: :test)

      @contract.reload
      assert_equal "active", @contract.state
    end

    test "triggered_by metadata in transition log" do
      @order.start_processing!(actor: :test)
      @order.complete!(actor: :test)

      log = Fosm::TransitionLog.where(
        record_type: "TestContract",
        event_name: "activate"
      ).last

      assert log.present?
      assert log.metadata["triggered_by"].present?
      assert_equal "TestOrder", log.metadata["triggered_by"]["record_type"]
      assert_equal @order.id, log.metadata["triggered_by"]["record_id"]
      assert_equal "complete", log.metadata["triggered_by"]["event_name"]
    end

    test "actor is :system for triggered transitions" do
      @order.start_processing!(actor: :test)
      @order.complete!(actor: :test)

      log = Fosm::TransitionLog.where(record_type: "TestContract").last

      assert_equal "symbol", log.actor_type
      # Symbol actors have nil actor_id, the symbol name is in actor_label
      assert_equal "system", log.actor_label
    end

    test "no triggered_by for manual transitions" do
      manual_contract = TestContract.create!
      manual_contract.send_for_payment!(actor: :test)
      manual_contract.activate!(actor: :user)

      log = Fosm::TransitionLog.where(record_type: "TestContract", record_id: manual_contract.id).last

      assert_nil log.metadata["triggered_by"]
    end
  end

  # ============================================================================
  # Event Definition Tests
  # ============================================================================

  class EventDefinitionTest < ActiveSupport::TestCase
    test "force? returns false by default" do
      event = Fosm::Lifecycle::EventDefinition.new(
        name: :test,
        from: :draft,
        to: :sent
      )

      refute event.force?
    end

    test "force? returns true when force: true" do
      event = Fosm::Lifecycle::EventDefinition.new(
        name: :test,
        from: :draft,
        to: :sent,
        force: true
      )

      assert event.force?
    end
  end
end
