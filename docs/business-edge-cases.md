# Business Domain Edge Cases Research for FOSM

**Research Date:** 2026-03-20  
**Researcher:** Business Domain Edge Case Researcher (VividRaven)  
**Context:** ERP and document workflow systems complexity analysis  
**Target:** 6-8 edge cases with severity assessment and integration recommendations

---

## Executive Summary

This research identifies eight high-impact business domain edge cases that emerge in real-world ERP and document workflow implementations. Each case is assessed for **severity** (how commonly it blocks production deployments), **current FOSM capability alignment**, and **integration complexity**. Classification: **Core FOSM** (belongs in engine), **Extension Module** (separate gem), or **Out of Scope** (intentionally excluded per FOSM philosophy).

---

## 1. Temporal Transitions (Time-Based Constraints)

### The Edge Case
Business transitions that are only valid during specific time windows:
- **Business Hours Only:** Invoice can only be marked paid during 9-5 (for wire transfer confirmation)
- **Cutoff Times:** Payroll changes locked after 3pm for same-day processing
- **Schedule-Ahead:** Contract effective date transitions that fire automatically on a future date
- **SLA Timeouts:** Auto-escalate support tickets if not responded to within 4 hours

### Real-World Example
```ruby
# SAP/Workday pattern: Time-dependent workflow gates
class Invoice < ApplicationRecord
  # Business rule: Can only transition to :processing during business hours
  # Otherwise queues for next business day start
  
  # Time-based auto-transition: If in :pending_review for > 5 days, auto-escalate
  # This is NOT a simple guard — it's a scheduled state change
end
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **High** | Every financial system has cutoff times |
| Workaround Complexity | **Medium** | Cron jobs outside FOSM, but lose audit trail coherence |
| Customer Pain | **High** | "Why can't I mark this paid? It's 6pm on Friday!" |
| **Overall Severity** | **8/10** | Common blocker for financial services deployments |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| Guard system | ✅ Yes | Can validate time windows |
| Side effects | ✅ Yes | Can schedule external jobs |
| Auto-transition | ❌ No | No cron/scheduled event firing |
| Temporal state queries | ❌ No | No "records in state X for Y duration" API |

### Classification: **EXTENSION MODULE** (`fosm-temporal`)

**Rationale:** Temporal logic introduces significant complexity (timezone handling, cron infrastructure, clock skew). Keep FOSM core synchronous and deterministic.

**Integration Recommendation:**
```ruby
# Proposed fosm-temporal extension DSL
lifecycle do
  state :draft, initial: true
  state :pending_review
  state :escalated
  
  event :submit, from: :draft, to: :pending_review
  
  # Extension syntax: temporal transition
  temporal :escalate_if_stale, 
           from: :pending_review, 
           to: :escalated,
           after: 5.days,
           business_hours: true  # or :calendar_days
end
```

**Implementation Notes:**
- Uses SolidQueue/Sidekiq cron for scheduled job
- Adds `fosm_temporal_schedules` table for pending auto-transitions
- Cancel schedule if manual transition fires first (race condition handling)
- Audit trail shows actor as `:system` with `triggered_by: :schedule`

---

## 2. Bulk Operations with Partial Failure

### The Edge Case
Operations across collections where some records succeed and others fail:
- **Batch Invoice Sending:** 100 invoices, 3 fail validation (missing addresses)
- **Mass Status Updates:** 50 candidates to "rejected", 5 already in "hired" (terminal)
- **Bulk Import:** CSV of 1000 records, 50 invalid — need to identify failures without rollback all

### Real-World Example
```ruby
# Salesforce/HubSpot pattern: Bulk action with error collection
class RecruitingController < ApplicationController
  def bulk_reject
    candidate_ids = params[:ids]
    
    # Naive approach: all-or-nothing transaction
    # Fails entire batch if one candidate is already hired
    
    # Required approach: partial success with detailed error reporting
    # - 42 successfully rejected
    # - 3 failed: already in terminal state "hired"
    # - 2 failed: guard "has_active_offer?" returned false
    # - 1 failed: access denied (not their assigned recruiter)
  end
end
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **Very High** | Every admin UI needs bulk actions |
| Workaround Complexity | **High** | Must loop + rescue in application code |
| Customer Pain | **High** | "Why did my entire bulk action fail for one bad record?" |
| **Overall Severity** | **9/10** | Blocking for any production admin interface |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| Single-record fire! | ✅ Yes | Atomic per-record |
| Bulk fire API | ❌ No | No `fire_all!` method |
| Partial failure reporting | ❌ No | Exceptions halt execution |
| Result aggregation | ❌ No | No structured bulk result type |

