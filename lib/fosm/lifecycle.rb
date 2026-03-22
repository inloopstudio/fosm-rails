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
          define_method(:"#{event_def.name}!") do |actor: nil, metadata: {}, snapshot_data: nil|
            fire!(event_def.name, actor: actor, metadata: metadata, snapshot_data: snapshot_data)
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
    #   6. Acquire row lock (SELECT FOR UPDATE) and re-validate
    #   7. BEGIN TRANSACTION: UPDATE state, run side effects
    #                         [optionally INSERT log if strategy == :sync]
    #      COMMIT
    #   8. Emit transition log (:async or :buffered, non-blocking)
    #   9. Enqueue webhook delivery (always async)
    #
    # RACE CONDITION PROTECTION:
    #   - Uses SELECT FOR UPDATE to lock the row, preventing concurrent transitions
    #   - Re-validates state, guards, and RBAC after acquiring lock
    #   - Guarantees only one transition succeeds when concurrent requests fire
    #     the same event on the same record
    #
    # @param event_name [Symbol, String] the event to fire
    # @param actor [Object] who/what is firing the event (User, or :system/:agent symbol)
    # @param metadata [Hash] optional metadata stored in the transition log
    # @param snapshot_data [Hash] arbitrary observations/data to include in state snapshot
    #   This allows capturing adhoc observations alongside schema attributes.
    #   Merged with schema data under the `_observations` key in the snapshot.
    # @raise [Fosm::UnknownEvent]    if event doesn't exist
    # @raise [Fosm::TerminalState]   if current state is terminal
    # @raise [Fosm::InvalidTransition] if current state doesn't allow this event
    # @raise [Fosm::GuardFailed]     if a guard blocks the transition
    # @raise [Fosm::AccessDenied]    if actor lacks a role that permits this event
    def fire!(event_name, actor: nil, metadata: {}, snapshot_data: nil)
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
      # 🆕 Use evaluate for rich error messages
      event_def.guards.each do |guard_def|
        allowed, reason = guard_def.evaluate(self)
        unless allowed
          raise Fosm::GuardFailed.new(guard_def.name, event_name, reason)
        end
      end

      # RBAC check — fail fast before touching the DB
      if lifecycle.access_defined?
        fosm_enforce_event_access!(event_name, actor)
      end

      from_state      = current
      to_state        = event_def.to_state.to_s
      transition_data = { from: from_state, to: to_state, event: event_name.to_s, actor: actor }

      # Auto-capture triggered_by when called from within a side effect
      triggered_by = Thread.current[:fosm_trigger_context]

      log_data = {
        "record_type" => self.class.name,
        "record_id"   => self.id.to_s,
        "event_name"  => event_name.to_s,
        "from_state"  => from_state,
        "to_state"    => to_state,
        "actor_type"  => actor_type_for(actor),
        "actor_id"    => actor_id_for(actor),
        "actor_label" => actor_label_for(actor),
        "metadata"    => metadata.merge(
          triggered_by ? { triggered_by: triggered_by } : {}
        ).compact
      }

      # ==========================================================================
      # SNAPSHOT CONFIGURATION
      # ==========================================================================
      # If snapshots are configured, determine if we should capture one for this
      # transition based on the strategy (every, count, time, terminal, manual).
      # ==========================================================================
      snapshot_config = lifecycle.snapshot_configuration
      if snapshot_config && metadata[:snapshot] != false  # allow manual opt-out
        # Calculate metrics for snapshot decision
        last_snapshot = Fosm::TransitionLog
          .where(record_type: self.class.name, record_id: self.id.to_s)
          .where.not(state_snapshot: nil)
          .order(created_at: :desc)
          .first

        transitions_since = last_snapshot ?
          Fosm::TransitionLog.where(record_type: self.class.name, record_id: self.id.to_s)
            .where("created_at > ?", last_snapshot.created_at).count :
          Fosm::TransitionLog.where(record_type: self.class.name, record_id: self.id.to_s).count

        seconds_since = last_snapshot ?
          (Time.current - last_snapshot.created_at).to_f :
          Float::INFINITY

        to_state_def = lifecycle.find_state(to_state)

        # Check if we should snapshot (respecting manual: false unless forced)
        force_snapshot = metadata[:snapshot] == true
        should_snapshot = snapshot_config.should_snapshot?(
          transition_count: transitions_since,
          seconds_since_last: seconds_since,
          to_state: to_state,
          to_state_terminal: to_state_def&.terminal? || false,
          force: force_snapshot
        )

        if should_snapshot
          # Build snapshot: schema attributes + arbitrary observations
          schema_snapshot = snapshot_config.build_snapshot(self)

          # Merge arbitrary observations if provided (stored under _observations key)
          if snapshot_data.present?
            schema_snapshot["_observations"] = snapshot_data.as_json
          end

          log_data["state_snapshot"] = schema_snapshot
          log_data["snapshot_reason"] = determine_snapshot_reason(
            snapshot_config.strategy, force_snapshot, to_state_def
          )
        end
      end

      # ==========================================================================
      # RACE CONDITION FIX: SELECT FOR UPDATE
      # ==========================================================================
      # Acquire a row-level lock before proceeding. This prevents concurrent
      # transactions from reading stale state and attempting concurrent transitions.
      #
      # Behavior:
      # - PostgreSQL/MySQL: SELECT ... FOR UPDATE blocks until lock acquired
      # - SQLite: No-op (database-level locking makes it already serializable)
      #
      # We re-read state after locking to ensure we have the latest value.
      # If another transaction committed while we waited for the lock, we get
      # the fresh state and must re-validate our checks.
      # ==========================================================================

      # Acquire lock - this blocks if another transaction holds the lock
      locked_record = self.class.lock.find(self.id)

      # Re-validate with locked state - the world may have changed while waiting
      locked_current = locked_record.state.to_s
      locked_current_state_def = lifecycle.find_state(locked_current)

      # If state changed while waiting for lock, transition may no longer be valid
      if locked_current_state_def&.terminal?
        raise Fosm::TerminalState.new(locked_current, self.class)
      end

      unless event_def.valid_from?(locked_current)
        raise Fosm::InvalidTransition.new(event_name, locked_current, self.class)
      end

      # Re-check guards with locked record (guards may depend on fresh state)
      event_def.guards.each do |guard_def|
        allowed, reason = guard_def.evaluate(locked_record)
        unless allowed
          raise Fosm::GuardFailed.new(guard_def.name, event_name, reason)
        end
      end

      # Re-check RBAC with locked record (for consistency, though RBAC uses cache)
      if lifecycle.access_defined?
        unless fosm_rbac_bypass?(actor)
          unless fosm_actor_has_event_permission_for_record?(event_name, actor, locked_record)
            raise Fosm::AccessDenied.new(event_name, actor)
          end
        end
      end

      # Update from_state to reflect the locked state's current value
      from_state = locked_current
      log_data["from_state"] = from_state

      ActiveRecord::Base.transaction do
        # Use the locked record for the update to ensure we hold the lock
        locked_record.update!(state: to_state)

        # Sync our instance state with what was written
        self.state = to_state

        # :sync strategy — INSERT inside transaction for strict consistency
        if Fosm.config.transition_log_strategy == :sync
          Fosm::TransitionLog.create!(log_data)
        end

        # Run immediate side effects inside transaction so they roll back on error
        # Set context for auto-capturing triggered_by in nested transitions
        begin
          Thread.current[:fosm_trigger_context] = {
            record_type: self.class.name,
            record_id: self.id.to_s,
            event_name: event_name.to_s
          }
          # Call side effects on self (not locked_record) so instance state is preserved
          event_def.side_effects.reject(&:deferred?).each do |side_effect_def|
            side_effect_def.call(self, transition_data)
          end
        ensure
          Thread.current[:fosm_trigger_context] = nil
        end

        # 🆕 Queue deferred side effects to run after commit
        deferred_effects = event_def.side_effects.select(&:deferred?)
        if deferred_effects.any?
          # Set instance variables on locked_record (the instance that gets saved)
          # so after_commit callback can access them
          locked_record.instance_variable_set(:@_fosm_deferred_side_effects, deferred_effects)
          locked_record.instance_variable_set(:@_fosm_transition_data, transition_data)
          # Use after_commit to run after transaction completes
          locked_record.class.after_commit :_fosm_run_deferred_side_effects, on: :update
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
      # Terminal states block transitions
      return false if lifecycle.find_state(self.state)&.terminal?
      return false unless event_def.valid_from?(self.state)

      # Use evaluate to properly check guards (handles rich return values)
      event_def.guards.all? { |guard_def| guard_def.evaluate(self).first }
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
        # 🆕 Use evaluate to properly check guards
        event_def.guards.all? { |g| g.evaluate(self).first }
      }.map(&:name)
    end

    # 🆕 Detailed introspection: why can this event (not) be fired?
    # Returns a hash with diagnostic information for debugging and UI messages.
    def why_cannot_fire?(event_name)
      lifecycle = self.class.fosm_lifecycle
      return { can_fire: false, reason: "No lifecycle defined" } unless lifecycle

      event_def = lifecycle.find_event(event_name)
      return { can_fire: false, reason: "Unknown event '#{event_name}'" } unless event_def

      current = self.state.to_s
      current_state_def = lifecycle.find_state(current)
      result = {
        can_fire: true,
        event: event_name.to_s,
        current_state: current
      }

      # Check terminal state
      if current_state_def&.terminal?
        result[:can_fire] = false
        result[:reason] = "State '#{current}' is terminal and cannot transition further"
        result[:is_terminal] = true
        return result
      end

      # Check valid from state
      unless event_def.valid_from?(current)
        result[:can_fire] = false
        result[:reason] = "Cannot fire '#{event_name}' from '#{current}' (valid from: #{event_def.from_states.join(', ')})"
        result[:valid_from_states] = event_def.from_states
        return result
      end

      # Evaluate guards
      failed_guards = []
      passed_guards = []

      event_def.guards.each do |guard_def|
        allowed, reason = guard_def.evaluate(self)
        if allowed
          passed_guards << guard_def.name
        else
          failed_guards << { name: guard_def.name, reason: reason }
        end
      end

      if failed_guards.any?
        result[:can_fire] = false
        result[:failed_guards] = failed_guards
        result[:passed_guards] = passed_guards
        first_failure = failed_guards.first
        result[:reason] = "Guard '#{first_failure[:name]}' failed"
        result[:reason] += ": #{first_failure[:reason]}" if first_failure[:reason]
      end

      result
    end

    # Returns the current state as a symbol
    def current_state
      self.state.to_sym
    end

    # ==========================================================================
    # SNAPSHOT REPLAY AND TIME-TRAVEL METHODS
    # ==========================================================================

    # Returns the most recent snapshot for this record, or nil if none exists.
    # @return [Fosm::TransitionLog, nil] the transition log entry with snapshot
    def last_snapshot
      Fosm::TransitionLog
        .where(record_type: self.class.name, record_id: self.id.to_s)
        .where.not(state_snapshot: nil)
        .order(created_at: :desc)
        .first
    end

    # Returns the snapshot data from the most recent snapshot, or nil.
    # @return [Hash, nil] the snapshot data
    def last_snapshot_data
      last_snapshot&.state_snapshot
    end

    # Returns the state of the record at a specific transition log ID.
    # This is a "time-travel" query that reconstructs state from snapshot + replay.
    #
    # @param transition_log_id [Integer] the ID of the transition log entry
    # @return [Hash] the reconstructed state at that point in time
    def state_at_transition(transition_log_id)
      log = Fosm::TransitionLog.find_by(id: transition_log_id)
      return nil unless log
      return nil unless log.record_type == self.class.name && log.record_id == self.id.to_s

      # If this log entry has a snapshot, use it directly
      return log.state_snapshot if log.state_snapshot.present?

      # Otherwise, find the most recent snapshot before this log entry
      prior_snapshot = Fosm::TransitionLog
        .where(record_type: self.class.name, record_id: self.id.to_s)
        .where.not(state_snapshot: nil)
        .where("created_at <= ?", log.created_at)
        .order(created_at: :desc)
        .first

      # Return the prior snapshot data, or nil if no snapshot exists
      prior_snapshot&.state_snapshot
    end

    # Replays events from a specific snapshot forward to the current state.
    # Yields each transition to a block for custom processing.
    #
    # @param from_snapshot [Fosm::TransitionLog, Integer] snapshot log entry or ID
    # @yield [transition_log] optional block to process each transition
    # @return [Array<Fosm::TransitionLog>] the transitions replayed
    def replay_from(from_snapshot)
      snapshot_id = from_snapshot.is_a?(Fosm::TransitionLog) ? from_snapshot.id : from_snapshot

      transitions = Fosm::TransitionLog
        .where(record_type: self.class.name, record_id: self.id.to_s)
        .where("id > ?", snapshot_id)
        .order(:created_at)

      if block_given?
        transitions.each { |log| yield log }
      end

      transitions.to_a
    end

    # Returns all snapshots for this record in chronological order.
    # Useful for audit trails and debugging.
    # @return [ActiveRecord::Relation] snapshot transition logs
    def snapshots
      Fosm::TransitionLog
        .where(record_type: self.class.name, record_id: self.id.to_s)
        .where.not(state_snapshot: nil)
        .order(:created_at)
    end

    # Returns the number of transitions since the last snapshot.
    # Useful for monitoring snapshot coverage.
    # @return [Integer] transitions since last snapshot
    def transitions_since_snapshot
      last_snap = last_snapshot
      return Fosm::TransitionLog.where(record_type: self.class.name, record_id: self.id.to_s).count unless last_snap

      Fosm::TransitionLog
        .where(record_type: self.class.name, record_id: self.id.to_s)
        .where("created_at > ?", last_snap.created_at)
        .count
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

    # Variant for checking permissions with a locked record (after SELECT FOR UPDATE)
    def fosm_actor_has_event_permission_for_record?(event_name, actor, record)
      return true if fosm_rbac_bypass?(actor)

      permitted_roles = record.class.fosm_lifecycle.access_definition.roles_for_event(event_name)
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

    # Run deferred side effects after transaction commits
    # This prevents SQLite locking when cross-machine triggers occur
    def _fosm_run_deferred_side_effects
      return unless defined?(@_fosm_deferred_side_effects) && @_fosm_deferred_side_effects

      transition_data = @_fosm_transition_data

      begin
        # Set context for auto-capturing triggered_by in nested transitions
        Thread.current[:fosm_trigger_context] = {
          record_type: self.class.name,
          record_id: self.id.to_s,
          event_name: transition_data[:event]
        }

        @_fosm_deferred_side_effects.each do |side_effect_def|
          side_effect_def.call(self, transition_data)
        end
      rescue => e
        # Log error but don't fail - transaction is already committed
        logger = defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
        logger ||= Logger.new(STDOUT)
        logger.error("[Fosm] Deferred side effect failed: #{e.message}")
      ensure
        Thread.current[:fosm_trigger_context] = nil
        # Clean up instance variables
        @_fosm_deferred_side_effects = nil
        @_fosm_transition_data = nil
      end

      # Remove the after_commit callback to avoid running on subsequent updates
      self.class.skip_callback(:commit, :after, :_fosm_run_deferred_side_effects, on: :update, raise: false)
    end

    # Determine the reason string for a snapshot based on strategy and context
    def determine_snapshot_reason(strategy, forced, to_state_def)
      return "manual" if forced
      return "every" if strategy == :every
      return "terminal" if strategy == :terminal && to_state_def&.terminal?
      return "count_interval" if strategy == :count
      return "time_interval" if strategy == :time
      "auto"
    end
  end
end
