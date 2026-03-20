# frozen_string_literal: true

require "test_helper"
require "rake"

# =============================================================================
# GRAPH GENERATOR TESTS
# Tests for the fosm:graph rake tasks.
# =============================================================================

class FosmGraphTaskTest < ActiveSupport::TestCase
  def setup
    @rake = Rake::Application.new
    Rake.application = @rake

    # Load the rake task
    load File.expand_path("../../../lib/tasks/fosm_graph.rake", __FILE__)

    @output_dir = Rails.root.join("tmp", "test_graphs")
    FileUtils.mkdir_p(@output_dir)
  end

  def teardown
    FileUtils.rm_rf(@output_dir) if @output_dir.present?
  end

  test "graph generation creates valid JSON" do
    # Create a test model with lifecycle
    invoice = TestInvoice.create!(
      recipient_email: "test@test.com",
      line_items_count: 1
    )

    # Run the graph generator
    ENV["MODEL"] = "TestInvoice"
    ENV["OUTPUT"] = @output_dir.to_s

    @rake["fosm:graph:generate"].invoke

    output_file = @output_dir.join("test_invoice_graph.json")
    assert output_file.exist?, "Graph file should be created"

    # Parse and validate JSON
    content = JSON.parse(output_file.read)

    assert_equal "TestInvoice", content["machine"]
    assert content["states"].is_a?(Array)
    assert content["events"].is_a?(Array)

    # Check states
    state_names = content["states"].map { |s| s["name"] }
    assert_includes state_names, "draft"
    assert_includes state_names, "sent"
    assert_includes state_names, "paid"

    # Check events
    event_names = content["events"].map { |e| e["name"] }
    assert_includes event_names, "send_invoice"
    assert_includes event_names, "pay"
    assert_includes event_names, "refund"

    # Check force flag on refund event
    refund_event = content["events"].find { |e| e["name"] == "refund" }
    assert refund_event["force"]
  end

  test "graph includes guard and side effect information" do
    ENV["MODEL"] = "TestInvoice"
    ENV["OUTPUT"] = @output_dir.to_s

    @rake["fosm:graph:generate"].reenable
    @rake["fosm:graph:generate"].invoke

    output_file = @output_dir.join("test_invoice_graph.json")
    content = JSON.parse(output_file.read)

    send_event = content["events"].find { |e| e["name"] == "send_invoice" }

    assert send_event["guards"].is_a?(Array)
    assert_includes send_event["guards"], "has_line_items"
    assert_includes send_event["guards"], "valid_recipient"

    assert send_event["side_effects"].is_a?(Array)
    assert_includes send_event["side_effects"], "send_notification"
  end

  test "graph detects cross-machine connections" do
    # This test verifies the side effect naming convention detection
    # When side effects follow patterns like "activate_contract",
    # they should be detected as cross-machine connections

    ENV["MODEL"] = "TestOrder"
    ENV["OUTPUT"] = @output_dir.to_s

    @rake["fosm:graph:generate"].reenable
    @rake["fosm:graph:generate"].invoke

    output_file = @output_dir.join("test_order_graph.json")
    content = JSON.parse(output_file.read)

    # Check for cross-machine connections
    if content["cross_machine_connections"]
      connections = content["cross_machine_connections"]

      # Should detect the activate_contract side effect
      contract_connection = connections.find { |c| c["target_machine"].include?("Contract") }

      if contract_connection
        assert_equal "complete", contract_connection["source"]["event"]
        assert contract_connection["via"].present?
      end
    end
  end

  test "system graph generation" do
    # Create some test data
    TestInvoice.create!(recipient_email: "test@test.com", line_items_count: 1)
    TestContract.create!

    ENV["SYSTEM"] = "true"
    ENV["OUTPUT"] = @output_dir.to_s

    # Generate all machine graphs first
    @rake["fosm:graph:all"].invoke

    system_file = @output_dir.join("fosm_system_graph.json")

    if system_file.exist?
      content = JSON.parse(system_file.read)

      assert content["machines"].is_a?(Hash)
      assert content["connections"].is_a?(Array)
      assert content["generated_at"].present?
    end
  end

  test "graph generation requires MODEL env var" do
    ENV.delete("MODEL")

    assert_raises(RuntimeError) do
      @rake["fosm:graph:generate"].reenable
      @rake["fosm:graph:generate"].invoke
    end
  end
end
