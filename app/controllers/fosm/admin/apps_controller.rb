module Fosm
  module Admin
    class AppsController < BaseController
      def index
        redirect_to fosm.admin_root_path
      end

      def show
        @slug = params[:slug]
        @model_class = Fosm::Registry.find(@slug)
        return render plain: "FOSM app '#{@slug}' not found", status: :not_found unless @model_class

        @lifecycle = @model_class.fosm_lifecycle
        @diagram_data = @lifecycle.to_diagram_data

        @state_counts = @lifecycle.state_names.index_with { |s| @model_class.where(state: s).count }
        @recent_transitions = Fosm::TransitionLog.for_app(@model_class).recent.limit(20)
        @total = @model_class.count

        # Stuck records: in a non-terminal state, no transition in 7 days
        non_terminal_states = @lifecycle.states.reject(&:terminal?).map { |s| s.name.to_s }
        # Load record_ids as array and cast to match the model's PK type (record_id
        # is stored as varchar in transition_logs but the model PK may be bigint).
        pk_type = @model_class.columns_hash[@model_class.primary_key]&.sql_type_metadata&.type
        stuck_ids = Fosm::TransitionLog.for_app(@model_class)
                                        .where("created_at < ?", 7.days.ago)
                                        .distinct
                                        .pluck(:record_id)
        stuck_ids = stuck_ids.map(&:to_i) if pk_type == :integer
        @stuck_count = @model_class.where(state: non_terminal_states).where.not(id: stuck_ids).count
      end
    end
  end
end
