# Hierarchical Statechart Patterns for FOSM: Research Synthesis

## Executive Summary

FOSM currently implements a **flat finite state machine** (XOR-state semantics) where exactly one state is active at any time. This research evaluates four hierarchical statechart patterns from XState, SCXML, and Yakindu to identify minimal viable additions that maximize developer power without complexity explosion.

**Recommendation**: Add **Compound States** (Pattern 1) and **History States** (Pattern 3) as the minimal viable set. Orthogonal regions (Pattern 2) provide significant value for parallel workflows but require deeper architectural changes. Entry/exit actions (Pattern 4) are syntactic sugar that can be deferred.

---

## Pattern 1: Compound States (Hierarchical/Nested States)

### Concept
A parent state containing multiple child states. When parent is active, exactly one child is active (XOR semantics preserved at each level). Child states inherit transitions defined at parent level.

**Without compound states**: A 3-step wizard with a "cancel" option from any step requires 3 separate cancel transitions.
**With compound states**: One cancel transition defined on parent applies to all children.

### Business Domain Mapping

| Domain | Parent State | Child States | Inherited Transition |
|--------|-------------|--------------|---------------------|
| **Contract Lifecycle** | `negotiation` | `drafting`, `review`, `redlining` | `abandon` → `cancelled` |
| **Candidate Screening** | `interviewing` | `phone_screen`, `technical`, `cultural` | `withdraw` → `withdrawn` |
| **Invoice Processing** | `disputed` | `under_review`, `awaiting_evidence`, `mediation` | `resolve` → `resolved` |
| **E-commerce Checkout** | `checkout` | `shipping`, `billing`, `review` | `cancel_order` → `cart` |

### API Sketch

```ruby
class Fosm::Contract < ApplicationRecord
  include Fosm::Lifecycle

  lifecycle do
    # Simple states (existing behavior preserved)
    state :draft, initial: true
    state :cancelled, terminal: true
    state :executed, terminal: true

    # Compound state with nested children
    compound :negotiation do
      # Default child when entering parent
      initial :drafting
      
      # Child states
      state :drafting
      state :review
      state :redlining

      # Parent-level transition inherited by all children
      event :abandon, to: :cancelled
      
      # Parent-level guard applies to all children
      guard :has_permission, on: :abandon do |contract|
        contract.user.can_cancel?
      end

      # Entry/exit actions at parent level
      on_entry do |contract|
        contract.started_negotiation_at = Time.current
      end
      
      on_exit do |contract|
        contract.negotiation_duration = Time.current - contract.started_negotiation_at
      end
    end

    # Transitions into compound state go to initial child
    event :start_negotiation, from: :draft, to: :negotiation
    
    # Transition from specific child (child-level overrides parent)
    event :submit_for_signature, from: :redlining, to: :awaiting_signature
    
    # Transition to parent transitions to initial child
    state :awaiting_signature
    event :sign, from: :awaiting_signature, to: :executed
  end
end
```

### Key Behaviors

1. **State Path**: Full state represented as path: `negotiation/drafting`, `negotiation/review`
2. **Predicate Methods**: `contract.negotiation?` (true for all children), `contract.drafting?` (specific)
3. **Transition Inheritance**: Parent-level `abandon` works from any child
4. **Guard Inheritance**: Parent guards apply to all child transitions unless explicitly overridden
5. **Terminal In Parent**: If parent is terminal, all children are effectively terminal

### Storage Considerations

```ruby
# Database column stores full path
contract.state # => "negotiation/drafting"

# Query helpers for finding all records in parent state
Fosm::Contract.in_compound_state(:negotiation)  # All children
Fosm::Contract.in_state(:negotiation, :review)   # Specific child
```

---

## Pattern 2: Orthogonal Regions (Parallel States)

