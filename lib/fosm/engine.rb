require "rails/engine"

module Fosm
  class Engine < ::Rails::Engine
    isolate_namespace Fosm

    config.generators do |g|
      g.test_framework :minitest
    end

    # Expose configuration
    initializer "fosm.configuration" do
      # Host app can configure via config/initializers/fosm.rb
      # Run: rails fosm:install:migrations && rails db:migrate

      # Patch Gemlings::Memory#to_messages to fix two Anthropic API incompatibilities
      # in the ToolCallingAgent:
      #
      # 1. Trailing whitespace: Anthropic rejects assistant content ending with whitespace.
      # 2. Tool result format: After a tool_use assistant message, Anthropic requires a
      #    structured tool_result block (not a plain "Observation: ..." user message).
      #    Gemlings generates the wrong format; we rewrite it here.
      # Patch Gemlings::Models::RubyLLMAdapter#load_messages to properly add tool
      # results using RubyLLM's `role: :tool` message type.
      # Without this, Gemlings passes tool results as plain user messages, causing
      # Anthropic to reject them with "tool_use without tool_result" errors.
      ::Gemlings::Models::RubyLLMAdapter.prepend(Module.new do
        private

        def load_messages(chat, messages)
          messages.each do |msg|
            role    = msg[:role]
            content = msg[:content]

            case role
            when "system"
              chat.with_instructions(content)
            when "assistant"
              attrs = { role: :assistant, content: content }
              if msg[:tool_calls]
                attrs[:tool_calls] = send(:convert_tool_calls_to_ruby_llm, msg[:tool_calls])
              end
              chat.add_message(attrs)
            else
              if content.is_a?(Array) && content.all? { |c| c.is_a?(Hash) && (c[:type] == "tool_result" || c["type"] == "tool_result") }
                content.each do |tr|
                  chat.add_message(
                    role: :tool,
                    content: (tr[:content] || tr["content"]).to_s,
                    tool_call_id: tr[:tool_use_id] || tr["tool_use_id"]
                  )
                end
              else
                chat.add_message(role: role.to_sym, content: content || "")
              end
            end
          end
        end
      end)

      ::Gemlings::Memory.prepend(Module.new do
        def to_messages
          messages = super

          # First pass: strip trailing whitespace from string content
          messages = messages.map do |msg|
            msg[:content].is_a?(String) ? msg.merge(content: msg[:content].rstrip) : msg
          end

          # Second pass: rewrite tool observation messages into proper tool_result blocks.
          # Anthropic requires that every tool_use in an assistant message is immediately
          # followed by a user message containing tool_result blocks (not plain text).
          result = []
          messages.each_with_index do |msg, i|
            prev = result.last
            # If previous assistant message had tool_calls and this is an "Observation:" message,
            # rewrite as structured tool_result blocks
            if prev && prev[:role] == "assistant" && prev[:tool_calls].present? &&
               msg[:role] == "user" && msg[:content].is_a?(String) && msg[:content].start_with?("Observation:")
              tool_calls = prev[:tool_calls]
              observation = msg[:content].sub(/\AObservation:\s*/, "").strip
              # Build one tool_result per tool_call, using the full observation for each
              # (for single-tool steps this is exact; for multi-tool it's a shared approximation)
              tool_results = tool_calls.map do |tc|
                { type: "tool_result", tool_use_id: tc.id, content: observation }
              end
              result << msg.merge(content: tool_results)
            else
              result << msg
            end
          end

          result
        end
      end)
    end

    # Auto-register all Fosm models with the registry after app loads.
    # Use ::Rails to avoid ambiguity with Fosm::Rails module.
    config.after_initialize do
      ::Rails.application.eager_load! if ::Rails.env.development? && !::Rails.application.config.eager_load

      ObjectSpace.each_object(Class).select { |klass|
        klass < ActiveRecord::Base &&
          klass.name&.start_with?("Fosm::") &&
          klass.respond_to?(:fosm_lifecycle) &&
          klass.fosm_lifecycle.present?
      }.each do |klass|
        slug = klass.name.demodulize.underscore.dasherize
        Fosm::Registry.register(klass, slug: slug)
      end
    end
  end
end
