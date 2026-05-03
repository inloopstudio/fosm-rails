module Fosm
  # Safely purges FOSM records that have exceeded the configured data retention
  # window. Designed to be triggered from the Data Archival admin UI.
  #
  # == Safety guarantees
  #
  # 1. Re-checks archival eligibility of the model class on entry.
  # 2. Re-checks +Fosm::DataRetention.safe_to_purge?+ per record inside the job
  #    — the controller's pre-check is advisory only; the retention window or
  #    record state could change between the UI request and job execution.
  # 3. Missing records are silently skipped (already purged — idempotent).
  # 4. Records within the retention window are NEVER deleted, even when
  #    explicitly enqueued — this is the absolute last line of defence.
  # 5. +fosm_transition_logs+ rows are NOT deleted. The audit trail is
  #    preserved forever for compliance purposes.
  # 6. Errors on individual records are logged, not re-raised, so a bulk job
  #    continues processing the remaining records.
  # 7. Unknown or non-eligible model class names abort immediately without
  #    side-effects.
  #
  # == Usage
  #
  #   # Single record
  #   Fosm::DataRetentionPurgeJob.perform_later(
  #     model_class_name: "Fosm::FaasAccount",
  #     record_id:        "42",
  #     purged_by_label:  current_user.email
  #   )
  #
  #   # Bulk — purges every eligible record for the model
  #   Fosm::DataRetentionPurgeJob.perform_later(
  #     model_class_name: "Fosm::FaasAccount",
  #     bulk:             true,
  #     purged_by_label:  current_user.email
  #   )
  class DataRetentionPurgeJob < Fosm::ApplicationJob
    queue_as :default

    # @param model_class_name [String]  e.g. "Fosm::FaasAccount"
    # @param record_id [String, nil]    ID of a single record to purge
    # @param bulk [Boolean]             true → purge all eligible records
    # @param purged_by_label [String]   actor label for audit logging
    def perform(model_class_name:, record_id: nil, bulk: false, purged_by_label: "system")
      model_class = resolve_model_class(model_class_name)
      return unless model_class

      unless Fosm::DataRetention.archival_eligible?(model_class)
        log_warn "#{model_class_name} is not archival-eligible. Purge aborted."
        return
      end

      if bulk
        purge_all_expired(model_class, purged_by_label)
      elsif record_id.present?
        purge_single(model_class, record_id.to_s, purged_by_label)
      else
        log_warn "Neither bulk: true nor record_id provided. Nothing to purge."
      end
    end

    private

    def resolve_model_class(name)
      name.constantize
    rescue NameError => e
      log_error "Unknown model class '#{name}': #{e.message}"
      nil
    end

    def purge_single(model_class, record_id, purged_by_label)
      record = model_class.find_by(id: record_id)
      unless record
        log_warn "#{model_class.name}##{record_id} not found — already purged or never existed."
        return
      end

      # CRITICAL: re-verify retention window even if the controller already checked.
      # The window or state may have changed between the UI click and job execution.
      unless Fosm::DataRetention.safe_to_purge?(record)
        log_warn(
          "#{model_class.name}##{record_id} is within the " \
          "#{Fosm.config.data_retention_days}-day retention window or not in an " \
          "archival state. Skipping."
        )
        return
      end

      log_info "Purging #{model_class.name}##{record_id} " \
               "(archived_at: #{record.archived_at}, purged_by: #{purged_by_label})"
      record.destroy!
      log_info "Purged #{model_class.name}##{record_id} successfully."
    rescue => e
      log_error "Failed to purge #{model_class.name}##{record_id}: #{e.message}"
    end

    def purge_all_expired(model_class, purged_by_label)
      purged  = 0
      skipped = 0

      Fosm::DataRetention.all_eligible_for_purge(model_class).find_each do |record|
        # Per-record safety check — never blindly trust the scope alone.
        unless Fosm::DataRetention.safe_to_purge?(record)
          log_warn "Skipping #{model_class.name}##{record.id} — within retention window."
          skipped += 1
          next
        end

        begin
          record.destroy!
          purged += 1
        rescue => e
          log_error "Failed to purge #{model_class.name}##{record.id}: #{e.message}"
          skipped += 1
        end
      end

      log_info "Bulk purge complete for #{model_class.name}: " \
               "#{purged} purged, #{skipped} skipped (purged_by: #{purged_by_label})."
    end

    def log_info(msg)  = logger.info("[Fosm::DataRetentionPurgeJob] #{msg}")
    def log_warn(msg)  = logger.warn("[Fosm::DataRetentionPurgeJob] #{msg}")
    def log_error(msg) = logger.error("[Fosm::DataRetentionPurgeJob] #{msg}")

    def logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : Logger.new($stdout)
    end
  end
end
