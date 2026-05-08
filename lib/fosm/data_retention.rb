module Fosm
  # Service for discovering and managing FOSM objects under a data retention policy.
  #
  # == Eligibility criteria
  #
  # A model is "archival-eligible" when it satisfies BOTH of the following:
  #   1. It has at least one *terminal* state whose name contains "archiv"
  #      (case-insensitive — covers :archived, :archival, :archiviert, etc.)
  #   2. Its database table has an `archived_at` datetime/timestamp column.
  #
  # == Retention window
  #
  # Driven by +Fosm.config.data_retention_days+ (default 3650 = 10 years).
  # Records with a non-nil +archived_at+ older than the cutoff are
  # "eligible for purge".
  #
  # == Audit-safety guarantee
  #
  # Purging a business record NEVER touches +fosm_transition_logs+. The audit
  # trail is intentionally kept forever for compliance purposes. Only the
  # source record (e.g. the Invoice or FaasAccount row) is deleted.
  module DataRetention
    class << self
      # All registered FOSM model classes that meet both eligibility criteria.
      #
      # @return [Array<Class>]
      def archival_eligible_models
        Fosm::Registry.model_classes.select { |mc| archival_eligible?(mc) }
      end

      # Returns true when the model has an archival terminal state AND an
      # `archived_at` column.
      #
      # @param model_class [Class]
      # @return [Boolean]
      def archival_eligible?(model_class)
        has_archival_terminal_state?(model_class) && has_archived_at_column?(model_class)
      end

      # Returns true when at least one terminal state name includes "archiv".
      #
      # @param model_class [Class]
      # @return [Boolean]
      def has_archival_terminal_state?(model_class)
        lifecycle = model_class.try(:fosm_lifecycle)
        return false unless lifecycle
        lifecycle.states.any? { |s| s.terminal? && s.name.to_s.downcase.include?("archiv") }
      end

      # Returns true when the model's table has an `archived_at` column.
      #
      # Rescues gracefully if the table doesn't exist yet (e.g. during migrations).
      #
      # @param model_class [Class]
      # @return [Boolean]
      def has_archived_at_column?(model_class)
        model_class.column_names.include?("archived_at")
      rescue => _e
        false
      end

      # All archival terminal state names for the model (as strings).
      #
      # @param model_class [Class]
      # @return [Array<String>]
      def archival_states_for(model_class)
        lifecycle = model_class.try(:fosm_lifecycle)
        return [] unless lifecycle
        lifecycle.states
          .select { |s| s.terminal? && s.name.to_s.downcase.include?("archiv") }
          .map { |s| s.name.to_s }
      end

      # The cutoff timestamp: records with `archived_at` before this moment are
      # eligible for purge.
      #
      # @return [ActiveSupport::TimeWithZone]
      def retention_cutoff_date
        Fosm.config.data_retention_days.days.ago
      end

      # Total records currently in any archival terminal state, regardless of
      # whether they have passed the retention window.
      #
      # @param model_class [Class]
      # @return [Integer]
      def total_in_archival_state(model_class)
        states = archival_states_for(model_class)
        return 0 if states.empty?
        model_class.where(state: states).count
      end

      # Total records eligible for purge: in an archival state, with a non-nil
      # `archived_at` older than the retention cutoff.
      #
      # @param model_class [Class]
      # @return [Integer]
      def total_eligible_for_purge(model_class)
        eligible_scope(model_class).count
      end

      # Returns a paginated ActiveRecord relation of purge-eligible records,
      # ordered oldest-first (most overdue first).
      #
      # Pagination is offset-based. Pages are 1-indexed.
      #
      # @param model_class [Class]
      # @param page [Integer] 1-based page number (clamped to >= 1)
      # @param per_page [Integer] max records per page
      # @return [ActiveRecord::Relation]
      def records_eligible_for_purge(model_class, page: 1, per_page: 50)
        offset = ([ page.to_i, 1 ].max - 1) * per_page
        eligible_scope(model_class).offset(offset).limit(per_page)
      end

      # An unbounded scope of all purge-eligible records for use in batch jobs.
      # Callers should use +find_each+ to avoid loading all rows into memory.
      #
      # @param model_class [Class]
      # @return [ActiveRecord::Relation]
      def all_eligible_for_purge(model_class)
        eligible_scope(model_class)
      end

      # Returns true when a single record is safe to purge:
      #
      #   - Its class has an `archived_at` column (defensive belt-and-suspenders).
      #   - +archived_at+ is not nil.
      #   - +archived_at+ is strictly older than the retention cutoff.
      #   - The record's current state is an archival terminal state.
      #
      # This is the *authoritative* pre-purge check. Always call this immediately
      # before destroying, even when the controller already checked — the
      # retention window or record state may have changed since the UI check.
      #
      # @param record [ActiveRecord::Base]
      # @return [Boolean]
      def safe_to_purge?(record)
        return false unless record.class.column_names.include?("archived_at")
        archived_at = record.archived_at
        return false if archived_at.nil?
        return false if archived_at >= retention_cutoff_date
        archival_states_for(record.class).include?(record.state.to_s)
      end

      private

      # Shared base scope for eligibility queries.
      def eligible_scope(model_class)
        states = archival_states_for(model_class)
        return model_class.none if states.empty?
        model_class
          .where(state: states)
          .where.not(archived_at: nil)
          .where("archived_at < ?", retention_cutoff_date)
          .order(archived_at: :asc)
      end
    end
  end
end
