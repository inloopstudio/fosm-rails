module Fosm
  # Admin-configured webhooks that fire on specific FOSM transitions.
  class WebhookSubscription < ApplicationRecord
    self.table_name = "fosm_webhook_subscriptions"

    validates :model_class_name, presence: true
    validates :event_name, presence: true
    validates :url, presence: true, format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]) }

    scope :active, -> { where(active: true) }
    scope :for_event, ->(model_class, event) {
      where(model_class_name: model_class.to_s, event_name: event.to_s).active
    }
  end
end