### Classification: **CORE FOSM** (enhancement)

**Rationale:** Bulk operations are fundamental to admin UX. The current workaround (loop + rescue) breaks audit trail coherence and loses transaction atomicity guarantees.

**Integration Recommendation:**
```ruby
# Add to Fosm::Lifecycle module

# New API method: fire_bulk!
results = Fosm::Invoice.fire_bulk!(
  :send_invoice,
  ids: [1, 2, 3, 4, 5],
  actor: current_user,
  strategy: :partial_success  # or :all_or_nothing
)

# Returns structured result
{
  total: 5,
  succeeded: 3,
  failed: 2,
  results: [
    { id: 1, success: true, from: "draft", to: "sent" },
    { id: 2, success: false, error: "GuardFailed: has_line_items" },
    { id: 3, success: true, from: "draft", to: "sent" },
    { id: 4, success: false, error: "AccessDenied" },
    { id: 5, success: true, from: "draft", to: "sent" }
  ]
}

# Implementation notes:
# - Each record in its own transaction (isolated failure)
# - Aggregate transition logs in single bulk INSERT (performance)
# - Webhook delivery still per-record (webhook payload includes bulk_batch_id)
```

**Alternative: Scoped Bulk Operations**
```ruby
# For "all records matching criteria"
Fosm::Invoice.where(state: "draft").fire_bulk!(:send_invoice, actor: current_user)
```

**Agent Integration:**
```ruby
# Auto-generated tool for agents
# send_invoices_bulk(ids:, continue_on_error: true)
# Returns structured result that agent can iterate and report
```

---

## 3. Multi-User Collaboration Patterns (Optimistic Locking)

### The Edge Case
Multiple users editing the same record simultaneously:
- **Concurrent Editing:** User A and User B both viewing "draft" invoice. User A sends it. User B tries to add line item — should fail with clear message.
- **Stale State in UI:** Event buttons shown based on `available_events` fetched 30 seconds ago. Record state changed since — action should fail gracefully.
- **Race Condition on Fire:** Two users click "Approve" simultaneously on same expense report.

### Real-World Example
```ruby
# Linear/Jira pattern: Optimistic locking with state as version proxy
class ExpenseReport < ApplicationRecord
  # User A loads report (state: pending_approval)
  # User B loads report (state: pending_approval)
  # User B approves first → state: approved
  # User A tries to approve → should get "State has changed, please refresh"
  # NOT a generic 500 error or silent failure
end
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **High** | Any system with multiple users per record |
| Workaround Complexity | **Low-Medium** | Rails `lock_version` exists, but not integrated with FOSM |
| Customer Pain | **Medium** | "Someone else already did this" vs cryptic error |
| **Overall Severity** | **6/10** | Important but has existing Rails patterns |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| State check at fire! | ✅ Partial | Validates current state, but no "expected state" param |
| Optimistic locking | ❌ No | No integration with ActiveRecord locking |
| Stale state detection | ❌ No | `available_events` is point-in-time |
| Collision error type | ❌ No | No specific `StaleState` exception |

### Classification: **CORE FOSM** (enhancement)

**Rationale:** Collaboration is fundamental to business apps. Integration with Rails' built-in optimistic locking is straightforward and expected.

**Integration Recommendation:**
```ruby
# Add optional state_version parameter to fire!
# Uses ActiveRecord optimistic locking pattern

class Fosm::Invoice < ApplicationRecord
  # FOSM auto-manages lock_version when state changes
  # Or: uses state itself as version proxy
end

# API: Client includes state they expect
invoice.fire!(:approve, actor: user, expected_state: "pending_approval")

# If current state != expected_state:
# raise Fosm::StaleStateError, 
#       "Expected 'pending_approval' but current state is 'approved'"

