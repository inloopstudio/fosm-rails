module Fosm
  # Global registry of all FOSM app model classes.
  # Models auto-register when they include Fosm::Lifecycle and call lifecycle { }.
  module Registry
    @registered = {}

    class << self
      def register(model_class, slug:)
        unless slug.match?(/\A[a-z0-9_]+\z/)
          raise ArgumentError, "FOSM slug must contain only lowercase letters, digits, and underscores " \
                               "(got: #{slug.inspect} for #{model_class.name}). " \
                               "Hyphens are not allowed because slugs are used to construct Ruby route helper names."
        end
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
