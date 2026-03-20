module Fosm
  module Lifecycle
    class SideEffectDefinition
      attr_reader :name, :rescue_strategy, :deferred

      def initialize(name:, rescue_strategy: :raise, defer: false, &block)
        @name = name
        @rescue_strategy = rescue_strategy
        @deferred = defer
        @block = block
      end

      def call(record, transition)
        @block.call(record, transition)
      rescue => e
        handle_error(e)
      end

      def deferred?
        @deferred
      end

      private

      def handle_error(error)
        case @rescue_strategy
        when :raise
          raise error
        when :log
          logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
          logger ||= Logger.new(STDOUT)
          logger.error("[Fosm] Side effect '#{@name}' failed: #{error.message}")
          nil
        when :ignore
          nil
        else
          raise error
        end
      end
    end
  end
end
