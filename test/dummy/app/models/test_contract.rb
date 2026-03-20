# frozen_string_literal: true

# Test model for cross-machine triggers
class TestContract < ApplicationRecord
  include Fosm::Lifecycle

  self.table_name = "test_contracts"

  lifecycle do
    state :draft, initial: true
    state :awaiting_payment
    state :active, terminal: true
    state :cancelled, terminal: true

    event :send_for_payment, from: :draft, to: :awaiting_payment
    event :activate, from: :awaiting_payment, to: :active
    event :cancel, from: [ :draft, :awaiting_payment ], to: :cancelled
  end

  attr_accessor :activation_log

  def track_activation(actor:, metadata: {})
    @activation_log = { actor: actor, metadata: metadata }
  end
end

# Test model for testing triggered_by chain
class TestOrder < ApplicationRecord
  include Fosm::Lifecycle

  self.table_name = "test_orders"
  belongs_to :test_contract, optional: true

  lifecycle do
    state :pending, initial: true
    state :processing
    state :completed, terminal: true

    event :start_processing, from: :pending, to: :processing
    event :complete, from: :processing, to: :completed

    # 🆕 Deferred side effect runs after transaction commits
    # This prevents SQLite locking when firing transitions on other models
    side_effect :activate_contract_if_linked, on: :complete, defer: true do |record, transition|
      contract = record.test_contract
      next unless contract&.can_activate?

      contract.activate!(
        actor: :system,
        metadata: {
          triggered_by: {
            record_type: record.class.name,
            record_id: record.id,
            event_name: :complete
          }
        }
      )
    end
  end
end
