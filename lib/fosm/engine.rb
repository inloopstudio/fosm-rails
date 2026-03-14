require "rails/engine"

module Fosm
  class Engine < ::Rails::Engine
    isolate_namespace Fosm

    config.generators do |g|
      g.test_framework :minitest
    end

    # Expose configuration
    initializer "fosm.configuration" do
      # Host app can configure via config/initializers/fosm.rb
      # Run: rails fosm:install:migrations && rails db:migrate
    end

    # Auto-register all Fosm models with the registry after app loads.
    # Use ::Rails to avoid ambiguity with Fosm::Rails module.
    config.after_initialize do
      ::Rails.application.eager_load! if ::Rails.env.development? && !::Rails.application.config.eager_load

      ObjectSpace.each_object(Class).select { |klass|
        klass < ActiveRecord::Base &&
          klass.name&.start_with?("Fosm::") &&
          klass.respond_to?(:fosm_lifecycle) &&
          klass.fosm_lifecycle.present?
      }.each do |klass|
        slug = klass.name.demodulize.underscore.dasherize
        Fosm::Registry.register(klass, slug: slug)
      end
    end
  end
end
