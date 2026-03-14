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
  end
end
