module Fosm
  # Writes an access event audit record asynchronously.
  # Called whenever a role is granted or revoked.
  class AccessEventJob < Fosm::ApplicationJob
    queue_as :fosm_audit

    # @param event_data [Hash] all columns for the access event row (string keys)
    def perform(event_data)
      Fosm::AccessEvent.create!(event_data)
    end
  end
end
