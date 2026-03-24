class AddStateSnapshotToFosmTransitionLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :fosm_transition_logs, :state_snapshot, :json, default: nil
    add_column :fosm_transition_logs, :snapshot_reason, :string, default: nil
    add_index :fosm_transition_logs, :snapshot_reason, name: "idx_fosm_tl_snapshot_reason"
  end
end
