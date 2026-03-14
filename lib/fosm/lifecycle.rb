require_relative "lifecycle/definition"

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
    # @param event_name [Symbol, String] the event to fire
    # @param actor [Object] who/what is firing the event (User, or symbol like :system, :agent)
    # @param metadata [Hash] optional metadata stored in the transition log
    # @raise [Fosm::UnknownEvent] if event doesn't exist
    # @raise [Fosm::TerminalState] if current state is terminal
    # @raise [Fosm::InvalidTransition] if current state doesn't allow this event
    # @raise [Fosm::GuardFailed] if a guard blocks the transition
    def fire!(event_name, actor: nil, metadata: {})
      lifecycle = self.class.fosm_lifecycle
      raise Fosm::Error, "No lifecycle defined on #{self.class.name}" unless lifecycle

      event_def = lifecycle.find_event(event_name)
      raise Fosm::UnknownEvent.new(event_name, self.class) unless event_def

      current = self.state.to_s
      current_state_def = lifecycle.find_state(current)

      # Block terminal states from further transitions
      if current_state_def&.terminal?
        raise Fosm::TerminalState.new(current, self.class)
      end

      # Check the transition is valid from current state
      unless event_def.valid_from?(current)
        raise Fosm::InvalidTransition.new(event_name, current, self.class)
      end

      # Run guards
      event_def.guards.each do |guard_def|
        unless guard_def.call(self)
          raise Fosm::GuardFailed.new(guard_def.name, event_name)
        end
      end

      from_state = current
      to_state = event_def.to_state.to_s

      transition_data = { from: from_state, to: to_state, event: event_name.to_s, actor: actor }

      ActiveRecord::Base.transaction do
        update!(state: to_state)

        # Write immutable transition log
        Fosm::TransitionLog.create!(
          record_type: self.class.name,
          record_id: self.id.to_s,
          event_name: event_name.to_s,
          from_state: from_state,
          to_state: to_state,
          actor_type: actor_type_for(actor),
          actor_id: actor_id_for(actor),
          actor_label: actor_label_for(actor),
          metadata: metadata
        )

        # Run side effects inside transaction so they can roll back on error
        event_def.side_effects.each do |side_effect_def|
          side_effect_def.call(self, transition_data)
        end
      end

      # Deliver webhooks asynchronously (outside transaction)
      Fosm::WebhookDeliveryJob.perform_later(
        record_type: self.class.name,
        record_id: self.id.to_s,
        event_name: event_name.to_s,
        from_state: from_state,
        to_state: to_state,
        metadata: metadata
      )

      true
    end

    # Returns true if the given event can be fired from the current state
    def can_fire?(event_name)
      lifecycle = self.class.fosm_lifecycle
      return false unless lifecycle

      event_def = lifecycle.find_event(event_name)
      return false unless event_def
      return false if lifecycle.find_state(self.state)&.terminal?
      return false unless event_def.valid_from?(self.state)

      event_def.guards.all? { |guard_def| guard_def.call(self) }
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
