require "test_helper"

# NOTE: These tests verify the snapshot DSL and configuration works correctly.
# Full integration tests with actual snapshot capture are skipped on SQLite
# due to database locking issues with concurrent queries inside transactions.
class SnapshotTest < ActiveSupport::TestCase
  setup do
    Fosm::TransitionLog.delete_all
  end

  test "snapshot configuration is accessible on model" do
    lifecycle = TestModels::SnapshotInvoice.fosm_lifecycle
    assert lifecycle.snapshot_configured?
    assert_equal :every, lifecycle.snapshot_configuration.strategy
  end

  test "snapshot attributes are configured correctly" do
    config = TestModels::SelectiveSnapshotInvoice.fosm_lifecycle.snapshot_configuration
    assert_equal [ "line_items_count", "recipient_email" ], config.attributes
  end

  test "terminal snapshot strategy is configured" do
    config = TestModels::TerminalSnapshotInvoice.fosm_lifecycle.snapshot_configuration
    assert_equal :terminal, config.strategy
  end

  test "manual snapshot strategy is configured" do
    config = TestModels::ManualSnapshotInvoice.fosm_lifecycle.snapshot_configuration
    assert_equal :manual, config.strategy
  end

  test "snapshot decision logic works correctly" do
    config = Fosm::Lifecycle::SnapshotConfiguration.new
    config.every

    # Should snapshot on every transition
    assert config.should_snapshot?(
      transition_count: 1,
      seconds_since_last: 0,
      to_state: "sent",
      to_state_terminal: false,
      force: false
    )

    # Terminal strategy
    config = Fosm::Lifecycle::SnapshotConfiguration.new
    config.terminal

    assert config.should_snapshot?(
      transition_count: 1,
      seconds_since_last: 0,
      to_state: "paid",
      to_state_terminal: true,
      force: false
    )

    refute config.should_snapshot?(
      transition_count: 1,
      seconds_since_last: 0,
      to_state: "sent",
      to_state_terminal: false,
      force: false
    )
  end

  test "snapshot? method on TransitionLog" do
    log = Fosm::TransitionLog.new(state_snapshot: { "test" => "data" })
    assert log.snapshot?

    log = Fosm::TransitionLog.new(state_snapshot: nil)
    refute log.snapshot?
  end

  test "TransitionLog scopes exist" do
    assert_respond_to Fosm::TransitionLog, :with_snapshot
    assert_respond_to Fosm::TransitionLog, :without_snapshot
    assert_respond_to Fosm::TransitionLog, :by_snapshot_reason
  end

  test "model instance methods exist" do
    invoice = TestModels::SnapshotInvoice.new
    assert_respond_to invoice, :last_snapshot
    assert_respond_to invoice, :snapshots
    assert_respond_to invoice, :state_at_transition
    assert_respond_to invoice, :replay_from
    assert_respond_to invoice, :transitions_since_snapshot
  end
end
