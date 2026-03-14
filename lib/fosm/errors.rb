module Fosm
  class Error < StandardError; end

  # Raised when fire! is called with an unknown event name
  class UnknownEvent < Error
    def initialize(event_name, model_class)
      super("Unknown event '#{event_name}' on #{model_class.name}. Available events: #{model_class.fosm_lifecycle.events.map(&:name).join(', ')}")
    end
  end

  # Raised when fire! is called but current state doesn't allow the event
  class InvalidTransition < Error
    def initialize(event_name, current_state, record_class)
      super("Cannot fire '#{event_name}' from state '#{current_state}' on #{record_class.name}")
    end
  end

  # Raised when a guard blocks a transition
  class GuardFailed < Error
    def initialize(guard_name, event_name)
      super("Guard '#{guard_name}' prevented transition for event '#{event_name}'")
    end
  end

  # Raised when trying to transition a record in a terminal state
  class TerminalState < Error
    def initialize(state_name, record_class)
      super("#{record_class.name} is in terminal state '#{state_name}' and cannot transition further")
    end
  end
end
