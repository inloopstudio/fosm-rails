module Fosm
  class Configuration
    # The base controller class the engine's controllers will inherit from.
    # Set this to match your app's ApplicationController.
    attr_accessor :base_controller

    # A callable that authorizes access to the /fosm/admin area.
    # Called via instance_exec in the controller before_action.
    # Example: -> { redirect_to root_path unless current_user&.superadmin? }
    attr_accessor :admin_authorize

    # A callable that authorizes access to individual FOSM apps.
    # Receives the access_level declared in the app definition.
    # Example: ->(level) { authenticate_user! }
    attr_accessor :app_authorize

    # A callable that returns the current user from the controller context.
    # Used for transition log actor tracking.
    attr_accessor :current_user_method

    # Layout used for the admin section
    attr_accessor :admin_layout

    # Default layout used for generated FOSM app views
    attr_accessor :app_layout

    # Strategy for writing transition logs.
    #
    # :sync     — INSERT inside the fire! transaction (strictest consistency, default)
    # :async    — SolidQueue/ActiveJob after commit (non-blocking, recommended for production)
    # :buffered — Bulk INSERT via periodic thread flush (highest throughput, opt-in)
    #
    # Example:
    #   config.transition_log_strategy = :async
    attr_accessor :transition_log_strategy

    def initialize
      @base_controller          = "ApplicationController"
      @admin_authorize          = -> { true } # Override in initializer!
      @app_authorize            = ->(_level) { true } # Override in initializer!
      @current_user_method      = -> { defined?(current_user) ? current_user : nil }
      @admin_layout             = "fosm/application"
      @app_layout               = "application"
      @transition_log_strategy  = :sync
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def config
      configuration
    end
  end
end