# Admin UI: Pass expected_state from hidden field populated on load
# Agent: Always calls get_* before fire to verify state
```

**Agent Integration:**
The existing `get_*` then fire pattern already mitigates this for agents. Can be strengthened by adding `expected_state` assertion in system prompt.

---

## 4. Undo / Compensation Workflows

### The Edge Case
Business processes that need reversal after completion:
- **Invoice Refund:** Paid invoice needs to be "reopened" for correction, then repaid
- **Contract Cancellation After Sign:** Signed contract needs emergency termination (not same as never-signed)
- **Reversal vs Correction:** Fix a typo (new transition) vs undo mistaken approval (rollback with audit trail)

### Critical Distinction
FOSM's `terminal: true` is **architectural** — it means "no further transitions in the normal lifecycle." But business reality has exceptions:
- "This should never happen" → until it does (regulatory change, error correction)
- Terminal is about **preventing accidents**, not **denying legitimate business needs**

### Real-World Example
```ruby
# NetSuite/SAP pattern: Compensating transactions
class Invoice < ApplicationRecord
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    state :refunded  # Terminal states can have exits, but they're "exceptional"
    state :voided    # Another terminal with exceptional exit
    
    event :send_invoice, from: :draft, to: :sent
    event :pay, from: :sent, to: :paid
    
    # Compensating event: NOT "un-pay", it's "refund" — different semantics
    event :refund, from: :paid, to: :refunded
    # ^ This currently raises TerminalState in FOSM
    
    # Void: administrative cancellation after payment
    event :void, from: :paid, to: :voided
    # ^ Also requires terminal exit
  end
end
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **High** | Refunds, returns, cancellations are business-as-usual |
| Workaround Complexity | **High** | Must model "paid" as non-terminal, losing safety |
| Customer Pain | **Very High** | "Your system won't let me process this refund" |
| **Overall Severity** | **9/10** | Critical blocker for e-commerce, financial services |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| Terminal state | ✅ Yes | Hard block on all transitions |
| Compensating events | ❌ No | No "exceptional exit" concept |
| Audit trail reason | ❌ Partial | Metadata exists, no "reason code" structure |

### Classification: **CORE FOSM** (philosophy clarification + enhancement)

**Rationale:** This is a **design philosophy** issue, not just implementation. The FOSM documentation states terminal states are "irreversible by design" and suggests "compensating events." But the implementation doesn't support compensating events FROM terminal states.

**Recommended Philosophy Change:**

```ruby
# Two types of terminal:
1. HARD terminal (default): No transitions out. For truly final states.
2. SOFT terminal (new): No NORMAL transitions out, but compensating events allowed.

# DSL change:
lifecycle do
  state :paid, terminal: true                    # Hard terminal (default behavior)
  state :paid, terminal: :soft                   # Soft terminal — compensating events allowed
  state :paid, terminal: true, compensable: true # Alternative syntax
end
```

**Integration Recommendation:**
```ruby
# Add compensating event DSL
lifecycle do
  state :draft, initial: true
  state :sent
  state :paid, terminal: :soft  # Soft terminal
  state :refunded, terminal: true
  
  event :pay, from: :sent, to: :paid
  
  # Compensating events explicitly declared
  compensating_event :refund, from: :paid, to: :refunded
  # ^ Bypasses terminal check, logged with compensating: true flag
  
  # Or: allow any event with compensating: true flag
  event :refund, from: :paid, to: :refunded, compensating: true
end

# Audit trail enhancement:
# fosm_transition_logs.compensating boolean
# UI badge: "Compensating transition" on history view
```

---

## 5. Cross-Object Lifecycle Triggers

### The Edge Case
State change in one object triggers state change in another:
- **Invoice Paid → Contract Activated:** When invoice fully paid, associated contract auto-transitions to "active"
- **Candidate Hired → Onboarding Started:** Candidate state change triggers new Onboarding record in "pending" state
- **PO Approved → Inventory Reserved:** Purchase order approval triggers inventory allocation

### Real-World Example
```ruby
# Salesforce Flow / SAP Workflow pattern: Cross-object automation
class Contract < ApplicationRecord
  lifecycle do
    state :draft, initial: true
    state :awaiting_payment
    state :active
    state :expired
    
    event :send_for_payment, from: :draft, to: :awaiting_payment
    event :activate, from: :awaiting_payment, to: :active
  end
end

class Invoice < ApplicationRecord
  belongs_to :contract
  
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    event :send_invoice, from: :draft, to: :sent
    event :pay, from: :sent, to: :paid
  end
  
  # Requirement: When this invoice is paid, auto-activate its contract
  # Current workaround: side_effect that calls contract.activate!(actor: :system)
  # Problem: side_effects run inside transaction — what if contract activation fails?
  # Should invoice payment roll back? Or succeed with failed cross-object trigger?
end
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **Very High** | ERP systems are webs of interconnected workflows |
| Workaround Complexity | **Medium** | Side effects work, but transaction boundaries are tricky |
| Customer Pain | **High** | "I paid the invoice, why isn't my contract active?" |
| **Overall Severity** | **8/10** | Core requirement for business process automation |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| Side effects | ✅ Yes | Can trigger other actions |
| Transaction boundary control | ❌ No | Side effects run in same transaction |
| Cross-object event firing | ❌ Partial | Must manually code in side_effect |
| Saga/compensating transaction | ❌ No | No multi-object transaction pattern |

### Classification: **CORE FOSM** (enhancement)

**Rationale:** Cross-object workflows are fundamental to business automation. Current side_effect approach works but lacks structure for error handling and observability.

**Integration Recommendation:**
```ruby
# Enhanced side_effect DSL with cross-object semantics

