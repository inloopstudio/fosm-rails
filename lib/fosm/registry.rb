module Fosm
  # Global registry of all FOSM app model classes.
  # Models auto-register when they include Fosm::Lifecycle and call lifecycle { }.
  module Registry
    @registered = {}

    class << self
      def register(model_class, slug:)
        @registered[slug] = model_class
      end

      def all
        @registered
      end

      def find(slug)
        @registered[slug]
      end

      def model_classes
        @registered.values
      end

      def slugs
        @registered.keys
      end

      def each(&block)
        @registered.each(&block)
      end
    end
  end
end
