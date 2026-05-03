module Fosm
  # Default data retention period in days (10 years).
  # Override per-project via: config.data_retention_days = 2555  # 7 years
  DATA_RETENTION_DEFAULT_DAYS = 3650

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

    # Queue name for Fosm::WebhookDeliveryJob.
    # Webhook delivery is fire-and-forget; route it to a low-priority queue to
    # avoid competing with user-facing jobs on the default queue.
    #
    # Example:
    #   config.webhook_job_queue = :low
    attr_accessor :webhook_job_queue

    # Queue name for Fosm::TransitionLogJob (used when transition_log_strategy = :async).
    #
    # Example:
    #   config.transition_log_job_queue = :low
    attr_accessor :transition_log_job_queue

    # When false, skip enqueuing WebhookDeliveryJob after every transition.
    # Set to false if your app has no webhook subscriptions to eliminate
    # unnecessary queue writes (reduces SQLite write pressure).
    #
    # Example:
    #   config.webhooks_enabled = false
    attr_accessor :webhooks_enabled

    # Data retention policy in days. Records in an archival terminal state
    # (state name contains "archiv") with an `archived_at` timestamp older
    # than this many days are eligible for purge from the Data Archival admin.
    #
    # Gem default: Fosm::DATA_RETENTION_DEFAULT_DAYS (3650 = 10 years).
    # Override per-project in config/initializers/fosm.rb:
    #   config.data_retention_days = 2555  # 7 years
    attr_accessor :data_retention_days

    def initialize
      @base_controller          = "ApplicationController"
      @admin_authorize          = -> { true } # Override in initializer!
      @app_authorize            = ->(_level) { true } # Override in initializer!
      @current_user_method      = -> { defined?(current_user) ? current_user : nil }
      @admin_layout             = "fosm/application"
      @app_layout               = "application"
      @transition_log_strategy  = :sync
      @webhook_job_queue        = :default
      @transition_log_job_queue = :fosm_audit
      @webhooks_enabled         = true
      @data_retention_days      = Fosm::DATA_RETENTION_DEFAULT_DAYS
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
