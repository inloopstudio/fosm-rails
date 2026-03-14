module Fosm
  # Delivers webhook payloads to configured endpoints when FOSM events fire.
  # Runs asynchronously after the transition completes.
  class WebhookDeliveryJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(record_type:, record_id:, event_name:, from_state:, to_state:, metadata: {})
      subscriptions = Fosm::WebhookSubscription.for_event(record_type, event_name)
      return if subscriptions.none?

      payload = {
        event: event_name,
        record_type: record_type,
        record_id: record_id,
        from_state: from_state,
        to_state: to_state,
        fired_at: Time.current.iso8601,
        metadata: metadata
      }

      subscriptions.each do |subscription|
        deliver(subscription, payload)
      end
    end

    private

    def deliver(subscription, payload)
      uri = URI.parse(subscription.url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 5
      http.read_timeout = 10

      request = Net::HTTP::Post.new(uri.request_uri, {
        "Content-Type" => "application/json",
        "X-FOSM-Event" => payload[:event],
        "X-FOSM-Record-Type" => payload[:record_type],
        "User-Agent" => "fosm-rails/#{Fosm::VERSION}"
      })

      if subscription.secret_token.present?
        signature = OpenSSL::HMAC.hexdigest("SHA256", subscription.secret_token, payload.to_json)
        request["X-FOSM-Signature"] = "sha256=#{signature}"
      end

      request.body = payload.to_json
      http.request(request)
    end
  end
end
