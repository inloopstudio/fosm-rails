module Fosm
  module Admin
    # Admin dashboard for data retention policy enforcement.
    #
    # Shows all archival-eligible FOSM models (terminal state containing "archiv"
    # + archived_at column) and lets admins review and purge records that have
    # exceeded the configured retention window.
    #
    # All destructive actions run asynchronously via DataRetentionPurgeJob so
    # the request/response cycle is never blocked by bulk deletes.
    class DataRetentionController < BaseController
      PER_PAGE = 50

      # GET /fosm/admin/data_retention
      # Lists every archival-eligible model with counts.
      def index
        @retention_days  = Fosm.config.data_retention_days
        @cutoff_date     = Fosm::DataRetention.retention_cutoff_date

        @eligible_models = Fosm::DataRetention.archival_eligible_models.map do |model_class|
          slug = Fosm::Registry.all.find { |_s, klass| klass.name == model_class.name }&.first
          {
            model_class:        model_class,
            slug:               slug,
            name:               model_class.name.demodulize.titleize,
            archival_states:    Fosm::DataRetention.archival_states_for(model_class),
            total_in_archive:   Fosm::DataRetention.total_in_archival_state(model_class),
            eligible_for_purge: Fosm::DataRetention.total_eligible_for_purge(model_class)
          }
        end
      end

      # GET /fosm/admin/data_retention/:id   (:id = model slug, e.g. "faas_account")
      # Paginated list of purge-eligible records for one model.
      def show
        @model_class  = resolve_eligible_model!(params[:id])
        @slug         = params[:id]
        @name         = @model_class.name.demodulize.titleize

        @retention_days  = Fosm.config.data_retention_days
        @cutoff_date     = Fosm::DataRetention.retention_cutoff_date
        @archival_states = Fosm::DataRetention.archival_states_for(@model_class)

        @page        = [ params[:page].to_i, 1 ].max
        @total       = Fosm::DataRetention.total_eligible_for_purge(@model_class)
        @total_pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max
        @records     = Fosm::DataRetention.records_eligible_for_purge(
          @model_class, page: @page, per_page: PER_PAGE
        )
      end

      # POST /fosm/admin/data_retention/:id/purge_record
      # Enqueues a single-record purge. params[:record_id] identifies the row.
      def purge_record
        @model_class = resolve_eligible_model!(params[:id])
        record = @model_class.find_by(id: params[:record_id])

        unless record
          redirect_to fosm.admin_data_retention_path(params[:id]),
            alert: "Record not found — it may have already been purged."
          return
        end

        unless Fosm::DataRetention.safe_to_purge?(record)
          redirect_to fosm.admin_data_retention_path(params[:id]),
            alert: "Record ##{record.id} is not eligible for purge " \
                   "(within the #{Fosm.config.data_retention_days}-day retention window)."
          return
        end

        Fosm::DataRetentionPurgeJob.perform_later(
          model_class_name: @model_class.name,
          record_id:        record.id.to_s,
          purged_by_label:  current_admin_label
        )

        redirect_to fosm.admin_data_retention_path(params[:id]),
          notice: "Record ##{record.id} has been queued for purge."
      end

      # POST /fosm/admin/data_retention/:id/purge_all_expired
      # Enqueues a bulk purge of all retention-expired records for this model.
      def purge_all_expired
        @model_class = resolve_eligible_model!(params[:id])
        total = Fosm::DataRetention.total_eligible_for_purge(@model_class)

        if total.zero?
          redirect_to fosm.admin_data_retention_path(params[:id]),
            notice: "No records are eligible for purge."
          return
        end

        Fosm::DataRetentionPurgeJob.perform_later(
          model_class_name: @model_class.name,
          bulk:             true,
          purged_by_label:  current_admin_label
        )

        redirect_to fosm.admin_data_retention_path(params[:id]),
          notice: "#{total} record(s) queued for bulk purge. This runs asynchronously."
      end

      private

      def resolve_eligible_model!(slug)
        model_class = Fosm::Registry.find(slug)
        raise ActionController::RoutingError, "Unknown FOSM model: #{slug}" unless model_class
        unless Fosm::DataRetention.archival_eligible?(model_class)
          raise ActionController::RoutingError,
            "Model '#{slug}' is not archival-eligible " \
            "(needs a terminal state containing 'archiv' AND an archived_at column)."
        end
        model_class
      end

      def current_admin_label
        user = instance_exec(&Fosm.config.current_user_method)
        return "admin" unless user
        user.respond_to?(:email) ? user.email : user.to_s
      rescue
        "admin"
      end
    end
  end
end
