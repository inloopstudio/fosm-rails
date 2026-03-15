module Fosm
  class ApplicationController < Fosm.config.base_controller.constantize
    protect_from_forgery with: :exception

    # Call this in generated app controllers to use host app routes instead of
    # the engine's isolated routes. FOSM apps define routes in the host app
    # (config/routes/fosm.rb), so controllers need host app route context.
    #
    # `include url_helpers` triggers the module's `included` hook which calls
    # `redefine_singleton_method(:_routes) { routes }` — this overrides the
    # engine's _routes with the host app's routes for this controller.
    def self.use_host_routes!
      include ::Rails.application.routes.url_helpers
      helper ::Rails.application.routes.url_helpers
    end

    private

    def fosm_current_user
      instance_exec(&Fosm.config.current_user_method)
    end

    # Check CRUD permissions for the current actor.
    # Raises Fosm::AccessDenied if the actor lacks the required role.
    # No-ops if the lifecycle has no access block declared (open-by-default).
    #
    # @param action  [Symbol] :create, :read, :update, or :delete
    # @param subject [ActiveRecord::Base, Class] a record or model class
    #
    # Example usage in generated controllers:
    #   before_action -> { fosm_authorize!(:read,   Fosm::Invoice) }, only: [:index, :show]
    #   before_action -> { fosm_authorize!(:create, Fosm::Invoice) }, only: [:new, :create]
    #   before_action -> { fosm_authorize!(:update, @record) },       only: [:edit, :update]
    #   before_action -> { fosm_authorize!(:delete, @record) },       only: [:destroy]
    def fosm_authorize!(action, subject)
      model_class = subject.is_a?(Class) ? subject : subject.class
      lifecycle   = model_class.try(:fosm_lifecycle)
      return unless lifecycle&.access_defined?

      actor = fosm_current_user
      # Bypass for superadmin and nil/symbol actors (mirrors fire! logic)
      return if actor.nil?
      return if actor.is_a?(Symbol)
      return if actor.respond_to?(:superadmin?) && actor.superadmin?

      record_id       = subject.is_a?(ActiveRecord::Base) ? subject.id : nil
      actor_roles     = Fosm::Current.roles_for(actor, model_class, record_id)
      permitted_roles = lifecycle.access_definition.roles_for_crud(action)

      unless (actor_roles & permitted_roles).any?
        raise Fosm::AccessDenied.new(action, actor)
      end
    end
  end
end
