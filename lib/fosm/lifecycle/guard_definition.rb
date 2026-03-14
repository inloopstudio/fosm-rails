module Fosm
  module Lifecycle
    class GuardDefinition
      attr_reader :name

      def initialize(name:, &block)
        @name = name
        @block = block
      end

      def call(record)
        @block.call(record)
      end
    end
  end
end
