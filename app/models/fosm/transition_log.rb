module Fosm
  # Immutable audit trail of every FOSM state transition.
  # Records are never updated or deleted — this is an append-only log.
  class TransitionLog < ApplicationRecord
    self.table_name = "fosm_transition_logs"

    # Immutability: prevent any updates or deletions
    before_update { raise ActiveRecord::ReadOnlyRecord, "Fosm::TransitionLog is immutable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "Fosm::TransitionLog records cannot be deleted" }

    validates :record_type, :record_id, :event_name, :from_state, :to_state, presence: true

    scope :recent, -> { order(created_at: :desc) }
    scope :for_record, ->(type, id) { where(record_type: type, record_id: id.to_s) }
    scope :for_app, ->(model_class) { where(record_type: model_class.name) }
    scope :by_event, ->(event) { where(event_name: event.to_s) }
    scope :by_actor_type, ->(type) { where(actor_type: type) }

    def by_agent?
      actor_type == "symbol" && actor_label == "agent"
    end

    def by_human?
      !by_agent? && actor_id.present?
    end
  end
end
