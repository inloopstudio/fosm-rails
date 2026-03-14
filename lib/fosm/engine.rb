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

      # ── Gemlings compatibility patches ────────────────────────────────────────
      # These patches fix Anthropic API incompatibilities in Gemlings' ToolCallingAgent.
      # Each patch is guarded: it reads the upstream source file and checks whether the
      # fix is already present. If Gemlings merges the fix, the patch becomes a no-op.
      #
      # Upstream PR: https://github.com/khasinski/gemlings (submitted from fork)
      #
      # TODO: remove these patches once the upstream PR is merged and a fixed version
      # of gemlings is released. Steps to clean up:
      #   1. Check if gemlings >= X.Y (the version that includes the fix) is the minimum
      #      required version in fosm-rails.gemspec.
      #   2. Delete the two `unless` blocks below (lines ~37-104).
      #   3. Remove the `_gemlings_dir`, `_memory_text`, `_adapter_text` variables.
      #   4. Update AGENTS.md "Compatibility note" section to remove the patch description.
      #   5. Bump fosm-rails version with a note in CHANGELOG.
      # Track: https://github.com/khasinski/gemlings/pull/[PR_NUMBER]

      # Read upstream source files directly from the gem installation path.
      # We avoid using source_location on the methods themselves because prepend
      # would redirect source_location to this engine file after patching.
      _gemlings_dir = Gem.loaded_specs["gemlings"]&.gem_dir || ""
      _memory_text  = File.read(File.join(_gemlings_dir, "lib/gemlings/memory.rb"))              rescue ""
      _adapter_text = File.read(File.join(_gemlings_dir, "lib/gemlings/models/ruby_llm_adapter.rb")) rescue ""

      # Patch 1 — Memory#to_messages (needed if upstream hasn't added tool_result + rstrip)
      #
      # Fixes:
      #   a) Trailing whitespace — Anthropic rejects assistant content ending with whitespace.
      #   b) Tool result format  — Observation: plain text must become a tool_result block.
      #
      # Detection: upstream fix will contain both "tool_result" and "rstrip" in to_messages.
      unless _memory_text.include?("tool_result") && _memory_text.include?("rstrip")
        ::Gemlings::Memory.prepend(Module.new do
          def to_messages
            messages = super

            # Strip trailing whitespace — some LLM APIs (e.g. Anthropic) reject messages
            # whose string content ends with whitespace.
            messages = messages.map do |msg|
              msg[:content].is_a?(String) ? msg.merge(content: msg[:content].rstrip) : msg
            end

            # Rewrite "Observation: ..." user messages that follow a tool_calls step into
            # structured tool_result blocks. Anthropic requires that every tool_use in an
            # assistant message is immediately followed by a tool_result block.
            result = []
            messages.each do |msg|
              prev = result.last
              if prev && prev[:role] == "assistant" && prev[:tool_calls].present? &&
                 msg[:role] == "user" && msg[:content].is_a?(String) && msg[:content].start_with?("Observation:")
                observation = msg[:content].sub(/\AObservation:\s*/, "").strip
                tool_results = prev[:tool_calls].map { |tc| { type: "tool_result", tool_use_id: tc.id, content: observation } }
                result << msg.merge(content: tool_results)
              else
                result << msg
              end
            end

            result
          end
        end)
      end

      # Patch 2 — RubyLLMAdapter#load_messages (needed if upstream hasn't added tool_result handling)
      #
      # Fixes: tool_result content arrays must be passed to ruby_llm as role: :tool messages
      # with a tool_call_id, not as plain user text. Without this, ruby_llm sends a malformed
      # payload that Anthropic rejects with "tool_use without tool_result" errors.
      #
      # Detection: upstream fix will contain "tool_result" in load_messages.
      unless _adapter_text.include?("tool_result")
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
                attrs[:tool_calls] = send(:convert_tool_calls_to_ruby_llm, msg[:tool_calls]) if msg[:tool_calls]
                chat.add_message(attrs)
              else
                if content.is_a?(Array) && content.all? { |c| c.is_a?(Hash) && (c[:type] == "tool_result" || c["type"] == "tool_result") }
                  content.each do |tr|
                    chat.add_message(role: :tool, content: (tr[:content] || tr["content"]).to_s, tool_call_id: tr[:tool_use_id] || tr["tool_use_id"])
                  end
                else
                  chat.add_message(role: role.to_sym, content: content || "")
                end
              end
            end
          end
        end)
      end
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
