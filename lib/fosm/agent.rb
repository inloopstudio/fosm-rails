module Fosm
  # Base class for FOSM AI agents powered by Gemlings.
  #
  # Each generated FOSM app gets an agent class that inherits from this.
  # Gemlings::Tool instances are auto-generated from the lifecycle definition,
  # giving the AI agent a bounded, machine-enforced set of actions.
  #
  # The AI agent can ONLY fire lifecycle events. It cannot directly update state.
  # This is the "bounded autonomy" guarantee — the state machine is the guardrail.
  # If a transition isn't valid, the tool returns { success: false } — the agent
  # cannot bypass the machine.
  #
  # Requires: gem "gemlings" in your Gemfile.
  # See: https://github.com/khasinski/gemlings
  #
  # Usage:
  #
  #   class Fosm::InvoiceAgent < Fosm::Agent
  #     model_class Fosm::Invoice
  #     default_model "anthropic/claude-sonnet-4-20250514"
  #
  #     # Optional: add custom tools using Gemlings inline API
  #     # fosm_tool :find_overdue,
  #     #           description: "Find sent invoices past their due date",
  #     #           inputs: {} do
  #     #   Fosm::Invoice.where(state: "sent").where("due_date < ?", Date.today)
  #     #                .map { |inv| { id: inv.id, due_date: inv.due_date } }
  #     # end
  #   end
  #
  #   # Build and run a Gemlings agent
  #   agent = Fosm::InvoiceAgent.build_agent
  #   agent.run("Mark all sent invoices older than 30 days as overdue")
  #
  class Agent
    class << self
      # Declares the model class this agent operates on.
      # Resets the cached tool list so tools are regenerated on next call to .tools
      def model_class(klass = nil)
        if klass
          @model_class = klass
          @tools = nil
        end
        @model_class
      end

      # Sets/gets the default Gemlings model string.
      # Format: "provider/model_name" — see Gemlings docs for supported providers.
      def default_model(model = nil)
        @default_model = model if model
        @default_model || "anthropic/claude-sonnet-4-20250514"
      end

      # Declare a custom Gemlings tool using the inline Gemlings.tool API.
      #
      # @param name [Symbol] snake_case tool name
      # @param description [String] what this tool does (shown to the LLM)
      # @param inputs [Hash] { param_name: "description" } for each parameter
      # @param block [Proc] the tool implementation
      #
      # Example:
      #   fosm_tool :find_overdue_invoices,
      #             description: "Find all invoices that are past their due date",
      #             inputs: {} do
      #     Fosm::Invoice.where(state: "sent")
      #                  .where("due_date < ?", Date.today)
      #                  .map { |inv| { id: inv.id, due_date: inv.due_date.to_s } }
      #   end
      def fosm_tool(name, description:, inputs: {}, &block)
        @custom_tool_definitions ||= []
        @custom_tool_definitions << { name: name, description: description, inputs: inputs, block: block }
        @tools = nil # Reset cached tools
      end

      # Returns all Gemlings tool instances for this agent.
      # Lazily built and cached — standard tools from lifecycle + custom tools.
      def tools
        @tools ||= build_all_tools
      end

      # Builds and returns a configured Gemlings::CodeAgent (default) or
      # Gemlings::ToolCallingAgent ready to run tasks within FOSM constraints.
      #
      # @param model [String] override the default model, e.g. "openai/gpt-4o"
      # @param agent_type [Symbol] :code (default) or :tool_calling
      # @param instructions [String] extra instructions appended to system prompt
      # @param kwargs [Hash] additional Gemlings::CodeAgent options
      #   (max_steps:, planning_interval:, callbacks:, output_type:, etc.)
      def build_agent(model: nil, agent_type: :code, instructions: nil, **kwargs)
        unless defined?(Gemlings)
          raise LoadError, "Gemlings is required for FOSM agents. Add `gem 'gemlings'` to your Gemfile."
        end

        agent_class = agent_type == :tool_calling ? Gemlings::ToolCallingAgent : Gemlings::CodeAgent

        agent_class.new(
          model: model || default_model,
          tools: tools,
          instructions: build_system_instructions(instructions),
          **kwargs
        )
      end

      private

      def build_all_tools
        raise ArgumentError, "#{name}.model_class is not set" unless @model_class

        lifecycle = @model_class.fosm_lifecycle
        raise ArgumentError, "#{@model_class.name} has no lifecycle defined" unless lifecycle

        standard = build_standard_tools(@model_class, lifecycle)
        custom = build_custom_tools

        standard + custom
      end

      # Generates Gemlings tools from the lifecycle definition using Gemlings.tool inline API.
      # Creates: list, get, available_events, transition_history, + one per event.
      def build_standard_tools(klass, lifecycle)
        mn = klass.name.demodulize.underscore # e.g. "invoice"
        tools = []

        # list_invoices — list all records, optionally filtered by state
        tools << Gemlings.tool(
          :"list_#{mn.pluralize}",
          "List #{mn.pluralize} with their current state. Pass state: 'draft' to filter.",
          state: "Optional state filter (e.g. 'draft', 'sent')"
        ) do |state: nil|
          records = state.present? ? klass.where(state: state) : klass.all
          records.map { |r|
            { id: r.id, state: r.state }
              .merge(r.attributes.except("id", "state", "created_by_id", "created_at", "updated_at"))
          }
        end

        # get_invoice — fetch a single record by ID
        tools << Gemlings.tool(
          :"get_#{mn}",
          "Get a #{mn} by ID with its current state and available lifecycle events.",
          id: "The #{mn} ID (integer)"
        ) do |id:|
          record = klass.find_by(id: id)
          next({ error: "#{mn.humanize} ##{id} not found" }) unless record

          { id: record.id, state: record.state, available_events: record.available_events }
            .merge(record.attributes.except("id", "state", "created_by_id", "created_at", "updated_at"))
        end

        # available_events_for_invoice
        tools << Gemlings.tool(
          :"available_events_for_#{mn}",
          "Returns which lifecycle events can fire on a #{mn} from its current state. Always check this before firing.",
          id: "The #{mn} ID (integer)"
        ) do |id:|
          record = klass.find_by(id: id)
          next({ error: "#{mn.humanize} ##{id} not found" }) unless record
          { id: record.id, current_state: record.state, available_events: record.available_events }
        end

        # transition_history_for_invoice
        tools << Gemlings.tool(
          :"transition_history_for_#{mn}",
          "Returns the full audit trail of every state transition for a #{mn}.",
          id: "The #{mn} ID (integer)"
        ) do |id:|
          Fosm::TransitionLog
            .where(record_type: klass.name, record_id: id.to_s)
            .order(created_at: :asc)
            .map { |l|
              { event: l.event_name, from: l.from_state, to: l.to_state,
                actor: l.actor_label || l.actor_type, at: l.created_at.iso8601 }
            }
        end

        # One tool per lifecycle event — the bounded autonomy guarantee.
        # The agent can only fire declared events. Invalid transitions return { success: false }.
        lifecycle.events.each do |event_def|
          from_desc = event_def.from_states.join(" or ")
          guard_note = event_def.guards.any? ? " Requires guards: #{event_def.guards.map(&:name).join(', ')}." : ""

          tools << Gemlings.tool(
            :"#{event_def.name}_#{mn}",
            "Fire the '#{event_def.name}' event on a #{mn}. " \
            "Valid from state [#{from_desc}] → #{event_def.to_state}.#{guard_note} " \
            "Returns { success: false } if the machine rejects the transition.",
            id: "The #{mn} ID (integer)"
          ) do |id:|
            record = klass.find_by(id: id)
            next({ success: false, error: "#{mn.humanize} ##{id} not found" }) unless record

            record.fire!(event_def.name, actor: :agent)
            { success: true, id: record.id, previous_state: event_def.from_states.first,
              new_state: record.reload.state }
          rescue Fosm::Error => e
            { success: false, error: e.message, current_state: record&.state }
          end
        end

        tools
      end

      def build_custom_tools
        (@custom_tool_definitions || []).map do |defn|
          Gemlings.tool(defn[:name], defn[:description], **defn[:inputs], &defn[:block])
        end
      end

      # Builds a system prompt that communicates FOSM constraints to the LLM.
      def build_system_instructions(extra = nil)
        klass = @model_class
        lifecycle = klass.fosm_lifecycle
        state_names = lifecycle.state_names.join(", ")
        terminal_states = lifecycle.states.select(&:terminal?).map(&:name).join(", ")
        event_names = lifecycle.event_names.join(", ")
        mn = klass.name.demodulize.underscore

        base = <<~INSTRUCTIONS
          You are a FOSM AI agent managing #{klass.name.demodulize.pluralize.humanize}.

          ARCHITECTURE CONSTRAINTS — you MUST follow these at all times:
          1. State changes happen ONLY via lifecycle event tools. Never use direct updates.
          2. Valid states: #{state_names}
          3. Terminal states (no further transitions allowed): #{terminal_states.presence || "none"}
          4. Available lifecycle events: #{event_names}
          5. ALWAYS call available_events_for_#{mn}(id:) before firing any event.
          6. If an event tool returns { success: false }, DO NOT retry — report the error.
          7. Records in a terminal state cannot transition further — accept this.
          8. Think step by step. State your reasoning before any action that changes state.
        INSTRUCTIONS

        extra.present? ? "#{base.strip}\n\n#{extra}" : base.strip
      end
    end
  end
end
