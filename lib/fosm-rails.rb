require "gemlings"
require "fosm/version"
require "fosm/errors"
require "fosm/configuration"
require "fosm/registry"
require "fosm/current"
require "fosm/transition_buffer"
require "fosm/lifecycle"
require "fosm/agent"
require "fosm/engine"

module Fosm
  # FOSM — Finite Object State Machine for Rails
  #
  # Include Fosm::Lifecycle in any ActiveRecord model to give it a
  # formal, enforced lifecycle with states, events, guards, and side-effects.
  #
  # Quick start:
  #
  #   class Invoice < ApplicationRecord
  #     include Fosm::Lifecycle
  #
  #     lifecycle do
  #       state :draft,     initial: true
  #       state :sent
  #       state :paid,      terminal: true
  #       state :cancelled, terminal: true
  #
  #       event :send_invoice, from: :draft, to: :sent
  #       event :pay,          from: :sent,  to: :paid
  #       event :cancel,       from: [:draft, :sent], to: :cancelled
  #
  #       guard :has_line_items, on: :send_invoice do |invoice|
  #         invoice.amount > 0
  #       end
  #
  #       side_effect :notify_client, on: :send_invoice do |invoice, transition|
  #         InvoiceMailer.send_to_client(invoice).deliver_later
  #       end
  #     end
  #   end
end
