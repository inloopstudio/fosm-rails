module Fosm
  module Lifecycle
    # Describes what a named role is permitted to do on a FOSM object.
    #
    # CRUD permissions and lifecycle event permissions are tracked separately.
    # A role grants read access to see the object, write access to mutate it,
    # and specific event access to fire lifecycle transitions.
    #
    # Usage (inside an access block):
    #
    #   role :owner, default: true do
    #     can :crud                   # shorthand: create + read + update + delete
    #     can :send_invoice, :cancel  # specific lifecycle events
    #   end
    #
    #   role :approver do
    #     can :read                   # view only
    #     can :pay                    # one lifecycle event
    #   end
    class RoleDefinition
      CRUD_ACTIONS    = %i[create read update delete].freeze
      CRUD_SHORTHAND  = :crud

      attr_reader :name

      def initialize(name:)
        @name             = name.to_sym
        @crud_permissions = Set.new
        @event_permissions = Set.new
      end

      # Grant one or more permissions to this role.
      #
      # @param actions [Array<Symbol>] :crud, :create/:read/:update/:delete, or any event name
      def can(*actions)
        actions.each do |action|
          sym = action.to_sym
          if sym == CRUD_SHORTHAND
            @crud_permissions += CRUD_ACTIONS
          elsif CRUD_ACTIONS.include?(sym)
            @crud_permissions << sym
          else
            @event_permissions << sym
          end
        end
      end

      def can_crud?(action)
        @crud_permissions.include?(action.to_sym)
      end

      def can_event?(event_name)
        @event_permissions.include?(event_name.to_sym)
      end

      # All permissions as a flat array (for display / introspection)
      def all_permissions
        (@crud_permissions + @event_permissions).sort
      end

      def crud_permissions
        @crud_permissions.to_a.sort
      end

      def event_permissions
        @event_permissions.to_a.sort
      end
    end
  end
end
