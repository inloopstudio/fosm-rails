# frozen_string_literal: true

# Test models for FOSM snapshot functionality
module TestModels
  class SnapshotInvoice < ApplicationRecord
    include Fosm::Lifecycle

    self.table_name = "test_invoices"

    lifecycle do
      snapshot :every
      snapshot_attributes :line_items_count, :recipient_email, :state, :payment_received

      state :draft, initial: true
      state :sent
      state :paid, terminal: true

      event :send_invoice, from: :draft, to: :sent
      event :mark_paid, from: :sent, to: :paid
    end
  end

  class TerminalSnapshotInvoice < ApplicationRecord
    include Fosm::Lifecycle

    self.table_name = "test_invoices"

    lifecycle do
      snapshot :terminal
      snapshot_attributes :line_items_count, :recipient_email

      state :draft, initial: true
      state :sent
      state :cancelled, terminal: true

      event :send_invoice, from: :draft, to: :sent
      event :cancel, from: [ :draft, :sent ], to: :cancelled
    end
  end

  class ManualSnapshotInvoice < ApplicationRecord
    include Fosm::Lifecycle

    self.table_name = "test_invoices"

    lifecycle do
      snapshot :manual
      snapshot_attributes :line_items_count, :recipient_email

      state :draft, initial: true
      state :sent
      state :paid, terminal: true

      event :send_invoice, from: :draft, to: :sent
      event :mark_paid, from: :sent, to: :paid
    end
  end

  class SelectiveSnapshotInvoice < ApplicationRecord
    include Fosm::Lifecycle

    self.table_name = "test_invoices"

    lifecycle do
      snapshot :every
      snapshot_attributes :line_items_count, :recipient_email  # Only these two fields

      state :draft, initial: true
      state :sent

      event :send_invoice, from: :draft, to: :sent
    end
  end

  class CountBasedSnapshotInvoice < ApplicationRecord
    include Fosm::Lifecycle

    self.table_name = "test_invoices"

    lifecycle do
      snapshot every: 3  # Snapshot every 3 transitions
      snapshot_attributes :line_items_count, :recipient_email

      state :draft, initial: true
      state :review
      state :approved
      state :sent
      state :paid, terminal: true

      event :submit, from: :draft, to: :review
      event :approve, from: :review, to: :approved
      event :send_invoice, from: :approved, to: :sent
      event :mark_paid, from: :sent, to: :paid
    end
  end

  class TimeBasedSnapshotInvoice < ApplicationRecord
    include Fosm::Lifecycle

    self.table_name = "test_invoices"

    lifecycle do
      snapshot time: 1  # Snapshot if > 1 second since last (for testing)
      snapshot_attributes :line_items_count, :recipient_email

      state :draft, initial: true
      state :sent

      event :send_invoice, from: :draft, to: :sent
    end
  end
end
