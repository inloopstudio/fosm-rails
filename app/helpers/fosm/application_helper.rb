module Fosm
  module ApplicationHelper
    # Returns a human-friendly label for a FOSM state, suitable for display in views.
    def fosm_state_badge(state)
      content_tag(:span, state.to_s.humanize,
                  class: "text-xs font-medium px-2 py-0.5 rounded bg-gray-100 text-gray-700")
    end

    # Returns a human-friendly label for an actor stored in a TransitionLog.
    def fosm_actor_label(transition)
      if transition.by_agent?
        content_tag(:span, "AI Agent",
                    class: "text-xs font-medium text-purple-600 bg-purple-50 px-2 py-0.5 rounded")
      else
        transition.actor_label || transition.actor_type || "—"
      end
    end
  end
end
