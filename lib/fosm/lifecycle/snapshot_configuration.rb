module Fosm
  module Lifecycle
    # Configuration for when and what to snapshot during transitions.
    # Supports multiple strategies: every, count, time, terminal, manual
    class SnapshotConfiguration
      # Strategy types
      STRATEGIES = %i[every count time terminal manual].freeze

      attr_reader :strategy, :interval, :conditions

      def initialize
        @strategy = :manual  # default: no automatic snapshots
        @attributes = []     # empty = snapshot all readable attributes
        @interval = nil      # for :count (transitions) or :time (seconds)
        @conditions = []     # additional conditions that must be met
      end

      # Returns the configured attributes
      def attributes
        @attributes
      end

      # DSL: snapshot on every transition
      # Usage: snapshot :every
      def every
        @strategy = :every
      end

      # DSL: snapshot every N transitions
      # Usage: snapshot every: 10
      def count(n)
        @strategy = :count
        @interval = n
      end

      # DSL: snapshot if last snapshot was more than N seconds ago
      # Usage: snapshot time: 300 (5 minutes)
      def time(seconds)
        @strategy = :time
        @interval = seconds
      end

      # DSL: snapshot only on terminal states
      # Usage: snapshot :terminal
      def terminal
        @strategy = :terminal
      end

      # DSL: manual snapshots only (default)
      # Usage: snapshot :manual
      def manual
        @strategy = :manual
      end

      # DSL: specify which attributes to snapshot
      # Usage: snapshot_attributes :amount, :status, :line_items_count
      #        snapshot_attributes %i[amount status]  # array also works
      def set_attributes(*attrs)
        @attributes = attrs.flatten.map(&:to_s)
      end

      # Check if a snapshot should be taken for this transition
      # @param transition_count [Integer] transitions since last snapshot
      # @param seconds_since_last [Float] seconds since last snapshot
      # @param to_state [String] the state we're transitioning to
      # @param to_state_terminal [Boolean] whether the destination state is terminal
      # @param force [Boolean] manual override to force snapshot
      def should_snapshot?(transition_count:, seconds_since_last:, to_state:, to_state_terminal:, force: false)
        return true if force
        return false if @strategy == :manual
        return true if @strategy == :every
        return true if @strategy == :terminal && to_state_terminal
        return true if @strategy == :count && transition_count >= @interval
        return true if @strategy == :time && seconds_since_last >= @interval

        false
      end

      # Build the snapshot data from a record
      # @param record [ActiveRecord::Base] the record to snapshot
      # @return [Hash] the snapshot data
      def build_snapshot(record)
        attrs = @attributes.any? ? @attributes : default_attributes(record)

        snapshot = {}
        attrs.each do |attr|
          value = read_attribute(record, attr)
          snapshot[attr] = serialize_value(value)
        end

        # Always include core FOSM metadata
        snapshot["_fosm_snapshot_meta"] = {
          "snapshot_at" => Time.current.iso8601,
          "record_class" => record.class.name,
          "record_id" => record.id.to_s
        }

        snapshot
      end

      private

      # Default attributes to snapshot when none specified
      # Excludes internal AR columns and associations
      def default_attributes(record)
        record.attributes.keys.reject do |attr|
          attr.start_with?("_") ||
            %w[id created_at updated_at].include?(attr) ||
            attr.end_with?("_id") && record.class.reflect_on_association(attr.sub(/_id$/, ""))
        end
      end

      def read_attribute(record, attr)
        # Handle associations (e.g., :line_items -> count)
        if attr.to_s.end_with?("_count") || attr.to_s.start_with?("count_")
          association_name = attr.to_s.gsub(/^_count|count_/, "").pluralize
          if record.respond_to?(association_name)
            record.send(association_name).count
          else
            record.send(attr)
          end
        else
          record.send(attr)
        end
      rescue => e
        # Graceful degradation: log error, return nil for this attribute
        nil
      end

      def serialize_value(value)
        case value
        when ActiveRecord::Base
          { "_type" => "record", "class" => value.class.name, "id" => value.id }
        when ActiveRecord::Relation, Array
          value.map { |v| serialize_value(v) }
        when Time, DateTime, Date
          { "_type" => "datetime", "value" => value.iso8601 }
        when BigDecimal
          { "_type" => "decimal", "value" => value.to_s }
        when Symbol
          value.to_s
        else
          value
        end
      end
    end
  end
end
