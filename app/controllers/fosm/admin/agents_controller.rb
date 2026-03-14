module Fosm
  module Admin
    class AgentsController < BaseController
      before_action :load_app

      def show
        @tools = derive_tool_definitions
        @system_prompt = derive_system_prompt
        @agent_class = begin
          "Fosm::#{@model_class.name.demodulize}Agent".constantize
        rescue NameError
          nil
        end
      end

      # ── Chat ──────────────────────────────────────────────────────────────────

      def chat
        @history = chat_history
      end

      def chat_send
        message = params[:message].to_s.strip
        return render json: { error: "Message cannot be blank" }, status: :bad_request if message.blank?

        agent = fetch_or_build_agent

        # reset: true starts fresh each turn (avoids trailing-whitespace issues with
        # multi-turn context). Visual history is maintained in the session.
        result = agent.run(message, reset: true, return_full_result: true)

        # Persist agent instance so next message continues the same conversation
        store_agent(agent)

        steps = Array(result.steps).map { |s|
          h = s.to_h
          # Ensure tool_calls are plain hashes for JSON serialization
          if h[:tool_calls]
            h[:tool_calls] = h[:tool_calls].map { |tc|
              { name: tc.function.name, args: tc.function.arguments }
            } rescue h[:tool_calls].map(&:to_s)
          end
          h
        }

        output = result.output.to_s

        # Store chat history in Rails.cache (not session cookie) to avoid
        # ActionDispatch::Cookies::CookieOverflow — agent responses can be large.
        history = chat_history
        history << { role: "user",  content: message }
        history << { role: "agent", content: output, timing: result.timing.round(2) }
        save_chat_history(history.last(10))

        render json: { output: output, steps: steps,
                       token_usage: result.token_usage.to_h,
                       timing: result.timing.round(2) }
      rescue => e
        render json: { error: "#{e.class}: #{e.message}" }, status: :unprocessable_entity
      end

      def chat_reset
        ::Rails.cache.delete(chat_history_key)
        ::Rails.cache.delete(agent_cache_key)
        render json: { ok: true }
      end

      def agent_invoke
        tool   = params[:tool].to_s
        id     = params[:record_id].presence
        filter = params[:filter].presence

        result = invoke_tool(tool, id, filter)
        render json: result
      rescue => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def load_app
        @slug = params[:slug]
        @model_class = Fosm::Registry.find(@slug)
        render plain: "FOSM app '#{@slug}' not found", status: :not_found unless @model_class
        @lifecycle = @model_class.fosm_lifecycle
        @mn = @model_class.name.demodulize.underscore
      end

      # Derives tool metadata from the lifecycle — no Gemlings required.
      def derive_tool_definitions
        plural = @mn.pluralize
        tools = [
          {
            name: "list_#{plural}",
            description: "List #{plural} with their current state. Pass state= to filter.",
            params: { state: "Optional: filter by state name (e.g. 'draft')" },
            requires_id: false,
            category: :read
          },
          {
            name: "get_#{@mn}",
            description: "Get a #{@mn} by ID with current state and available events.",
            params: { id: "Record ID" },
            requires_id: true,
            category: :read
          },
          {
            name: "available_events_for_#{@mn}",
            description: "Check which lifecycle events can fire from the current state. Always call before firing.",
            params: { id: "Record ID" },
            requires_id: true,
            category: :read
          },
          {
            name: "transition_history_for_#{@mn}",
            description: "Full immutable audit trail of every state transition for this record.",
            params: { id: "Record ID" },
            requires_id: true,
            category: :read
          }
        ]

        @lifecycle.events.each do |event|
          guard_note = event.guards.any? ? " Guards: #{event.guards.map(&:name).join(', ')}." : ""
          side_note  = event.side_effects.any? ? " Side-effects: #{event.side_effects.map(&:name).join(', ')}." : ""
          tools << {
            name: "#{event.name}_#{@mn}",
            description: "Fire '#{event.name}'. Valid from [#{event.from_states.join(' | ')}] → #{event.to_state}.#{guard_note}#{side_note}",
            params: { id: "Record ID" },
            requires_id: true,
            event: event.name,
            category: :mutate
          }
        end

        tools
      end

      def derive_system_prompt
        state_names    = @lifecycle.state_names.join(", ")
        terminal       = @lifecycle.states.select(&:terminal?).map(&:name).join(", ")
        event_names    = @lifecycle.event_names.join(", ")

        <<~PROMPT.strip
          You are a FOSM AI agent managing #{@model_class.name.demodulize.pluralize.humanize}.

          ARCHITECTURE CONSTRAINTS:
          1. State changes happen ONLY via lifecycle event tools. Never use direct updates.
          2. Valid states: #{state_names}
          3. Terminal states (irreversible): #{terminal.presence || "none"}
          4. Available lifecycle events: #{event_names}
          5. ALWAYS call available_events_for_#{@mn}(id:) before firing any event.
          6. If a tool returns { success: false }, DO NOT retry — report the error.
          7. Records in a terminal state cannot transition further — accept this.
        PROMPT
      end

      def invoke_tool(tool, id, filter)
        plural = @mn.pluralize
        klass  = @model_class

        case tool
        when "list_#{plural}"
          records = filter.present? ? klass.where(state: filter) : klass.order(created_at: :desc).limit(20)
          { result: records.map { |r| safe_attrs(r) } }

        when "get_#{@mn}"
          record = klass.find(id)
          { result: safe_attrs(record).merge(available_events: record.available_events) }

        when "available_events_for_#{@mn}"
          record = klass.find(id)
          { result: { id: record.id, current_state: record.state, available_events: record.available_events } }

        when "transition_history_for_#{@mn}"
          logs = Fosm::TransitionLog.for_record(klass.name, id).recent
          { result: logs.map { |t|
            { event: t.event_name, from: t.from_state, to: t.to_state,
              actor: t.actor_label || t.actor_type, at: t.created_at.iso8601 }
          } }

        else
          # fire event: tool name pattern is "event_name_#{mn}"
          event_name = tool.delete_suffix("_#{@mn}").to_sym
          record = klass.find(id)
          record.fire!(event_name, actor: :agent)
          { result: { success: true, id: record.id, new_state: record.reload.state } }
        end
      rescue ActiveRecord::RecordNotFound
        { error: "Record ##{id} not found" }
      rescue Fosm::Error => e
        { error: e.message, success: false }
      end

      def agent_cache_key
        "fosm_agent_#{session.id}_#{@slug}"
      end

      def chat_history_key
        "fosm_chat_#{session.id}_#{@slug}"
      end

      def chat_history
        ::Rails.cache.read(chat_history_key) || []
      end

      def save_chat_history(history)
        ::Rails.cache.write(chat_history_key, history, expires_in: 4.hours)
      end

      def fetch_or_build_agent
        ::Rails.cache.read(agent_cache_key) || build_fosm_agent
      end

      def store_agent(agent)
        ::Rails.cache.write(agent_cache_key, agent, expires_in: 2.hours)
      rescue
        # Marshal serialization may fail for complex objects — that's OK,
        # next message will start a fresh agent with no prior memory
      end

      def build_fosm_agent
        klass = begin
          "Fosm::#{@model_class.name.demodulize}Agent".constantize
        rescue NameError
          # Build an ad-hoc anonymous agent class for this model
          anon = Class.new(Fosm::Agent)
          anon.model_class(@model_class)
          anon
        end
        klass.build_agent
      end

      def safe_attrs(record)
        record.attributes.except("created_by_id").tap do |h|
          h["created_at"] = h["created_at"]&.iso8601
          h["updated_at"] = h["updated_at"]&.iso8601
        end
      end
    end
  end
end
