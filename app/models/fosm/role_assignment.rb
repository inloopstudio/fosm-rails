module Fosm
  # Persists an actor's role on a FOSM resource.
  #
  # Scopes:
  #   resource_id: nil  → type-level   ("Alice is an :approver for ALL Fosm::Invoice records")
  #   resource_id: "42" → record-level ("Alice is an :approver for Fosm::Invoice #42 only")
  #
  # Role names must match those declared in the model's lifecycle access block.
  # This model does NOT validate role names against the lifecycle (it would create a
  # hard coupling between DB state and code). Invalid role names simply have no effect
  # at runtime because Fosm::Current.roles_for returns them but no permission grants
  # will ever include them.
  class RoleAssignment < Fosm::ApplicationRecord
    self.table_name = "fosm_role_assignments"

    validates :user_type,     presence: true
    validates :user_id,       presence: true
    validates :resource_type, presence: true
    validates :role_name,     presence: true

    validates :user_id, uniqueness: {
      scope: %i[user_type resource_type resource_id role_name],
      message: "already has this role on this resource"
    }

    # Scope: all type-level assignments (applies to every record of resource_type)
    scope :type_level,   -> { where(resource_id: nil) }
    # Scope: all record-level assignments (pinned to a specific record)
    scope :record_level, -> { where.not(resource_id: nil) }
    # Scope: for a specific FOSM model class
    scope :for_resource_type, ->(model_class) { where(resource_type: model_class.to_s) }
    # Scope: for a specific actor
    scope :for_user, ->(user) { where(user_type: user.class.name, user_id: user.id.to_s) }

    # Try to resolve the actor object (may return nil if class no longer exists)
    def actor
      user_type.constantize.find_by(id: user_id)
    rescue NameError
      nil
    end

    # Human-readable display label for the actor
    def actor_label
      a = actor
      return "#{user_type}##{user_id}" unless a
      a.respond_to?(:email) ? a.email : a.to_s
    end

    def record_level?
      resource_id.present?
    end

    def type_level?
      resource_id.nil?
    end

    def scope_label
      record_level? ? "#{resource_type}##{resource_id}" : "all #{resource_type.demodulize.pluralize}"
    end
  end
end
