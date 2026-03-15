module Fosm
  # In-memory buffer for high-throughput transition log writes.
  # Used when config.transition_log_strategy = :buffered.
  #
  # Entries accumulate in a thread-safe Queue and are bulk-INSERTed every
  # FLUSH_INTERVAL seconds by a background thread started at boot.
  #
  # Trade-offs vs :async:
  #   Pro:  Sub-millisecond fire! latency (no job enqueue overhead)
  #   Pro:  Fewer DB round-trips (bulk INSERT vs N individual INSERTs)
  #   Con:  Up to FLUSH_INTERVAL seconds of log delay
  #   Con:  Unflushed entries are lost if the process crashes
  #
  # To activate, set config.transition_log_strategy = :buffered in fosm.rb.
  # The flusher thread is started automatically by the engine initializer.
  module TransitionBuffer
    BUFFER         = Queue.new
    FLUSH_INTERVAL = 1  # seconds

    def self.push(entry)
      BUFFER << entry
    end

    # Starts the background flusher thread.
    # Called once by the engine after Rails initializes (if strategy is :buffered).
    def self.start_flusher!
      Thread.new do
        loop do
          sleep FLUSH_INTERVAL
          flush
        rescue => e
          ::Rails.logger.error("[FOSM] TransitionBuffer flush error: #{e.message}")
        end
      end
    end

    # Drain the buffer and bulk-INSERT all pending entries.
    # Safe to call manually (e.g. in tests or before process exit).
    def self.flush
      entries = []
      entries << BUFFER.pop(true) while !BUFFER.empty? rescue nil
      return if entries.empty?

      now = Time.current
      rows = entries.map { |e| e.merge("created_at" => now) }
      Fosm::TransitionLog.insert_all(rows)
    end

    def self.pending_count
      BUFFER.size
    end
  end
end
