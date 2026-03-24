# FOSM Fiber Integration Research

> Research on Ruby 3+ fiber-based concurrency patterns for FOSM state machines
> Author: Fiber Concurrency Researcher (GoldKnight)
> Date: 2026-03-20

---

## Executive Summary

Ruby 3.0+ fibers with the Fiber::Scheduler interface provide cooperative multitasking that is ideal for I/O-bound state machine operations. Unlike threads (preemptive, heavy memory), fibers yield control only at explicit points, making state transitions deterministic and race-condition-free by default.

**Key insight for FOSM**: State machine transitions are naturally sequential (check → guard → write → side-effect), but multiple transitions across different records can be concurrent. Fibers excel at this "per-record sequential, cross-record concurrent" pattern.

---

## Core Ruby Fiber Concepts

### The Fiber Scheduler Interface (Ruby 3.0+)

```ruby
# A minimal scheduler implementation showing the hooks
class FosmScheduler
  def initialize
    @readable = {}
    @writable = {}
    @timers = []
  end
  
  # Called when fiber calls IO.read/recv/etc
  def io_wait(io, events, duration)
    fiber = Fiber.current
    @readable[io] = fiber if events.include?(:read)
    @writable[io] = fiber if events.include?(:write)
    Fiber.yield
  end
  
  # Called when fiber calls sleep
  def kernel_sleep(duration)
    @timers << [Time.now + duration, Fiber.current]
    Fiber.yield
  end
  
  # The event loop - runs when thread would exit
  def close
    while @readable.any? || @writable.any? || @timers.any?
      # epoll/kqueue/io_uring would go here
      # Resume fibers whose I/O is ready or timer expired
    end
  end
end
```

**Key point**: You don't implement this yourself. Use the `async` gem which provides a production-ready `Async::Scheduler`.

---

## Integration Point 1: Fiber-Isolated Transition Execution

### Current Pattern

```ruby
# lib/fosm/lifecycle.rb - current fire! method
def fire!(event_name, actor: nil, metadata: {})
  # ... validations ...
  
  ActiveRecord::Base.transaction do
    update!(state: to_state)
    
    if Fosm.config.transition_log_strategy == :sync
      Fosm::TransitionLog.create!(log_data)
    end
    
    event_def.side_effects.each do |side_effect_def|
      side_effect_def.call(self, transition_data)  # Blocks here
    end
  end
  
  # Async jobs enqueued AFTER transaction commits
  WebhookDeliveryJob.perform_later(...)  # More blocking I/O
end
```

**Problem**: Side effects and webhook jobs block the request thread. Under high load, thread pool exhaustion occurs.

### Fiber-Enhanced Pattern

```ruby
# lib/fosm/lifecycle_fiber.rb - proposed fiber integration
require "async"

module Fosm
  module LifecycleFiber
    extend ActiveSupport::Concern
    
    class_methods do
      # Configure fiber scheduler for this lifecycle
      def fiber_scheduler
        @fiber_scheduler ||= Async::Scheduler.new
      end
      
      def fiber_scheduler=(scheduler)
        @fiber_scheduler = scheduler
      end
    end
    
    # Fire transition inside a fiber that can yield during I/O
    def fire_async!(event_name, actor: nil, metadata: {})
      # Run in fiber that yields during DB operations
      Async(fiber_scheduler) do |task|
        # Pre-flight checks (same as fire!)
        event_def = validate_transition!(event_name)
        
        # Suspend fiber during DB transaction
        # The scheduler switches to another fiber while we wait for Postgres
        result = nil
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            # Fiber yields here during UPDATE
            update!(state: event_def.to_state.to_s)
            
            if sync_logging?
              Fosm::TransitionLog.create!(build_log_data(event_name, actor, metadata))
            end
            
            # Side effects run inside fiber - can yield for HTTP calls
            run_side_effects_in_fiber(event_def, transition_data)
          end
        end
        
        # Webhook delivery as fiber task (concurrent, not job queue)
        deliver_webhooks_async(event_name, metadata)
        
        { success: true, state: reload.state }
      rescue Fosm::Error => e
        { success: false, error: e.message }
      end
    end
    
    private
    
    def run_side_effects_in_fiber(event_def, transition_data)
      event_def.side_effects.each do |side_effect_def|
        # If side effect hits I/O, fiber yields automatically
        # Other transitions continue processing
        side_effect_def.call(self, transition_data)
      end
    end
    
    def deliver_webhooks_async(event_name, metadata)
      # Spawn child fiber for each webhook
      # All run concurrently, parent doesn't wait
      Async do
        Fosm::WebhookSubscription.for_event(self.class.name, event_name).each do |sub|
          Async do
            deliver_webhook_fiber(sub, build_payload(event_name, metadata))
          end
        end
      end
    end
    
    def deliver_webhook_fiber(subscription, payload)
      # Using async-http instead of Net::HTTP
      # Fiber yields during request, resumes on response
      client = Async::HTTP::Client.new(Async::HTTP::Endpoint.parse(subscription.url))
      headers = [["content-type", "application/json"]]
      headers << ["x-fosm-signature", sign_payload(payload, subscription.secret_token)]
      
      response = client.post(subscription.url, headers, payload.to_json)
      response.read  # Fiber yields here
    ensure
      client&.close
    end
  end
end
```

