module Fosm
  # Writes a single transition log entry asynchronously.
  # Used when config.transition_log_strategy = :async (SolidQueue default).
  #
  # The state UPDATE has already committed before this job runs, so there is
  # at most a brief delay between the transition completing and the log entry
  # appearing. For strict consistency, use config.transition_log_strategy = :sync.
  class TransitionLogJob < Fosm::ApplicationJob
    queue_as :fosm_audit

    # @param log_data [Hash] all columns for the transition log row (string keys)
    def perform(log_data)
      Fosm::TransitionLog.create!(log_data)
    end
  end
end
