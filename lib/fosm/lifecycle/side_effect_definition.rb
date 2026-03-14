module Fosm
  module Lifecycle
    class SideEffectDefinition
      attr_reader :name

      def initialize(name:, &block)
        @name = name
        @block = block
      end

      def call(record, transition)
        @block.call(record, transition)
      end
    end
  end
end