### Usage Pattern

```ruby
class Invoice < ApplicationRecord
  include Fosm::Lifecycle
  include Fosm::LifecycleFiber  # Add fiber capabilities
  
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    event :send_invoice, from: :draft, to: :sent
    
    side_effect :notify_client, on: :send_invoice do |inv, transition|
      # This HTTP call now yields the fiber
      # Other invoice transitions can run concurrently
      InvoiceMailer.send_to_client(inv).deliver_now  # Inlined, not queued
    end
  end
end

# In controller
Async do
  # Process 100 invoices concurrently with 1 thread
  invoices.each do |invoice|
    Async do
      invoice.fire_async!(:send_invoice, actor: current_user)
    end
  end
end.wait  # Wait for all fibers to complete
```

**Benefits**:
- 1 thread handles 1000+ concurrent transitions
- Side effects (HTTP calls) don't block other transitions
- Webhook delivery happens immediately, not via job queue
- No thread pool exhaustion under load

---

## Integration Point 2: Concurrent Guard Evaluation with Async::Barrier

### Current Pattern

```ruby
# Guards run sequentially - slow if each does I/O
event_def.guards.each do |guard_def|
  unless guard_def.call(self)
    raise Fosm::GuardFailed.new(guard_def.name, event_name)
  end
end
```

**Problem**: If 3 guards each make HTTP calls (100ms each), transition takes 300ms+ before even touching the database.

### Fiber-Concurrent Pattern

```ruby
# lib/fosm/lifecycle/guard_runner.rb
require "async"
require "async/barrier"

module Fosm
  class GuardRunner
    def self.evaluate_concurrently(guard_definitions, record, timeout: 5)
      barrier = Async::Barrier.new
      results = {}
      
      Async do
        guard_definitions.each do |guard_def|
          barrier.async do
            # Each guard runs in its own fiber
            # If it hits I/O, it yields; other guards continue
            start_time = Time.now
            result = guard_def.call(record)
            elapsed = Time.now - start_time
            
            results[guard_def.name] = {
              passed: result,
              elapsed_ms: (elapsed * 1000).round(2)
            }
          end
        end
        
        # Wait for all guards with timeout
        # If any fiber hasn't completed, timeout raises
        barrier.wait(timeout: timeout)
      end
      
      # Check results
      failed = results.select { |_, v| !v[:passed] }
      if failed.any?
        failed_names = failed.keys.join(", ")
        raise Fosm::GuardFailed.new(failed_names, "concurrent evaluation")
      end
      
      results
    rescue Async::TimeoutError
      raise Fosm::GuardFailed.new("timeout", "guard evaluation exceeded #{timeout}s")
    end
  end
end
```

### Integration into fire!