lifecycle do
  event :pay, from: :sent, to: :paid do
    side_effect :notify_client
    
    # New: cross_object trigger with explicit error handling
    cross_object :activate_contract,
                 target: ->(invoice) { invoice.contract },
                 event: :activate,
                 actor: :system,
                 on_failure: :log_warning  # or :rollback, :ignore, :retry
  end
end

# Alternative: Declarative trigger syntax
lifecycle do
  # Declare that this model receives triggers from other models
  trigger_on :contract, 
             event: :activated,
             fire: :mark_ready,
             condition: ->(contract) { contract.fully_paid? }
end

# Audit trail enhancement:
# - Cross-object transitions logged with triggered_by: { type:, id:, event: }
# - UI shows causal chain: Invoice#123 paid → triggered Contract#456 activate
```

**Saga Pattern Consideration (Future):**
For complex multi-object workflows, consider `fosm-sagas` extension:
```ruby
# Future extension for distributed transactions
saga :contract_activation_flow do
  step :pay_invoice, model: Invoice, event: :pay
  step :activate_contract, model: Contract, event: :activate, depends_on: :pay_invoice
  step :notify_stakeholders, model: Notification, event: :send, depends_on: :activate_contract
  
  compensation :reverse_contract_activation, on_failure: :activate_contract
end
```

---

## 6. Delegation Patterns (Proxy / Act-On-Behalf)

### The Edge Case
One user performs actions on behalf of another:
- **Manager Approves for Team Member:** Manager submits expense report on behalf of direct report
- **Executive Assistant:** EA manages calendar/scheduling on behalf of executive
- **Proxy Voting:** Board member delegates vote to alternate
- **System-to-System Delegation:** Service account acts on behalf of specific user (API integrations)

### Critical Distinction from RBAC
Current FOSM RBAC answers: "Does this user have a role on this record?"

Delegation answers: "This user is acting as that user — permissions are evaluated as if the delegate were the principal."

### Real-World Example
```ruby
# Google Workspace / Salesforce Delegated Admin pattern
class ExpenseReport < ApplicationRecord
  lifecycle do
    access do
      role :owner, default: true do
        can :create, :read, :update
        can :event, :submit
      end
      
      role :manager do
        can :event, :approve
        can :event, :reject
      end
    end
  end
end

# Scenario: Direct report is sick, manager needs to submit their expense report
# Current RBAC: Manager has :manager role, but that only allows approve/reject
# Delegation needed: Manager acts as direct report, gains :owner capabilities
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **Medium** | Common in executive/manager workflows, less so in peer systems |
| Workaround Complexity | **High** | Requires temporary role assignment + audit complexity |
| Customer Pain | **Medium-High** | "I need to do this for my team member who is OOO" |
| **Overall Severity** | **6/10** | Important for enterprise, less critical for SMB |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| RBAC with roles | ✅ Yes | Fixed role assignments |
| Dynamic delegation | ❌ No | No "act as" capability |
| Audit trail attribution | ❌ Partial | Single actor field, no delegation chain |

### Classification: **EXTENSION MODULE** (`fosm-delegation`)

**Rationale:** Delegation is complex (chain of custody, revocation, time-bounds). Not all FOSM users need it. Keep core simple.

**Integration Recommendation:**
```ruby
# Proposed fosm-delegation extension

# New DSL in access block
access do
  # ... existing roles ...
  
  # Delegation rules
  allow_delegation from: :manager, to: :direct_report, for_events: [:submit]
  allow_delegation from: :executive_assistant, to: :executive, for_crud: [:create, :update]
end

# Runtime API
delegate = User.find(manager_id)
principal = User.find(direct_report_id)

report.fire!(:submit, 
             actor: delegate,  # Who physically performed the action
             acting_as: principal)  # Whose permissions to use

# Audit trail enhancement:
# fosm_transition_logs.actor_type/id = delegate
# fosm_transition_logs.acting_as_type/id = principal
# fosm_transition_logs.delegation_chain JSON for multi-hop

# UI indication: "Submitted by Jane Doe on behalf of John Smith"
```

