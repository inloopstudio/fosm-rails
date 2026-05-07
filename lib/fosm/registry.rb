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
        @registered.values.map { |klass| klass.name.constantize rescue klass }
      end

      def slug_for(model_class)
        target_name = model_class.name
        @registered.each { |slug, klass| return slug if klass.name == target_name }
        nil
      end

      def slugs
        @registered.keys
      end

      def each(&block)
        @registered.each(&block)
      end

      # Remove all registered entries.
      # Called by to_prepare in development so stale class references are
      # replaced after Rails reloads the application code.
      def clear!
        @registered = {}
      end

      # Scan ObjectSpace for all ActiveRecord subclasses that include
      # Fosm::Lifecycle and register them.  Calling this after clear! is
      # equivalent to the boot-time registration that after_initialize performs.
      def repopulate!
        ObjectSpace.each_object(Class).select { |klass|
          klass < ActiveRecord::Base &&
            klass.name&.start_with?("Fosm::") &&
            klass.respond_to?(:fosm_lifecycle) &&
            klass.fosm_lifecycle.present?
        }.each do |klass|
          slug = klass.name.demodulize.underscore
          register(klass, slug: slug)
        end
      end
    end
  end
end
