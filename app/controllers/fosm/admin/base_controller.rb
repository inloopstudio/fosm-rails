module Fosm
  module Admin
    class BaseController < Fosm::ApplicationController
      layout -> { Fosm.config.admin_layout }

      before_action :fosm_authorize_admin

      private

      def fosm_authorize_admin
        instance_exec(&Fosm.config.admin_authorize)
      end
    end
  end
end
