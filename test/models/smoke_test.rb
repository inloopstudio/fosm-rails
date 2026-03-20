# frozen_string_literal: true

require "test_helper"
require "dummy/app/models/test_invoice"
require "dummy/app/models/test_contract"

# =============================================================================
# SMOKE TESTS - Quick validation of key features
# Run these for rapid feedback during development.
# =============================================================================

class FosmSmokeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  
  def setup
    Fosm::TransitionLog.delete_all
    TestOrder.delete_all  # Delete children first (foreign key constraint)
    TestInvoice.delete_all
    TestContract.delete_all
  end
  
  def teardown
    Fosm::TransitionLog.delete_all
    TestOrder.delete_all
    TestInvoice.delete_all
    TestContract.delete_all
  end
  test "basic lifecycle works end-to-end" do
    invoice = TestInvoice.create!(
      recipient_email: "smoke@test.com",
      line_items_count: 2
    )
    
    assert invoice.draft?
    assert invoice.can_send_invoice?
    
    invoice.send_invoice!(actor: :smoke)
    assert invoice.sent?
    
    # Simulate payment
    invoice.update!(payment_received: true)
    invoice.pay!(actor: :smoke)
    assert invoice.paid?
    
    # Refund from terminal
    invoice.refund!(actor: :smoke)
    assert invoice.refunded?
    
    puts "✓ Smoke test passed: Full lifecycle"
  end
  
  test "guard error messages work" do
    invoice = TestInvoice.create!(
      recipient_email: "bad-email",
      line_items_count: 0
    )
    
    diagnostics = invoice.why_cannot_fire?(:send_invoice)
    
    assert_equal false, diagnostics[:can_fire]
    assert diagnostics[:reason].present?
    
    puts "✓ Smoke test passed: Guard diagnostics"
  end
  
  test "terminal state with force works" do
    invoice = TestInvoice.create!(
      state: "paid",
      recipient_email: "test@test.com",
      line_items_count: 1
    )
    
    assert_raises(Fosm::TerminalState) do
      invoice.send_invoice!(actor: :test)
    end
    
    assert_nothing_raised do
      invoice.refund!(actor: :test)
    end
    
    puts "✓ Smoke test passed: Terminal state override"
  end
  
  test "side effect error handling" do
    invoice = TestInvoice.create!(
      recipient_email: "test@test.com",
      line_items_count: 1
    )
    
    invoice.send_invoice!(actor: :test)
    invoice.instance_variable_set(:@should_fail_cancellation, true)
    
    # Should succeed even though side effect fails
    assert_nothing_raised do
      invoice.cancel!(actor: :test)
    end
    
    # State should be changed even though side effect failed
    assert_equal "draft", invoice.state
    
    puts "✓ Smoke test passed: Side effect error recovery"
  end
  
  test "cross-machine trigger creates causal chain" do
    contract = TestContract.create!
    contract.send_for_payment!(actor: :test)  # Get contract to awaiting_payment state
    assert_equal "awaiting_payment", contract.state
    
    order = TestOrder.create!(test_contract: contract)
    
    order.start_processing!(actor: :test)
    order.complete!(actor: :test)
    
    # The deferred side effect should activate the contract after the order transaction commits
    assert_equal "active", contract.reload.state
    
    puts "✓ Smoke test passed: Cross-machine causal chain"
  end
  
  test "available_events respects guards" do
    good_invoice = TestInvoice.create!(
      recipient_email: "good@test.com",
      line_items_count: 1
    )
    bad_invoice = TestInvoice.create!(
      recipient_email: "",
      line_items_count: 0
    )
    
    assert_includes good_invoice.available_events, :send_invoice
    refute_includes bad_invoice.available_events, :send_invoice
    
    puts "✓ Smoke test passed: Event availability"
  end
end
