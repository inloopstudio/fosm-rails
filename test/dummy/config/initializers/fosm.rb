# frozen_string_literal: true

# Test environment configuration for FOSM
Fosm.configure do |config|
  # 🆕 Use async strategy in tests to avoid SQLite locking issues
  # The sync strategy creates TransitionLog inside the transaction,
  # which causes database locks in SQLite during concurrent access.
  config.transition_log_strategy = :async
end

# Disable webhook delivery in tests
module Fosm
  class WebhookDeliveryJob
    def self.perform_later(*args)
      # No-op in tests
    end
  end
end
