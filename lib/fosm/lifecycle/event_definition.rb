module Fosm
  module Lifecycle
    class EventDefinition
      attr_reader :name, :from_states, :to_state, :guards, :side_effects, :force

      def initialize(name:, from:, to:, force: false)
        @name = name.to_sym
        @from_states = Array(from).map(&:to_sym)
        @to_state = to.to_sym
        @force = force
        @guards = []
        @side_effects = []
      end

      def add_guard(guard_def)
        @guards << guard_def
      end

      def add_side_effect(side_effect_def)
        @side_effects << side_effect_def
      end

      def valid_from?(state)
        @from_states.include?(state.to_sym)
      end

      # 🆕 Whether this event can bypass terminal state check
      def force?
        @force
      end
    end
  end
end
