require_relative "lifecycle/definition"
require_relative "current"

module Fosm
  module Lifecycle
    extend ActiveSupport::Concern

    included do
      # The lifecycle definition is stored as a class attribute
      class_attribute :fosm_lifecycle, instance_accessor: false

      # Validations
      before_validation :fosm_set_initial_state, on: :create
      validates :state, inclusion: { in: ->(record) { record.class.fosm_lifecycle&.state_names || [] } },
                        allow_blank: false,
                        if: -> { self.class.fosm_lifecycle.present? }

      # Auto-assign the default role to the record creator after creation
      after_create :fosm_auto_assign_default_role
    end

    class_methods do
      # The lifecycle DSL entry point
      def lifecycle(&block)
        self.fosm_lifecycle = Fosm::Lifecycle::Definition.new
        self.fosm_lifecycle.instance_eval(&block)

        # Generate state predicate methods: invoice.draft? => true
        fosm_lifecycle.states.each do |state_def|
          define_method(:"#{state_def.name}?") do
            self.state.to_s == state_def.name.to_s
          end
        end

        # Generate dynamic bang methods per event: invoice.send_invoice!(actor: user)
        fosm_lifecycle.events.each do |event_def|
          define_method(:"#{event_def.name}!") do |actor: nil, metadata: {}|
            fire!(event_def.name, actor: actor, metadata: metadata)
          end

          define_method(:"can_#{event_def.name}?") do
            can_fire?(event_def.name)
          end
        end
      end
    end

    # Fire a lifecycle event. This is the ONLY way to change state.
    #
    # Execution order (all in-memory checks first, then one DB write):
    #   1. Validate event exists
    #   2. Check current state is not terminal
    #   3. Check event is valid from current state
    #   4. Run guards (pure in-memory functions)
    #   5. RBAC check (O(1) cache lookup after first request hit)
    #   6. BEGIN TRANSACTION: UPDATE state, run side effects
    #                         [optionally INSERT log if strategy == :sync]
    #      COMMIT
    #   7. Emit transition log (:async or :buffered, non-blocking)
    #   8. Enqueue webhook delivery (always async)
    #
    # @param event_name [Symbol, String] the event to fire
    # @param actor [Object] who/what is firing the event (User, or :system/:agent symbol)
    # @param metadata [Hash] optional metadata stored in the transition log
    # @raise [Fosm::UnknownEvent]    if event doesn't exist
    # @raise [Fosm::TerminalState]   if current state is terminal
    # @raise [Fosm::InvalidTransition] if current state doesn't allow this event
    # @raise [Fosm::GuardFailed]     if a guard blocks the transition
    # @raise [Fosm::AccessDenied]    if actor lacks a role that permits this event
    def fire!(event_name, actor: nil, metadata: {})
      lifecycle = self.class.fosm_lifecycle
      raise Fosm::Error, "No lifecycle defined on #{self.class.name}" unless lifecycle

      event_def = lifecycle.find_event(event_name)
      raise Fosm::UnknownEvent.new(event_name, self.class) unless event_def

      current           = self.state.to_s
      current_state_def = lifecycle.find_state(current)

      # Block terminal states from further transitions
      if current_state_def&.terminal?
        raise Fosm::TerminalState.new(current, self.class)
      end

      # Check the transition is valid from current state
      unless event_def.valid_from?(current)
        raise Fosm::InvalidTransition.new(event_name, current, self.class)
      end

      # Run guards (pure functions — no side effects, evaluated before any writes)
      event_def.guards.each do |guard_def|
        unless guard_def.call(self)
          raise Fosm::GuardFailed.new(guard_def.name, event_name)
        end
      end

      # RBAC check — fail fast before touching the DB
      if lifecycle.access_defined?
        fosm_enforce_event_access!(event_name, actor)
      end

      from_state      = current
      to_state        = event_def.to_state.to_s
      transition_data = { from: from_state, to: to_state, event: event_name.to_s, actor: actor }

      log_data = {
        "record_type" => self.class.name,
        "record_id"   => self.id.to_s,
        "event_name"  => event_name.to_s,
        "from_state"  => from_state,
        "to_state"    => to_state,
        "actor_type"  => actor_type_for(actor),
        "actor_id"    => actor_id_for(actor),
        "actor_label" => actor_label_for(actor),
        "metadata"    => metadata
      }

      ActiveRecord::Base.transaction do
        update!(state: to_state)

        # :sync strategy — INSERT inside transaction for strict consistency
        if Fosm.config.transition_log_strategy == :sync
          Fosm::TransitionLog.create!(log_data)
        end

        # Run side effects inside transaction so they roll back on error
        event_def.side_effects.each do |side_effect_def|
          side_effect_def.call(self, transition_data)
        end
      end

      # :async strategy — enqueue job after transaction commits (non-blocking)
      if Fosm.config.transition_log_strategy == :async
        Fosm::TransitionLogJob.perform_later(log_data)
      end

      # :buffered strategy — push to in-memory buffer (bulk INSERT every ~1s)
      if Fosm.config.transition_log_strategy == :buffered
        Fosm::TransitionBuffer.push(log_data)
      end

      # Deliver webhooks asynchronously (outside transaction, always)
      Fosm::WebhookDeliveryJob.perform_later(
        record_type: self.class.name,
        record_id:   self.id.to_s,
        event_name:  event_name.to_s,
        from_state:  from_state,
        to_state:    to_state,
        metadata:    metadata
      )

      true
    end

    # Returns true if the given event can be fired from the current state.
    # Does NOT check RBAC — use fosm_can_fire_with_actor? for that.
    def can_fire?(event_name)
      lifecycle = self.class.fosm_lifecycle
      return false unless lifecycle

      event_def = lifecycle.find_event(event_name)
      return false unless event_def
      return false if lifecycle.find_state(self.state)&.terminal?
      return false unless event_def.valid_from?(self.state)

      event_def.guards.all? { |guard_def| guard_def.call(self) }
    end

    # Returns true if the actor has a role permitting this event AND the transition is valid.
    def can_fire_with_actor?(event_name, actor:)
      return false unless can_fire?(event_name)
      lifecycle = self.class.fosm_lifecycle
      return true unless lifecycle.access_defined?
      fosm_actor_has_event_permission?(event_name, actor)
    end

    # Returns list of event names that can be fired from the current state
    def available_events
      lifecycle = self.class.fosm_lifecycle
      return [] unless lifecycle

      lifecycle.available_events_from(self.state).select { |event_def|
        event_def.guards.all? { |g| g.call(self) }
      }.map(&:name)
    end

    # Returns the current state as a symbol
    def current_state
      self.state.to_sym
    end

    private

    def fosm_set_initial_state
      return if self.state.present?
      initial = self.class.fosm_lifecycle&.initial_state
      self.state = initial.name.to_s if initial
    end

    # Auto-assign the lifecycle's default role to the record creator.
    # Fires after_create if an access block with default: true role is declared
    # and the record has a created_by association.
    def fosm_auto_assign_default_role
      lifecycle = self.class.fosm_lifecycle
      return unless lifecycle&.access_defined?

      default_role = lifecycle.access_definition.default_role
      return unless default_role

      # Resolve creator — support created_by, user, and owner associations
      creator = nil
      creator ||= created_by  if respond_to?(:created_by)  && try(:created_by).present?
      creator ||= user         if respond_to?(:user)         && try(:user).present?
      creator ||= owner        if respond_to?(:owner)        && try(:owner).present?
      return unless creator

      Fosm::RoleAssignment.find_or_create_by!(
        user_type:     creator.class.name,
        user_id:       creator.id.to_s,
        resource_type: self.class.name,
        resource_id:   self.id.to_s,
        role_name:     default_role.to_s
      ) do |ra|
        ra.granted_by_type = "system"
        ra.granted_by_id   = nil
      end

      # Async audit record
      Fosm::AccessEventJob.perform_later({
        "action"             => "auto_grant",
        "user_type"          => creator.class.name,
        "user_id"            => creator.id.to_s,
        "user_label"         => (creator.respond_to?(:email) ? creator.email : creator.to_s),
        "resource_type"      => self.class.name,
        "resource_id"        => self.id.to_s,
        "role_name"          => default_role.to_s,
        "performed_by_type"  => "system",
        "performed_by_id"    => nil,
        "performed_by_label" => "auto_grant_on_create"
      })
    rescue ActiveRecord::RecordNotUnique
      # Race condition: assignment already exists — safe to ignore
    end

    # ── RBAC enforcement ──────────────────────────────────────────────────────

    def fosm_enforce_event_access!(event_name, actor)
      return if fosm_rbac_bypass?(actor)
      return if fosm_actor_has_event_permission?(event_name, actor)

      raise Fosm::AccessDenied.new(event_name, actor)
    end

    def fosm_actor_has_event_permission?(event_name, actor)
      return true if fosm_rbac_bypass?(actor)

      permitted_roles = self.class.fosm_lifecycle.access_definition.roles_for_event(event_name)
      actor_roles     = fosm_roles_for_actor(actor)
      (actor_roles & permitted_roles).any?
    end

    # Returns the actor's roles for this specific record (type-level + record-level combined)
    def fosm_roles_for_actor(actor)
      return [] unless actor.respond_to?(:id) && actor.respond_to?(:class)
      Fosm::Current.roles_for(actor, self.class, self.id)
    end

    # Bypass RBAC for:
    #   - nil actors (no user context — system/cron/migration)
    #   - Symbol actors (:system, :agent, etc. — programmatic invocations)
    #   - Superadmins (root equivalent)
    def fosm_rbac_bypass?(actor)
      return true if actor.nil?
      return true if actor.is_a?(Symbol)
      return true if actor.respond_to?(:superadmin?) && actor.superadmin?
      false
    end

    def actor_type_for(actor)
      return nil if actor.nil?
      return "symbol" if actor.is_a?(Symbol)
      actor.class.name
    end

    def actor_id_for(actor)
      return nil if actor.nil? || actor.is_a?(Symbol)
      actor.respond_to?(:id) ? actor.id.to_s : nil
    end

    def actor_label_for(actor)
      return actor.to_s if actor.is_a?(Symbol)
      return nil unless actor
      actor.respond_to?(:email) ? actor.email : actor.to_s
    end
  end
end