```ruby
def fire!(event_name, actor: nil, metadata: {})
  # ... event lookup, terminal check, transition validation ...
  
  # Run guards concurrently if fiber scheduler available
  if Async::Task.current?
    # Inside async context - use concurrent evaluation
    Fosm::GuardRunner.evaluate_concurrently(event_def.guards, self)
  else
    # Fallback to sequential
    event_def.guards.each do |guard_def|
      unless guard_def.call(self)
        raise Fosm::GuardFailed.new(guard_def.name, event_name)
      end
    end
  end
  
  # ... continue with transaction ...
end
```

### Example Guard with I/O

```ruby
class Invoice < ApplicationRecord
  lifecycle do
    event :pay, from: :sent, to: :paid
    
    # This guard checks external credit service
    # With fibers, it yields during HTTP call
    guard :credit_check_passed, on: :pay do |invoice|
      # Fiber yields here during HTTP request
      response = CreditService.check(invoice.client_id)
      response.approved?
    end
    
    # This guard checks inventory system
    guard :inventory_available, on: :pay do |invoice|
      # Fiber yields here during DB call to inventory DB
      InventorySystem.available?(invoice.sku)
    end
  end
end
```

**Performance**: 3 guards × 100ms = 300ms sequential, ~100ms concurrent (plus overhead).

---

## Integration Point 3: Fiber-Based TransitionBuffer

### Current Pattern (Thread-based)

```ruby
module Fosm
  module TransitionBuffer
    BUFFER = Queue.new
    FLUSH_INTERVAL = 1
    
    def self.start_flusher!
      Thread.new do
        loop do
          sleep FLUSH_INTERVAL
          flush
        end
      end
    end
    
    def self.flush
      entries = []
      entries << BUFFER.pop(true) while !BUFFER.empty? rescue nil
      return if entries.empty?
      
      Fosm::TransitionLog.insert_all(entries.map { |e| e.merge("created_at" => Time.current) })
    end
  end
end
```

**Problems**:
- Fixed 1-second sleep (latency vs throughput tradeoff)
- Thread per buffer (overhead)
- No backpressure - buffer grows unbounded under load

### Fiber-Enhanced Pattern (Timer-based)

```ruby
# lib/fosm/transition_buffer_fiber.rb
require "async"
require "async/clock"

module Fosm
  module TransitionBufferFiber
    BUFFER = Async::Queue.new
    MAX_BUFFER_SIZE = 10_000
    FLUSH_INTERVAL = 1.0
    
    class << self
      attr_accessor :scheduler
      
      def push(entry)
        # Backpressure: wait if buffer full
        while BUFFER.size >= MAX_BUFFER_SIZE
          Async::Task.yield
        end
        BUFFER << entry
      end
      
      def start_flusher!
        @scheduler = Async::Scheduler.new
        
        Async(@scheduler) do
          loop do
            # Use timer instead of sleep - more precise
            # Fiber yields, resumes after interval or on signal
            Async::Clock.timeout(FLUSH_INTERVAL) do
              # Wait for either timeout OR buffer reaching batch size
              wait_for_flush_condition
            end
            
            flush
          rescue => e
            Rails.logger.error("[FOSM] Buffer flush error: #{e.message}")
          end
        end
      end
      
      def flush
        batch = []
        
        # Drain up to batch size (non-blocking)
        while batch.size < batch_size && (entry = BUFFER.try_pop)
          batch << entry
        end
        
        return if batch.empty?
        
        # Bulk insert with fiber-aware connection
        ActiveRecord::Base.connection_pool.with_connection do
          Fosm::TransitionLog.insert_all(
            batch.map { |e| e.merge("created_at" => Time.current) }
          )
        end
        
        Rails.logger.info("[FOSM] Flushed #{batch.size} transition logs")
      end
      
      def pending_count
        BUFFER.size
      end
      
      private
      
      def wait_for_flush_condition
        # Block until either:
        # 1. Timer expires (interval reached)
        # 2. Buffer has enough entries for efficient batch
        # 3. Explicit flush signal received
        
        until should_flush?
          Async::Task.yield
        end
      end
      
      def should_flush?
        BUFFER.size >= batch_size || @force_flush
      end
      
      def batch_size
        # Dynamic: larger batches under load
        [BUFFER.size / 10, 100].max
      end
    end
  end
end
```

