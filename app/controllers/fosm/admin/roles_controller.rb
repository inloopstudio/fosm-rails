module Fosm
  module Admin
    class RolesController < Fosm::Admin::BaseController
      def index
        @assignments     = Fosm::RoleAssignment.order(created_at: :desc)
        @access_events   = Fosm::AccessEvent.recent.limit(20)
        @apps            = Fosm::Registry.all
      end

      def new
        @assignment = Fosm::RoleAssignment.new
        @apps       = Fosm::Registry.all
      end

      def create
        @assignment = Fosm::RoleAssignment.new(assignment_params)
        @assignment.granted_by_type = fosm_current_user&.class&.name
        @assignment.granted_by_id   = fosm_current_user&.id&.to_s

        if @assignment.save
          Fosm::AccessEventJob.perform_later({
            "action"             => "grant",
            "user_type"          => @assignment.user_type,
            "user_id"            => @assignment.user_id,
            "user_label"         => resolve_user_label(@assignment.user_type, @assignment.user_id),
            "resource_type"      => @assignment.resource_type,
            "resource_id"        => @assignment.resource_id,
            "role_name"          => @assignment.role_name,
            "performed_by_type"  => fosm_current_user&.class&.name,
            "performed_by_id"    => fosm_current_user&.id&.to_s,
            "performed_by_label" => (fosm_current_user.respond_to?(:email) ? fosm_current_user.email : fosm_current_user.to_s)
          })

          # Invalidate the per-request RBAC cache for the affected user so their
          # new role is visible immediately in the same request (unlikely but correct)
          user = @assignment.actor
          Fosm::Current.invalidate_for(user) if user

          redirect_to fosm.admin_roles_path, notice: "Role :#{@assignment.role_name} granted to #{@assignment.actor_label}."
        else
          @apps = Fosm::Registry.all
          render :new, status: :unprocessable_entity
        end
      end

      def users_search
        q         = params[:q].to_s.strip
        user_type = params[:user_type].presence || "User"
        results   = []

        begin
          klass = user_type.constantize
          scope = klass.all

          if q.present?
            searchable = klass.column_names & %w[email name]
            if searchable.any?
              conditions = searchable.map { |col| "lower(#{col}) LIKE :q" }.join(" OR ")
              scope = scope.where(conditions, q: "%#{q.downcase}%")
            end
          end

          results = scope.limit(10).map do |user|
            label = [
              (user.name if user.respond_to?(:name) && user.name.present?),
              (user.email if user.respond_to?(:email))
            ].compact.join(" — ")
            { id: user.id.to_s, label: label }
          end
        rescue NameError
          # unknown user_type — return empty
        end

        render json: results
      end

      def destroy
        @assignment = Fosm::RoleAssignment.find(params[:id])

        Fosm::AccessEventJob.perform_later({
          "action"             => "revoke",
          "user_type"          => @assignment.user_type,
          "user_id"            => @assignment.user_id,
          "user_label"         => @assignment.actor_label,
          "resource_type"      => @assignment.resource_type,
          "resource_id"        => @assignment.resource_id,
          "role_name"          => @assignment.role_name,
          "performed_by_type"  => fosm_current_user&.class&.name,
          "performed_by_id"    => fosm_current_user&.id&.to_s,
          "performed_by_label" => (fosm_current_user.respond_to?(:email) ? fosm_current_user.email : fosm_current_user.to_s)
        })

        user = @assignment.actor
        @assignment.destroy!
        Fosm::Current.invalidate_for(user) if user

        redirect_to fosm.admin_roles_path, notice: "Role revoked."
      end

      private

      def assignment_params
        params.require(:fosm_role_assignment).permit(
          :user_type, :user_id, :resource_type, :resource_id, :role_name
        )
      end

      def resolve_user_label(user_type, user_id)
        user = user_type.constantize.find_by(id: user_id)
        return "#{user_type}##{user_id}" unless user
        user.respond_to?(:email) ? user.email : user.to_s
      rescue NameError
        "#{user_type}##{user_id}"
      end
    end
  end
end
