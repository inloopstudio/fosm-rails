module Fosm
  module Lifecycle
    class StateDefinition
      attr_reader :name

      def initialize(name:, initial: false, terminal: false)
        @name = name.to_sym
        @initial = initial
        @terminal = terminal
      end

      def initial? = @initial
      def terminal? = @terminal

      def to_s = @name.to_s
    end
  end
end
