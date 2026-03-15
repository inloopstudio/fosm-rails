class CreateFosmRoleAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :fosm_role_assignments do |t|
      # The actor who holds this role (polymorphic — any user model)
      t.string :user_type,  null: false
      t.string :user_id,    null: false

      # The resource this role applies to (polymorphic — any FOSM model)
      t.string :resource_type, null: false
      # resource_id = nil  → type-level assignment (applies to ALL records of resource_type)
      # resource_id = "42" → record-level assignment (applies only to that specific record)
      t.string :resource_id

      # Role name as declared in the lifecycle access block (e.g. "owner", "approver")
      t.string :role_name, null: false

      # Audit: who granted this role (nullable — system/migration grants have no granter)
      t.string :granted_by_type
      t.string :granted_by_id

      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      # Intentionally no updated_at — role assignments are create/destroy only
    end

    # Fast lookup: "what roles does User#42 have on Fosm::Invoice?" (per-request cache load)
    add_index :fosm_role_assignments,
              %i[user_type user_id resource_type resource_id],
              name: "idx_fosm_roles_user_resource"

    # Fast lookup: "which users have the :approver role on Fosm::Invoice?" (admin UI)
    add_index :fosm_role_assignments,
              %i[resource_type resource_id role_name],
              name: "idx_fosm_roles_resource_role"

    # Uniqueness: one role per user per resource (type-level or record-level)
    add_index :fosm_role_assignments,
              %i[user_type user_id resource_type resource_id role_name],
              unique: true,
              name: "idx_fosm_roles_unique"
  end
end
