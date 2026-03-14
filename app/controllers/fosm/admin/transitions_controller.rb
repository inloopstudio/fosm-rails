module Fosm
  module Admin
    class TransitionsController < BaseController
      def index
        @transitions = Fosm::TransitionLog.recent

        @transitions = @transitions.where(record_type: params[:model]) if params[:model].present?
        @transitions = @transitions.where(event_name: params[:event]) if params[:event].present?
        @transitions = @transitions.where(actor_type: "symbol", actor_label: "agent") if params[:actor] == "agent"
        @transitions = @transitions.where.not(actor_type: "symbol") if params[:actor] == "human"

        @per_page = 50
        @current_page = [params[:page].to_i, 1].max
        @total_count = @transitions.count
        @total_pages = (@total_count / @per_page.to_f).ceil
        @transitions = @transitions.limit(@per_page).offset((@current_page - 1) * @per_page)

        @model_names = Fosm::Registry.model_classes.map(&:name).sort
      end
    end
  end
end
