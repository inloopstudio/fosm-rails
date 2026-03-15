class CreateFosmAccessEvents < ActiveRecord::Migration[8.1]
  def change
    # Immutable audit log for RBAC operations: who was granted/revoked what role, and by whom.
    # Written asynchronously (via ActiveJob) and never updated or deleted.
    create_table :fosm_access_events do |t|
      t.string :action,        null: false  # "grant" | "revoke" | "auto_grant"

      t.string :user_type,     null: false  # actor who received/lost the role
      t.string :user_id,       null: false
      t.string :user_label                  # email or display name at time of event

      t.string :resource_type, null: false  # "Fosm::Invoice"
      t.string :resource_id                 # nil = type-level

      t.string :role_name,     null: false  # "owner", "approver", etc.

      t.string :performed_by_type           # who performed the grant/revoke
      t.string :performed_by_id
      t.string :performed_by_label

      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      # No updated_at — append-only
    end

    add_index :fosm_access_events, %i[user_type user_id],         name: "idx_fosm_ae_user"
    add_index :fosm_access_events, %i[resource_type resource_id], name: "idx_fosm_ae_resource"
    add_index :fosm_access_events, :action,                       name: "idx_fosm_ae_action"
    add_index :fosm_access_events, :created_at,                   name: "idx_fosm_ae_created_at"
  end
end
