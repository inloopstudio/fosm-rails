class CreateFosmTransitionLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :fosm_transition_logs do |t|
      t.string  :record_type,  null: false
      t.string  :record_id,    null: false
      t.string  :event_name,   null: false
      t.string  :from_state,   null: false
      t.string  :to_state,     null: false
      t.string  :actor_type
      t.string  :actor_id
      t.string  :actor_label
      t.column  :metadata, :json, default: {}  # use json (works for SQLite + PostgreSQL; jsonb on PG only)

      # Intentionally no updated_at — this is an immutable log
      t.datetime :created_at,  null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :fosm_transition_logs, [ :record_type, :record_id ], name: "idx_fosm_tl_record"
    add_index :fosm_transition_logs, :event_name, name: "idx_fosm_tl_event"
    add_index :fosm_transition_logs, :created_at, name: "idx_fosm_tl_created_at"
    add_index :fosm_transition_logs, :actor_label, name: "idx_fosm_tl_actor"
  end
end
