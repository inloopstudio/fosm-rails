module Fosm
  module Admin
    class DashboardController < BaseController
      def index
        @apps = Fosm::Registry.all.map do |slug, model_class|
          lifecycle = model_class.fosm_lifecycle
          state_counts = lifecycle.state_names.index_with { |state_name|
            model_class.where(state: state_name).count
          }
          {
            slug: slug,
            model_class: model_class,
            name: model_class.name.demodulize.humanize,
            state_counts: state_counts,
            total: model_class.count,
            recent_transitions: Fosm::TransitionLog.for_app(model_class).recent.limit(3)
          }
        end

        @total_transitions = Fosm::TransitionLog.count
        @recent_transitions = Fosm::TransitionLog.recent.limit(10)
      end
    end
  end
end
