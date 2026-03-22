require "test_helper"

class SnapshotTest < ActiveSupport::TestCase
  setup do
    # Clean up
    Fosm::TransitionLog.delete_all
  end

  test "snapshot :every captures on every transition" do
    invoice = TestModels::SnapshotInvoice.create!(recipient_email: "test@example.com", line_items_count: 5)

    # With :every strategy, all transitions should have snapshots
    invoice.send_invoice!(actor: :test)
    invoice.mark_paid!(actor: :test)

    logs = Fosm::TransitionLog.for_record("TestModels::SnapshotInvoice", invoice.id).to_a

    # 3 logs: create (initial), send_invoice, mark_paid
    assert_equal 3, logs.count
    assert logs.all?(&:snapshot?), "All transitions should have snapshots with :every strategy"
    assert logs.all? { |l| l.state_snapshot.present? }
    assert logs.all? { |l| l.state_snapshot["line_items_count"].present? }
  end

  test "snapshot :terminal only captures on terminal states" do
    invoice = TestModels::TerminalSnapshotInvoice.create!(recipient_email: "terminal@test.com", line_items_count: 3)

    invoice.send_invoice!(actor: :test)

    # Not yet at terminal state
    logs = Fosm::TransitionLog.for_record("TestModels::TerminalSnapshotInvoice", invoice.id).to_a
    assert logs.none?(&:snapshot?), "No snapshots before terminal state"

    invoice.cancel!(actor: :test)

    # Now at terminal state
    logs = Fosm::TransitionLog.for_record("TestModels::TerminalSnapshotInvoice", invoice.id).to_a
    snapshot_logs = logs.select(&:snapshot?)
    assert_equal 1, snapshot_logs.count, "Should have exactly one snapshot at terminal state"
    assert_equal "cancelled", snapshot_logs.first.to_state
  end

  test "manual snapshot via metadata[:snapshot] = true" do
    invoice = TestModels::ManualSnapshotInvoice.create!(recipient_email: "manual@test.com", line_items_count: 2)

    # First transition without forced snapshot
    invoice.send_invoice!(actor: :test)

    logs = Fosm::TransitionLog.for_record("TestModels::ManualSnapshotInvoice", invoice.id).to_a
    assert logs.none?(&:snapshot?), "No automatic snapshots with manual strategy"

    # Second transition with forced snapshot
    invoice.mark_paid!(actor: :test, metadata: { snapshot: true })

    logs = Fosm::TransitionLog.for_record("TestModels::ManualSnapshotInvoice", invoice.id).order(:created_at)
    snapshot_logs = logs.select(&:snapshot?)
    assert_equal 1, snapshot_logs.count, "Should have exactly one manual snapshot"
    assert_equal "manual", snapshot_logs.first.snapshot_reason
  end

  test "snapshot includes configured attributes" do
    invoice = TestModels::SelectiveSnapshotInvoice.create!(recipient_email: "test@example.com", line_items_count: 7)

    invoice.send_invoice!(actor: :test)

    log = Fosm::TransitionLog.for_record("TestModels::SelectiveSnapshotInvoice", invoice.id).first
    snapshot = log.state_snapshot

    assert snapshot.key?("line_items_count"), "Should include configured attribute: line_items_count"
    assert snapshot.key?("recipient_email"), "Should include configured attribute: recipient_email"
    assert_equal 7, snapshot["line_items_count"]
    assert_equal "test@example.com", snapshot["recipient_email"]
    assert_equal "TestModels::SelectiveSnapshotInvoice", snapshot["_fosm_snapshot_meta"]["record_class"]
  end

  test "last_snapshot returns most recent snapshot" do
    invoice = TestModels::SnapshotInvoice.create!(recipient_email: "last@test.com", line_items_count: 4)

    invoice.send_invoice!(actor: :test)

    snapshot = invoice.last_snapshot
    assert snapshot.present?
    assert_equal "sent", snapshot.to_state
    assert_equal 4, snapshot.state_snapshot["line_items_count"]
  end

  test "snapshots scope returns all snapshots for record" do
    invoice = TestModels::SnapshotInvoice.create!(recipient_email: "scope@test.com", line_items_count: 6)

    invoice.send_invoice!(actor: :test)
    invoice.mark_paid!(actor: :test)

    all_snapshots = invoice.snapshots.to_a
    assert_equal 3, all_snapshots.count  # create, send_invoice, mark_paid
  end
end
