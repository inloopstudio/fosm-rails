module Fosm
  module Lifecycle
    class SideEffectDefinition
      attr_reader :name, :deferred

      def initialize(name:, defer: false, &block)
        @name = name
        @deferred = defer
        @block = block
      end

      def call(record, transition)
        @block.call(record, transition)
      end

      def deferred?
        @deferred
      end
    end
  end
end