**Agent Integration:**
```ruby
# Agents can be configured with delegation context
class Fosm::ExpenseReportAgent < Fosm::Agent
  model_class Fosm::ExpenseReport
  default_delegation :manager  # Agent calls include acting_as context
end
```

---

## 7. Hierarchical / Sub-State Machines

### The Edge Case
Complex states that decompose into substates:
- **Review State:** Generic "under review" with substates: initial_screening → technical_review → final_approval
- **Shipping State:** "In transit" with substates: picked → packed → handed_to_carrier → customs → out_for_delivery
- **Multi-Party Approval:** "Pending approval" with parallel sub-states for each approver

### FOSM Philosophy Tension
This is intentionally excluded per AGENTS.md: "resist adding complexity (priorities, concurrent states, history states). FOSM is deliberately simple. If you need those features, look at XState or Statecharts."

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **Medium** | Common in complex workflows, but often modeled differently |
| Workaround Complexity | **Medium** | Can use multiple FOSM models (Review as separate object) |
| Customer Pain | **Low** | "Why can't I see which review stage?" vs system doesn't work |
| **Overall Severity** | **4/10** | Workaround exists, design philosophy clear |

### Classification: **OUT OF SCOPE** (intentional)

**Rationale:** FOSM's value proposition is "deliberately simple." Hierarchical states add significant complexity (statecharts semantics, history states, parallel regions). Users who need this should use XState or model sub-workflows as separate FOSM objects.

**Recommended Workaround:**
```ruby
# Instead of hierarchical states, use associated workflow objects

class JobApplication < ApplicationRecord
  lifecycle do
    state :applied, initial: true
    state :under_review
    state :rejected, terminal: true
    state :hired, terminal: true
    
    event :start_review, from: :applied, to: :under_review
    event :complete_hire, from: :under_review, to: :hired
    event :reject, from: [:applied, :under_review], to: :rejected
  end
  
  has_one :review_process  # Separate FOSM object for review details
end

class ReviewProcess < ApplicationRecord
  belongs_to :job_application
  
  lifecycle do
    state :screening, initial: true
    state :technical_interview
    state :final_decision
    state :completed, terminal: true
    
    event :schedule_technical, from: :screening, to: :technical_interview
    event :make_decision, from: :technical_interview, to: :final_decision
    event :finish, from: :final_decision, to: :completed
  end
end

# Cross-object trigger (see Case 5) connects them
```

---

## 8. Conditional / Dynamic Workflow Routing

### The Edge Case
Transitions that depend on runtime data beyond simple guards:
- **Approval Routing:** Expense > $10k requires manager approval; > $50k requires director
- **Conditional States:** Contract goes to "legal_review" only if terms include liability clause
- **Dynamic Event Availability:** "Expedite" event only available if customer tier = "enterprise"

### Critical Distinction from Guards
- **Guards:** Binary yes/no — "can this transition happen?"
- **Dynamic Routing:** Which transition (or target state) should be chosen based on data

### Real-World Example
```ruby
# ServiceNow / Camunda pattern: Dynamic workflow based on data
class ExpenseReport < ApplicationRecord
  lifecycle do
    state :draft, initial: true
    state :pending_manager_approval
    state :pending_director_approval
    state :approved
    state :rejected
    
    event :submit, from: :draft do
      # Dynamic routing: Where should this go?
      if amount > 50_000
        to: :pending_director_approval
      elsif amount > 10_000
        to: :pending_manager_approval
      else
        to: :approved  # Auto-approve small amounts
      end
    end
    
    event :manager_approve, from: :pending_manager_approval, to: :approved
    event :director_approve, from: :pending_director_approval, to: :approved
  end
end
```

### Severity Assessment
| Metric | Score | Notes |
|--------|-------|-------|
| Frequency | **High** | Most approval workflows have thresholds |
| Workaround Complexity | **Low** | Can model as separate events with guards |
| Customer Pain | **Low-Medium** | Verbose DSL, but works |
| **Overall Severity** | **5/10** | Nice-to-have syntactic sugar |

### FOSM Capability Mapping

