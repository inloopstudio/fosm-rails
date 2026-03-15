module Fosm
  # Immutable append-only audit log for RBAC operations.
  #
  # Records every grant and revoke action so there is a complete audit trail
  # of who had what access, when, and who authorized it.
  #
  # Written asynchronously via Fosm::AccessEventJob (non-blocking).
  class AccessEvent < Fosm::ApplicationRecord
    self.table_name = "fosm_access_events"

    ACTIONS = %w[grant revoke auto_grant].freeze

    validates :action,        presence: true, inclusion: { in: ACTIONS }
    validates :user_type,     presence: true
    validates :user_id,       presence: true
    validates :resource_type, presence: true
    validates :role_name,     presence: true

    # Immutability: access events are append-only, never modified or deleted
    before_update { raise ActiveRecord::ReadOnlyRecord, "Fosm::AccessEvent records are immutable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "Fosm::AccessEvent records are immutable" }

    scope :recent,     -> { order(created_at: :desc) }
    scope :grants,     -> { where(action: "grant") }
    scope :revokes,    -> { where(action: "revoke") }
    scope :for_user,   ->(user) { where(user_type: user.class.name, user_id: user.id.to_s) }
    scope :for_resource_type, ->(model_class) { where(resource_type: model_class.to_s) }

    def grant?      = action == "grant"
    def revoke?     = action == "revoke"
    def auto_grant? = action == "auto_grant"
  end
end
