module Fosm
  module Admin
    class SettingsController < BaseController
      def show
        @llm_providers = detect_llm_providers
        @fosm_config   = summarize_fosm_config
      end

      private

      LLM_PROVIDERS = [
        { name: "Anthropic (Claude)",  env_key: "ANTHROPIC_API_KEY",   model_prefix: "anthropic/" },
        { name: "OpenAI",              env_key: "OPENAI_API_KEY",       model_prefix: "openai/" },
        { name: "Google (Gemini)",     env_key: "GEMINI_API_KEY",       model_prefix: "gemini/" },
        { name: "Cohere",              env_key: "COHERE_API_KEY",       model_prefix: "cohere/" },
        { name: "Mistral",             env_key: "MISTRAL_API_KEY",      model_prefix: "mistral/" }
      ].freeze

      def detect_llm_providers
        LLM_PROVIDERS.map do |provider|
          value = ENV[provider[:env_key]]
          {
            name:       provider[:name],
            env_key:    provider[:env_key],
            configured: value.present?,
            hint:       value.present? ? "#{value.length} chars, starts with #{value[0..3]}…" : nil
          }
        end
      end

      def summarize_fosm_config
        cfg = Fosm.config
        {
          base_controller:    cfg.base_controller,
          admin_layout:       cfg.admin_layout,
          app_layout:         cfg.app_layout,
          admin_authorize:    cfg.admin_authorize.inspect,
          app_authorize:      cfg.app_authorize.inspect,
          current_user_method: cfg.current_user_method.inspect
        }
      end
    end
  end
end
