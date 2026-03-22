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

      # 🆕 Evaluate guard and return [allowed, reason] tuple
      # Supports: true/false (legacy), String (failure reason), [:fail, reason]
      def evaluate(record)
        result = call(record)

        case result
        when true
          [ true, nil ]
        when false
          [ false, nil ]
        when String
          # String is treated as failure reason
          [ false, result ]
        when Array
          result[0] == :fail ? [ false, result[1] ] : [ true, nil ]
        else
          # 🆕 Any other truthy value is treated as passing
          # Only false/nil fails; everything else passes
          result ? [ true, nil ] : [ false, nil ]
        end
      end
    end
  end
end