### Configuration Integration

```ruby
# config/initializers/fosm.rb
Fosm.configure do |config|
  config.transition_log_strategy = :fiber_buffered  # New strategy
end

# lib/fosm/engine.rb - auto-start fiber scheduler
module Fosm
  class Engine < ::Rails::Engine
    initializer "fosm.fiber_scheduler" do
      if config.transition_log_strategy == :fiber_buffered
        Fosm::TransitionBufferFiber.start_flusher!
      end
    end
  end
end
```

**Benefits**:
- No dedicated thread (runs in main async loop)
- Dynamic batch sizing based on load
- Backpressure prevents memory exhaustion
- Lower latency under burst load (flush when batch ready, not on interval)

---

## Integration Point 4: Structured Concurrency for Agent Bulk Operations

### Current Pattern

```ruby
# AI agent fires events sequentially
# If agent processes 50 invoices, each waits for the previous
invoices.each do |inv|
  result = inv.fire!(:mark_overdue, actor: :agent)
  # Wait for full cycle: check → guard → DB → side effects → webhooks
end
# Total time: 50 × ~50ms = 2500ms
```

### Fiber-Concurrent Pattern with Supervision

```ruby
# lib/fosm/agent_bulk_operations.rb
require "async"
require "async/barrier"
require "async/semaphore"

module Fosm
  class AgentBulkOperations
    # Process N records with bounded concurrency and supervision
    def self.fire_all!(records, event_name, actor: :agent, max_concurrent: 10)
      results = {}
      semaphore = Async::Semaphore.new(max_concurrent)  # Limit concurrency
      barrier = Async::Barrier.new  # Track all children
      
      Async do |parent|
        records.each do |record|
          # Acquire semaphore slot (blocks if at limit)
          semaphore.acquire do
            barrier.async do |child|
              # Each child fiber runs one transition
              # Parent can monitor, cancel, or timeout children
              
              result = record.fire!(event_name, actor: actor)
              results[record.id] = { success: true, state: result }
              
            rescue Fosm::Error => e
              results[record.id] = { success: false, error: e.class.name, message: e.message }
            rescue => e
              results[record.id] = { success: false, error: "Unexpected", message: e.message }
              # Let parent know about unexpected errors
              parent.raise(e) if should_abort_on_error?(e)
            end
          end
        end
        
        # Wait for all children (or timeout)
        barrier.wait(timeout: 30)
        
      rescue Async::TimeoutError
        # Cancel remaining children
        barrier.stop
        raise Fosm::BulkOperationTimeout.new("Bulk operation timed out")
      end
      
      results
    end
    
    # All-or-nothing batch (transaction across records)
    def self.fire_all_or_nothing!(records, event_name, actor: :agent)
      # This is the "Erlang supervisor" pattern
      # If any child fails, cancel all others
      
      Async do
        barrier = Async::Barrier.new
        
        children = records.map do |record|
          barrier.async do
            record.fire!(event_name, actor: actor)
          end
        end
        
        begin
          barrier.wait
        rescue => e
          # Cancel all children on first failure
          barrier.stop
          raise Fosm::BulkOperationFailed.new("Rolled back due to: #{e.message}")
        end
      end
    end
  end
end
```

### Agent Integration

```ruby
# app/agents/fosm/invoice_agent.rb
class Fosm::InvoiceAgent < Fosm::Agent
  model_class Fosm::Invoice
  
  # Add bulk tool for AI agent
  fosm_tool :bulk_mark_overdue,
            description: "Mark multiple invoices as overdue concurrently",
            inputs: { ids: "Array of invoice IDs", max_concurrent: "Max parallel operations (default 10)" } do |ids:, max_concurrent: 10|
    
    invoices = Fosm::Invoice.where(id: ids, state: "sent")
    
    # Run with structured concurrency
    results = Fosm::AgentBulkOperations.fire_all!(
      invoices,
      :mark_overdue,
      actor: :agent,
      max_concurrent: max_concurrent
    )
    
    succeeded = results.count { |_, v| v[:success] }
    failed = results.count { |_, v| !v[:success] }
    
    {
      processed: ids.size,
      succeeded: succeeded,
      failed: failed,
      details: results
    }
  end
end
```

