class CreateFosmWebhookSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :fosm_webhook_subscriptions do |t|
      t.string  :model_class_name, null: false
      t.string  :event_name,       null: false
      t.string  :url,              null: false
      t.boolean :active,           default: true, null: false
      t.string  :secret_token

      t.timestamps
    end

    add_index :fosm_webhook_subscriptions, [ :model_class_name, :event_name ], name: "idx_fosm_webhooks_model_event"
    add_index :fosm_webhook_subscriptions, :active, name: "idx_fosm_webhooks_active"
  end
end
