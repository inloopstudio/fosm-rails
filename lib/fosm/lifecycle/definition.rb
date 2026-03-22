require_relative "state_definition"
require_relative "event_definition"
require_relative "guard_definition"
require_relative "side_effect_definition"
require_relative "access_definition"
require_relative "snapshot_configuration"

module Fosm
  module Lifecycle
    # Holds the entire lifecycle definition for a FOSM model.
    # Instantiated once per model class at class load time.
    class Definition
      attr_reader :states, :events, :access_definition

      def initialize
        @states            = []
        @events            = []
        @pending_guards    = {}   # event_name => [GuardDefinition, ...]
        @pending_side_effects = {} # event_name => [SideEffectDefinition, ...]
        @access_definition = nil  # nil = open-by-default; set when access{} is declared
      end

      # DSL: declare a state
      def state(name, initial: false, terminal: false)
        if initial && @states.any?(&:initial?)
          raise ArgumentError, "Only one initial state is allowed"
        end
        @states << StateDefinition.new(name: name, initial: initial, terminal: terminal)
      end

      # DSL: declare an event
      def event(name, from:, to:)
        event_def = EventDefinition.new(name: name, from: from, to: to)

        # Apply any guards/side_effects declared before this event (unusual but handle it)
        (@pending_guards[name.to_sym] || []).each { |g| event_def.add_guard(g) }
        (@pending_side_effects[name.to_sym] || []).each { |se| event_def.add_side_effect(se) }

        @events << event_def
        event_def
      end

      # DSL: declare a guard on an event
      def guard(name, on:, &block)
        guard_def = GuardDefinition.new(name: name, &block)
        event_def = find_event(on)
        if event_def
          event_def.add_guard(guard_def)
        else
          # Event may be declared after guard — store for later
          @pending_guards[on.to_sym] ||= []
          @pending_guards[on.to_sym] << guard_def
        end
      end

      # DSL: declare the access control block for this lifecycle.
      #
      # Activates RBAC for this object. Without this block, all authenticated
      # actors have full access (open-by-default — backwards-compatible).
      #
      # Once declared, deny-by-default: only granted capabilities work.
      # Superadmin and :system/:agent symbol actors always bypass checks.
      #
      # Example:
      #
      #   access do
      #     role :owner, default: true do
      #       can :crud
      #       can :send_invoice, :cancel
      #     end
      #
      #     role :approver do
      #       can :read
      #       can :pay
      #     end
      #
      #     role :viewer do
      #       can :read
      #     end
      #   end
      def access(&block)
        @access_definition = AccessDefinition.new
        @access_definition.instance_eval(&block)
        @access_definition
      end

      # Returns true if an access block was declared (RBAC is active)
      def access_defined?
        @access_definition.present?
      end

      # DSL: declare a side effect on an event
      # Options:
      #   defer: false (default), true — run after transaction commits
      def side_effect(name, on:, defer: false, &block)
        side_effect_def = SideEffectDefinition.new(
          name: name,
          defer: defer,
          &block
        )
        event_def = find_event(on)
        if event_def
          event_def.add_side_effect(side_effect_def)
        else
          @pending_side_effects[on.to_sym] ||= []
          @pending_side_effects[on.to_sym] << side_effect_def
        end
      end

      def initial_state
        @states.find(&:initial?)
      end

      def find_event(name)
        @events.find { |e| e.name == name.to_sym }
      end

      def find_state(name)
        @states.find { |s| s.name == name.to_sym }
      end

      def state_names
        @states.map(&:name).map(&:to_s)
      end

      def event_names
        @events.map(&:name)
      end

      # Returns events valid from the given state
      def available_events_from(state)
        @events.select { |e| e.valid_from?(state) }
      end

      # DSL: configure automatic state snapshots on transitions
      # Supports multiple strategies for how often to snapshot:
      #
      #   snapshot :every        # snapshot on every transition
      #   snapshot every: 10      # snapshot every 10 transitions
      #   snapshot time: 300      # snapshot if >5 min since last snapshot
      #   snapshot :terminal      # snapshot only when reaching terminal states
      #   snapshot :manual        # only snapshot when explicitly requested (default)
      #
      #   snapshot_attributes :amount, :due_date, :line_items_count
      #
      def snapshot(strategy = nil, **options)
        @snapshot_configuration ||= SnapshotConfiguration.new

        if strategy.is_a?(Symbol) || strategy.is_a?(String)
          @snapshot_configuration.send(strategy)
        elsif options[:every]
          @snapshot_configuration.count(options[:every])
        elsif options[:time]
          @snapshot_configuration.time(options[:time])
        end

        @snapshot_configuration
      end

      # DSL: specify which attributes to include in snapshots
      # Usage: snapshot_attributes :amount, :status, :line_items_count
      def snapshot_attributes(*attrs)
        @snapshot_configuration ||= SnapshotConfiguration.new
        @snapshot_configuration.set_attributes(*attrs)
      end

      # Returns true if snapshot configuration has been set
      def snapshot_configured?
        @snapshot_configuration.present?
      end

      # Returns the snapshot configuration (nil if not configured)
      def snapshot_configuration
        @snapshot_configuration
      end

      # Returns a hash suitable for rendering a state diagram
      def to_diagram_data
        {
          states: @states.map { |s| { name: s.name, initial: s.initial?, terminal: s.terminal? } },
          transitions: @events.map { |e|
            e.from_states.map { |from|
              { event: e.name, from: from, to: e.to_state, guards: e.guards.map(&:name) }
            }
          }.flatten
        }
      end
    end
  end
end
