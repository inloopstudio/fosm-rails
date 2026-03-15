require_relative "role_definition"

module Fosm
  module Lifecycle
    # Holds the access control definition for a FOSM lifecycle.
    #
    # Activated by declaring an `access do ... end` block inside `lifecycle do`.
    # Once declared, RBAC is enforced: deny-by-default, only granted capabilities work.
    # Without an access block, all authenticated actors have full access (open-by-default).
    #
    # Design principles:
    #   - Rules live IN the lifecycle definition, same file as states and events
    #   - One default role is auto-assigned to the record creator on creation
    #   - Superadmin bypasses all checks (like root in Linux)
    #   - :system and :agent symbols bypass RBAC (internal/programmatic actors)
    class AccessDefinition
      attr_reader :roles

      def initialize
        @roles        = []
        @default_role = nil
      end

      # DSL: declare a role within the access block
      #
      # @param name [Symbol] role name (e.g. :owner, :approver, :viewer)
      # @param default [Boolean] if true, auto-assigned to the record creator on create
      # @param block [Proc] permissions block where `can` is called
      def role(name, default: false, &block)
        role_def = RoleDefinition.new(name: name)
        role_def.instance_eval(&block) if block_given?
        @roles << role_def
        @default_role = name.to_sym if default
        role_def
      end

      # The role name that gets auto-assigned to the creator when a record is created.
      # nil if no default was declared.
      def default_role
        @default_role
      end

      # Returns the role names permitted to fire a given lifecycle event
      def roles_for_event(event_name)
        @roles.select { |r| r.can_event?(event_name.to_sym) }.map(&:name)
      end

      # Returns the role names permitted to perform a CRUD action (:create/:read/:update/:delete)
      def roles_for_crud(action)
        @roles.select { |r| r.can_crud?(action.to_sym) }.map(&:name)
      end

      def find_role(name)
        @roles.find { |r| r.name == name.to_sym }
      end

      def role_names
        @roles.map(&:name)
      end
    end
  end
end
