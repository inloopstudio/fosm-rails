# frozen_string_literal: true

# Test model for FOSM lifecycle functionality
class TestInvoice < ApplicationRecord
  include Fosm::Lifecycle

  self.table_name = "test_invoices"

  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    state :refunded, terminal: true

    event :send_invoice, from: :draft, to: :sent

    # Side effects defined at top level with on: parameter and block
    side_effect :send_notification, on: :send_invoice do |record, transition|
      record.send_notification
    end

    # Guards defined at top level with on: parameter
    guard :has_line_items, on: :send_invoice do |inv|
      inv.line_items_count > 0 || "At least one line item required"
    end

    guard :valid_recipient, on: :send_invoice do |inv|
      if inv.recipient_email.blank?
        "Email is blank"
      elsif !inv.recipient_email.include?("@")
        "Invalid email format"
      else
        true
      end
    end

    event :pay, from: :sent, to: :paid

    guard :payment_received, on: :pay do |inv|
      inv.payment_received? || "Payment not yet received"
    end

    # 🆕 Compensating event from terminal state
    event :refund, from: :paid, to: :refunded, force: true

    # 🆕 Side effect with error handling
    event :cancel, from: [ :draft, :sent ], to: :draft
    side_effect :notify_cancellation, on: :cancel, rescue: :log do |record, transition|
      record.notify_cancellation
    end
    side_effect :update_inventory, on: :cancel, rescue: :ignore do |record, transition|
      record.update_inventory
    end
  end

  # Helper methods for guards
  def line_items_count
    read_attribute(:line_items_count) || 0
  end

  def payment_received?
    read_attribute(:payment_received) || false
  end

  def recipient_email
    read_attribute(:recipient_email)
  end

  # Tracking for side effects
  attr_accessor :notification_sent, :inventory_updated, :cancellation_notified

  def send_notification(record = nil, transition = nil)
    @notification_sent = true
  end

  def notify_cancellation(record = nil, transition = nil)
    raise "Simulated failure" if defined?(@should_fail_cancellation) && @should_fail_cancellation
    @cancellation_notified = true
  end

  def update_inventory(record = nil, transition = nil)
    @inventory_updated = true
  end
end