**Benefits**:
- Bounded concurrency prevents DB connection pool exhaustion
- Parent fiber can cancel all children on timeout or error
- Results aggregated and returned to agent
- "All-or-nothing" pattern for transactional batches

---

## Integration Point 5: Race Condition Prevention with Fiber-Aware Locking

### The Problem: Check-Then-Act Race

```ruby
# Even with fibers, logical races exist
def approve_invoice!(actor)
  # Fiber A reads
  return false unless can_approve?  # State is :pending
  
  # Fiber B runs, also reads can_approve? = true
  # Fiber B updates state to :approved and commits
  
  # Fiber A resumes, UPDATE runs
  update!(state: :approved)  # Overwrites B's transition - BUG!
end
```

### Solution: Fiber-Aware Optimistic Locking

```ruby
# lib/fosm/lifecycle/race_protection.rb
module Fosm
  module RaceProtection
    extend ActiveSupport::Concern
    
    included do
      # Add lock_version if not present
      # FOSM generator should add this to migrations
    end
    
    # Fire with optimistic locking at fiber level
    def fire_with_lock!(event_name, actor: nil, metadata: {}, retries: 3)
      attempt = 0
      
      begin
        # Reload with lock_version check
        fresh = self.class.lock.find(id)
        
        # Check if state changed under us
        if fresh.state != state
          raise Fosm::ConcurrentTransition.new(
            "State changed from #{state} to #{fresh.state} by another process"
          )
        end
        
        # Run the transition on fresh record
        fresh.fire!(event_name, actor: actor, metadata: metadata)
        
        # Sync current instance with fresh
        reload
        
      rescue ActiveRecord::StaleObjectError
        attempt += 1
        if attempt <= retries
          # Brief yield to let other fibers complete
          Async::Task.yield if defined?(Async::Task)
          sleep(0.01 * attempt)  # Exponential backoff
          retry
        else
          raise Fosm::ConcurrentTransition.new("Max retries exceeded due to contention")
        end
      end
    end
  end
end
```

### Fiber-Aware Mutex Alternative

```ruby
# For per-record transition serialization
module Fosm
  class TransitionLock
    MUTEXES = {}
    MUTEX_MUTEX = Mutex.new  # Protects the hash itself
    
    def self.synchronize(record)
      key = "#{record.class.name}:#{record.id}"
      
      # Get or create fiber-aware mutex for this record
      mutex = MUTEX_MUTEX.synchronize do
        MUTEXES[key] ||= Async::Mutex.new  # Fiber-aware mutex from async gem
      end
      
      # Acquire lock (yields fiber if held, resumes when free)
      mutex.acquire do
        yield
      end
    end
    
    # Cleanup when record is destroyed
    def self.release(record)
      key = "#{record.class.name}:#{record.id}"
      MUTEX_MUTEX.synchronize do
        MUTEXES.delete(key)
      end
    end
  end
end
```

### Integration into fire!

```ruby
def fire!(event_name, actor: nil, metadata: {})
  lifecycle = self.class.fosm_lifecycle
  event_def = lifecycle.find_event(event_name)
  
  # If in async context, use fiber-aware lock
  if defined?(Async::Task) && Async::Task.current?
    Fosm::TransitionLock.synchronize(self) do
      execute_transition!(event_def, actor, metadata)
    end
  else
    # Fallback to optimistic locking
    execute_transition!(event_def, actor, metadata)
  end
end
```

**Benefits**:
- No database-level locks held during guard evaluation
- Per-record granularity (invoice 1 and 2 can transition concurrently)
- Automatic cleanup on fiber completion
- Compatible with existing optimistic locking

