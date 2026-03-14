module Fosm
  module Admin
    class WebhooksController < BaseController
      def index
        @webhooks = Fosm::WebhookSubscription.all.order(:model_class_name, :event_name)
        @apps = Fosm::Registry.all
      end

      def new
        @webhook = Fosm::WebhookSubscription.new
        @apps = Fosm::Registry.all
      end

      def create
        @webhook = Fosm::WebhookSubscription.new(webhook_params)
        if @webhook.save
          redirect_to fosm.admin_webhooks_path, notice: "Webhook created successfully."
        else
          @apps = Fosm::Registry.all
          render :new, status: :unprocessable_entity
        end
      end

      def destroy
        @webhook = Fosm::WebhookSubscription.find(params[:id])
        @webhook.destroy
        redirect_to fosm.admin_webhooks_path, notice: "Webhook removed."
      end

      private

      def webhook_params
        params.require(:fosm_webhook_subscription).permit(:model_class_name, :event_name, :url, :active, :secret_token)
      end
    end
  end
end
