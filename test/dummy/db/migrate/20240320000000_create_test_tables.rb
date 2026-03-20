class CreateTestTables < ActiveRecord::Migration[7.0]
  def change
    create_table :test_invoices do |t|
      t.string :state, default: "draft"
      t.string :recipient_email
      t.integer :line_items_count, default: 0
      t.boolean :payment_received, default: false
      t.timestamps
    end
    
    create_table :test_contracts do |t|
      t.string :state, default: "draft"
      t.timestamps
    end
    
    create_table :test_orders do |t|
      t.string :state, default: "pending"
      t.references :test_contract, foreign_key: true
      t.timestamps
    end
  end
end