### Concept
AND-state semantics: when parallel parent is active, ALL regions are simultaneously active. Each region has its own state machine. Regions coordinate via in-guards (checking other regions' states).

**Without parallel regions**: 5 independent approval tracks (2 states each) = 2^5 = 32 states.
**With parallel regions**: 5 regions × 2 states = 10 states + parallel container.

### Business Domain Mapping

| Domain | Parallel Container | Region 1 | Region 2 | Region 3 |
|--------|-------------------|----------|----------|----------|
| **Contract Approval** | `approval_process` | `legal_review` (pending/approved) | `pricing_review` (pending/approved) | `security_review` (pending/approved) |
| **Candidate Hiring** | `hiring_decision` | `hr_approval` (pending/approved) | `technical_approval` (pending/approved) | `budget_approval` (pending/approved) |
| **Invoice Processing** | `payment_clearance` | `fraud_check` (pending/cleared) | `spend_limit_check` (pending/approved) | `duplicate_check` (pending/cleared) |
| **Product Launch** | `launch_readiness` | `legal_clearance` (pending/ready) | `marketing_ready` (pending/ready) | `engineering_ready` (pending/ready) |

### API Sketch

```ruby
class Fosm::Contract < ApplicationRecord
  include Fosm::Lifecycle

  lifecycle do
    state :draft, initial: true
    state :cancelled, terminal: true
    
    # Parallel container - all regions active simultaneously
    parallel :approval_process do
      region :legal do
        state :pending_review, initial: true
        state :approved
        state :rejected
        
        event :legal_approve, from: :pending_review, to: :approved
        event :legal_reject, from: :pending_review, to: :rejected
      end
      
      region :pricing do
        state :pending_review, initial: true
        state :approved
        state :rejected
        
        event :pricing_approve, from: :pending_review, to: :approved
        event :pricing_reject, from: :pending_review, to: :rejected
      end
      
      region :security do
        state :pending_review, initial: true
        state :approved
        state :rejected
        
        event :security_approve, from: :pending_review, to: :approved
        event :security_reject, from: :pending_review, to: :rejected
      end
      
      # Global transition when ANY region rejects
      event :abort, to: :cancelled do
        guard :any_region_rejected do |contract|
          contract.parallel_state[:legal] == :rejected ||
          contract.parallel_state[:pricing] == :rejected ||
          contract.parallel_state[:security] == :rejected
        end
      end
    end
    
    # Transition out when ALL regions complete
    state :awaiting_signature
    event :submit_for_signature, from: :approval_process, to: :awaiting_signature do
      guard :all_regions_approved do |contract|
        contract.parallel_state[:legal] == :approved &&
        contract.parallel_state[:pricing] == :approved &&
        contract.parallel_state[:security] == :approved
      end
    end
  end
end
```

### Key Behaviors

1. **Region Isolation**: Each region has independent states and transitions
2. **Automatic Join**: Parallel container can emit `done.state.id` when all regions reach terminal states
3. **In-Guards**: Guards can query other regions' states for coordination
4. **Event Broadcasting**: Events sent to parallel container are dispatched to all regions
5. **Partial Completion**: Some regions can complete while others continue

### Storage Considerations

```ruby
# JSON column for parallel state tracking
# fosm_parallel_states:jsonb

contract.parallel_state # => 
# {
#   "approval_process" => {
#     "legal" => "approved",
#     "pricing" => "pending_review",
#     "security" => "approved"
#   }
# }
```

---

## Pattern 3: History States (Resumption)

### Concept
A pseudostate that remembers the last active substate when exiting a compound state. Enables workflow suspension and resumption without losing position.

**Shallow History ($H$)**: Remember only the immediate child state. Nested substates reset to their initial.
**Deep History ($H^*$)**: Remember the full nested configuration, however deep.

### Business Domain Mapping

| Domain | Compound State | Use Case | History Type |
|--------|---------------|----------|--------------|
| **Multi-step Form** | `onboarding` | User returns after logout | Deep - remember exact form page |
| **Document Workflow** | `review_cycle` | Review paused for clarification | Shallow - restart current phase fresh |
| **Interview Process** | `interviewing` | Candidate reschedules | Deep - remember which round they were in |
| **Approval Process** | `approval_process` | Process suspended for audit | Shallow - restart current approval step |
| **Draft Document** | `editing` | Auto-save and resume | Deep - remember exact editing position |

### API Sketch

```ruby
class Fosm::Candidate < ApplicationRecord
  include Fosm::Lifecycle

  lifecycle do
    state :applied, initial: true
    state :withdrawn, terminal: true
    state :hired, terminal: true
    state :rejected, terminal: true

    # Compound with shallow history
    compound :interviewing do
      initial :phone_screen
      
      state :phone_screen
      state :technical
      state :cultural
      state :final_round
      
      # Shallow history - remembers immediate child only
      # When returning via :back_to_interviewing, resumes at last active round
      # But nested states within that round reset to initial
      history :shallow, default: :phone_screen
      
      event :pass_round, transitions: {
        :phone_screen => :technical,
        :technical => :cultural,
        :cultural => :final_round
      }
      
      event :fail_round, to: :rejected
      
      # Exit compound - can resume via history
      event :suspend, to: :on_hold
    end
    
    state :on_hold
    
    # Resume using shallow history - goes to last round, fresh start in that round
    event :resume, from: :on_hold, to: :interviewing, via: :shallow_history
    
    # Or force restart from specific round
    event :restart_at_technical, from: :on_hold, to: :interviewing, via: :technical
    
    # Deep history example for complex nested workflow
    compound :onboarding do
      initial :paperwork
      
      state :paperwork do
        state :tax_forms, initial: true
        state :benefits_selection
        state :emergency_contacts
      end
      
      state :training do
        state :security_training, initial: true
        state :role_specific_training
        state :company_orientation
      end
      
      # Deep history - remembers exact substate including nested
      history :deep, default: :paperwork
      
      event :suspend_onboarding, to: :onboarding_paused
    end
    
    state :onboarding_paused
    # Resume exactly where they left off, even nested substates
    event :resume_onboarding, from: :onboarding_paused, to: :onboarding, via: :deep_history
  end
end
```

### Key Behaviors

1. **History as Target**: Transitions can target `via: :shallow_history` or `via: :deep_history`
2. **Default Fallback**: First-time entry uses default state when no history exists
3. **History Scope**: Shallow = immediate parent only, Deep = full nested path
4. **History Reset**: Explicit `reset_history!` method for administrative operations
5. **Audit Trail**: History restoration logged as special transition event

### Storage Considerations

```ruby
# Separate history tracking table
# fosm_state_histories: record_type, record_id, compound_state, 
#                      shallow_state, deep_path, exited_at

# Or inline in JSONB column alongside state
contract.history_state # =>
# {
#   "interviewing" => {
#     "shallow" => "technical",
#     "deep" => "interviewing/technical/screen_1",
#     "exited_at" => "2026-03-20T10:30:00Z"
#   }
# }
```

---

## Pattern 4: Entry/Exit Actions (Parent-Level Side Effects)

### Concept
Actions that fire when entering or exiting a state, regardless of which transition was taken. In hierarchy: entry runs top-down (parent first), exit runs bottom-up (child first).

### Business Domain Mapping

| Domain | State | Entry Action | Exit Action |
|--------|-------|-------------|-------------|
| **Invoice** | `overdue` | Start interest accrual, notify collections | Stop interest accrual |
| **Contract** | `negotiation` | Start negotiation timer | Calculate duration, archive thread |
| **Candidate** | `interviewing` | Block calendar, notify interviewers | Release calendar, send feedback form |
| **Support Ticket** | `escalated` | Notify manager, start SLA timer | Close escalation record |

### API Sketch

```ruby
class Fosm::Invoice < ApplicationRecord
  include Fosm::Lifecycle

  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    compound :overdue do
      initial :grace_period
      
      state :grace_period
      state :collections
      state :legal_review
      
      # Fires when entering ANY child of overdue
      on_entry do |invoice, transition|
        invoice.overdue_since = Time.current
        invoice.start_interest_accrual!
        CollectionsMailer.notify(invoice).deliver_later
      end
      
      # Fires when exiting ANY child of overdue
      on_exit do |invoice, transition|
        invoice.total_interest = invoice.calculate_interest
        invoice.stop_interest_accrual!
      end
      
      # Child can have its own entry/exit
      state :legal_review do
        on_entry do |invoice|
          invoice.create_legal_case_number!
        end
        
        on_exit do |invoice|
          invoice.archive_legal_files!
        end
      end
      
      event :escalate_to_collections, from: :grace_period, to: :collections
      event :escalate_to_legal, from: :collections, to: :legal_review
      event :mark_paid, from: [:grace_period, :collections, :legal_review], to: :paid
    end
    
    event :mark_overdue, from: :sent, to: :overdue
  end
end
```

### Key Behaviors

1. **Execution Order**: Entry = parent → child (top-down), Exit = child → parent (bottom-up)
2. **Transition Context**: Both entry and exit receive transition data (from, to, event, actor)
3. **Transaction Safety**: Entry/exit run inside the same transaction as state update
4. **Idempotency**: Actions should be idempotent (may run multiple times on retries)

### Relationship to Existing Side Effects

```ruby
# Current FOSM: side_effect on event
event :mark_overdue, from: :sent, to: :overdue
side_effect :start_accrual, on: :mark_overdue do |inv|
  inv.start_interest_accrual!
end

# With entry actions: side_effect on state entry
# This fires regardless of WHICH transition entered the state
category :overdue do
  on_entry do |inv, transition|
    inv.start_interest_accrual!
  end
end
```

---

## Implementation Complexity Assessment

| Pattern | DSL Changes | Storage Changes | Runtime Changes | Priority |
|---------|------------|-----------------|-----------------|----------|
| **1. Compound States** | Moderate - nested blocks | Minimal - path strings | Moderate - hierarchical lookup | **P1 - Essential** |
| **2. Orthogonal Regions** | Significant - parallel semantics | Significant - JSONB for regions | Major - event broadcasting | P2 - High Value |
| **3. History States** | Moderate - history declaration | Moderate - history table | Moderate - resume logic | **P1 - Essential** |
| **4. Entry/Exit Actions** | Minor - on_entry/on_exit blocks | None | Minor - action ordering | P3 - Sugar |

---

## Recommended Minimal Viable Addition

Based on the AGENTS.md principle of "deliberately simple" and the goal of maximizing developer power without complexity explosion:

### Phase 1: Compound States + Shallow History

```ruby
lifecycle do
  state :draft, initial: true
  
  compound :review do
    initial :pending
    history shallow: :pending  # Shallow history with default
    
    state :pending
    state :in_progress
    state :approved
    
    # Parent-level transition inherited
    event :cancel, to: :draft
    
    on_entry do |record|
      record.review_started_at = Time.current
    end
  end
  
  event :submit, from: :draft, to: :review
  event :return_to_review, from: :rejected, to: :review, via: :history
end
```

This gives FOSM:
1. **State explosion prevention** via transition inheritance
2. **Workflow resumption** via shallow history
3. **Syntactic clarity** via nested state declaration
4. **Backward compatibility** - existing flat lifecycles work unchanged

### Deferred for Phase 2
- Deep history (complexity vs utility tradeoff)
- Orthogonal regions (architectural significance)
- Entry/exit actions (can use existing event side_effects)

---

## References

1. [Stately.ai: Parent States](https://stately.ai/docs/parent-states)
2. [Statecharts.dev: Parallel States](https://statecharts.dev/glossary/parallel-state.html)
3. [Statecharts.dev: History States](https://statecharts.dev/glossary/history-state.html)
4. [SCXML Specification](https://www.w3.org/TR/scxml/)
5. [Yakindu/itemis CREATE History Nodes](https://www.itemis.com/en/products/itemis-create/documentation/user-guide/quick_ref_history_nodes)
6. [XState Parallel States](https://xstate.js.org/docs/guides/parallel.html)