---

## Comparison with Erlang/OTP Patterns

| Pattern | Erlang/OTP | Ruby Fibers (FOSM) |
|---------|-----------|-------------------|
| **Isolation** | Process has private heap | Fiber shares memory, but yields predictably |
| **Fault tolerance** | Supervisor restarts crashed processes | No automatic restart (use `rescue` blocks) |
| **Communication** | Message passing (mailbox) | Shared state + Async::Queue for coordination |
| **Concurrency** | Preemptive (per-process) | Cooperative (explicit yield points) |
| **Error containment** | Process crash doesn't affect others | Unhandled exception kills fiber, parent can catch |
| **Monitoring** | `monitor/2` and `link/2` | `Async::Barrier` and `Async::Condition` |

### Erlang-Inspired Supervisor Pattern for FOSM

```ruby
# Supervisor for agent bulk operations
class Fosm::TransitionSupervisor
  def self.supervise(records, event_name, max_retries: 3)
    results = {}
    
    Async do
      barrier = Async::Barrier.new
      
      records.each do |record|
        barrier.async do
          retries = 0
          
          begin
            record.fire!(event_name, actor: :agent)
            results[record.id] = { status: :success }
            
          rescue => e
            retries += 1
            if retries <= max_retries
              # Exponential backoff
              sleep(0.1 * (2 ** retries))
              retry
            else
              results[record.id] = { status: :failed, error: e.message }
              # Don't re-raise - let other children continue
            end
          end
        end
      end
      
      barrier.wait
    end
    
    results
  end
end
```

---

## Implementation Roadmap

### Phase 1: Foundation (No breaking changes)
1. Add `async` gem as optional dependency
2. Create `Fosm::LifecycleFiber` mixin (opt-in)
3. Implement `TransitionBufferFiber` as alternative strategy

### Phase 2: Core Integration
4. Add fiber-aware guard runner with `Async::Barrier`
5. Implement `TransitionLock` for per-record serialization
6. Create `AgentBulkOperations` for AI agent efficiency

### Phase 3: Optimization
7. Add `fire_async!` method for fiber-native transitions
8. Implement `Async::Semaphore` for DB connection pool protection
9. Add telemetry: fiber context switching metrics

### Migration Path

```ruby
# Existing code continues to work
class Invoice < ApplicationRecord
  include Fosm::Lifecycle
end

# Opt-in to fibers
class Invoice < ApplicationRecord
  include Fosm::Lifecycle
  include Fosm::LifecycleFiber
end
```

---

## Concrete Gem Recommendations

| Gem | Purpose | FOSM Use Case |
|-----|---------|---------------|
| `async` | Core fiber scheduler | Replace Thread-based buffer |
| `async-http` | Non-blocking HTTP | Webhook delivery, guard I/O |
| `async-io` | Fiber-aware I/O | Side effect streaming |
| `falcon` | Fiber-based web server | Host FOSM apps with fiber-native requests |
| `async-postgres` (if available) | Fiber-aware DB driver | Lower-level DB yielding |

---

## Summary: 5 Integration Points

1. **Fiber-Isolated Transition Execution**: `fire_async!` runs transitions in fibers that yield during I/O, allowing thousands of concurrent transitions per thread.

2. **Concurrent Guard Evaluation**: `Async::Barrier` runs multiple guards in parallel fibers, reducing latency for I/O-heavy guard checks.

3. **Fiber-Based TransitionBuffer**: Timer-based fiber scheduler replaces Thread+sleep, with dynamic batch sizing and backpressure.

4. **Structured Concurrency for Agents**: `AgentBulkOperations` with `Async::Semaphore` and `Async::Barrier` enables AI agents to process hundreds of records concurrently with supervision.

5. **Race Condition Prevention**: `TransitionLock` provides per-record fiber-aware mutexes, preventing check-then-act races without database locks.

These patterns keep FOSM's core philosophy (single `fire!` path, immutable logs, bounded autonomy) while dramatically improving throughput and latency under concurrent load.