| Feature | Exists? | Fit |
|---------|---------|-----|
| Guards | ✅ Yes | Can route via separate events with guards |
| Dynamic target state | ❌ No | `to:` is static in current DSL |
| Conditional events | ✅ Partial | Multiple events with guard conditions |

### Classification: **CORE FOSM** (enhancement - syntax sugar)

**Rationale:** Can be achieved with current guards + multiple events, but verbose. Worthwhile DSL improvement for readability.

**Integration Recommendation:**
```ruby
# Current workaround (works, but verbose)
event :submit_small, from: :draft, to: :approved do
  guard :amount_under_10k
end
event :submit_medium, from: :draft, to: :pending_manager_approval do
  guard :amount_10k_to_50k
end
event :submit_large, from: :draft, to: :pending_director_approval do
  guard :amount_over_50k
end

# Proposed enhancement: Conditional to
event :submit, from: :draft do
  to :approved, if: ->(r) { r.amount < 10_000 }
  to :pending_manager_approval, if: ->(r) { r.amount < 50_000 }
  to :pending_director_approval  # default
end

# Or: Guard-based routing
event :submit, from: :draft, to: :approved,                     guard: :amount_under_10k
event :submit, from: :draft, to: :pending_manager_approval,  guard: :amount_10k_to_50k
event :submit, from: :draft, to: :pending_director_approval,   guard: :amount_over_50k
# ^ Multiple events with same name, different guards — first matching wins
```

---

## Summary Matrix

| Edge Case | Severity | Classification | Effort | Priority |
|-----------|----------|----------------|--------|----------|
| 1. Temporal Transitions | 8/10 | Extension (`fosm-temporal`) | Medium | High |
| 2. Bulk Operations | 9/10 | Core Enhancement | Medium | **Critical** |
| 3. Collaboration/Optimistic Locking | 6/10 | Core Enhancement | Low | Medium |
| 4. Undo/Compensation | 9/10 | Core Enhancement | Medium | **Critical** |
| 5. Cross-Object Triggers | 8/10 | Core Enhancement | Medium | High |
| 6. Delegation | 6/10 | Extension (`fosm-delegation`) | High | Medium |
| 7. Hierarchical States | 4/10 | Out of Scope | N/A | N/A |
| 8. Conditional Routing | 5/10 | Core Enhancement | Low | Low |

### Recommended Implementation Order

1. **Critical Priority:** Bulk Operations (#2), Undo/Compensation (#4)
   - These block production deployments in common scenarios
   - No viable workaround without losing FOSM benefits

2. **High Priority:** Cross-Object Triggers (#5), Temporal Transitions (#1)
   - Important for business automation
   - Workarounds exist but are fragile

3. **Medium Priority:** Collaboration Patterns (#3), Delegation (#6)
   - Quality-of-life improvements
   - Enterprise feature set

4. **Low Priority:** Conditional Routing (#8)
   - Syntactic sugar only
   - Current workarounds are acceptable

5. **Intentionally Excluded:** Hierarchical States (#7)
   - Aligns with FOSM philosophy
   - Clear workaround documented

---

## Appendix: Existing FOSM Capabilities Reference

For each edge case analysis, the following FOSM capabilities were evaluated:

### Core Lifecycle
- `state`, `event`, `guard`, `side_effect` DSL
- `initial: true`, `terminal: true` state modifiers
- `fire!` as sole mutation path
- `can_fire?`, `available_events` introspection
- Auto-generated predicate methods (`draft?`, `sent?`)
- Auto-generated bang methods (`send_invoice!`, `pay!`)

### RBAC (Access Control)
- `access` block with `role` declarations
- `default: true` role auto-assignment on create
- CRUD permissions (`can :create, :read, :update, :delete`)
- Event permissions (`can :event, :event_name`)
- Per-request role cache via `Fosm::Current`
- Superadmin bypass (`actor.superadmin?`)
- Symbol actor bypass (`:system`, `:agent`)

### Audit Trail
- `Fosm::TransitionLog` immutable records
- Sync, async, and buffered strategies
- Actor attribution (type, id, label)
- Metadata storage

### AI Agent Integration
- `Fosm::Agent` base class
- Auto-generated Gemlings tools per lifecycle
- System prompt with FOSM constraints
- Bounded autonomy guarantee (agent cannot bypass machine)

### Webhooks
- `Fosm::WebhookSubscription` admin-configured
- `WebhookDeliveryJob` async with HMAC signing

---

*End of Research Report*
