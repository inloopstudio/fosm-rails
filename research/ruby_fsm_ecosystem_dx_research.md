# Ruby State Machine Ecosystem DX Research
## Survey of aasm, state_machines, workflow, transitions, stateful_enum, statesman
### Research Date: 2026-03-20 | Researcher: EpicLion (Ruby FSM DX Researcher)

---

## Executive Summary

This research surveyed the Ruby state machine gem ecosystem to identify developer experience gaps and community pain points. The goal: extract patterns FOSM should adopt and anti-patterns to avoid.

**Key Insight:** The most common developer pain point across ALL gems is **error message clarity**—developers consistently struggle to answer "why did this transition fail?" When a guard returns false, most gems either raise generic exceptions or silently return false without explaining which guard failed or why.

---

## Gem-by-Gem Analysis

### 1. AASM (Acts As State Machine) - The Market Leader

**GitHub:** https://github.com/aasm/aasm  
**Stars:** ~5k+  
**Maintenance:** Active (best in class)

#### What Developers LOVE
- ✅ **Excellent RSpec integration** - `require 'aasm/rspec'` provides fluent matchers:
  ```ruby
  expect(order).to transition_from(:pending).to(:paid).on_event(:pay)
  expect(order).to have_state(:pending)
  ```
- ✅ **Clear DSL** - readable `event :pay do transitions from: :pending, to: :paid end`
- ✅ **Active maintenance** - frequent updates, Rails 7/8 compatibility
- ✅ **Guard introspection** - `may_pay?` method to check if transition is possible
- ✅ **Comprehensive callbacks** - `before`, `after`, `after_commit`, `after_all_transitions`

#### What Developers HATE (Pain Points)
- ❌ **Guard failures have no built-in error messages**
  
  When a guard returns `false`, AASM raises `AASM::InvalidTransition` with NO indication of WHICH guard failed or WHY. Developers resort to hacks:
  
  ```ruby
  # The HACK developers use to track guard failures
  def ready_to_finish?
    if criteria_met?
      true
    else
      @transition_failure_reason = "Missing required documentation"  # HACK!
      false
    end
  end
  ```
  
  There is no first-class `failure_reason` API.

- ❌ **Magic method injection breaks IDE/LSP support**
  
  Dynamically generated `pay!`, `paid?`, `may_pay?` methods confuse Language Servers. Developers must "grep" to find method definitions.

- ❌ **Model bloat / "God Objects"**
  
  Complex workflows lead to massive state machine blocks in model files, violating Single Responsibility Principle.

- ❌ **Transaction rollback surprises**
  
  Using `whiny_transitions: true` (default) raises on guard failure, but catching the exception doesn't tell you which guard failed.

---

### 2. state_machines (Successor to state_machine gem)

**GitHub:** https://github.com/state-machines/state_machines  
**Maintenance:** Sporadic (community fork)

#### What Developers LOVE
- ✅ **Deep ActiveRecord integration** - validations, automatic transactions
- ✅ **Can add errors to model** on transition failure (unlike AASM)
- ✅ **Can_transition?** introspection method

#### What Developers HATE (Major Pain Points)
- ❌ **CRITICAL: Transaction rollback destroys audit logs**
  
  This is the #1 complaint. When a guard fails or callback returns false, the entire transaction rolls back—including any audit log entries created in `after_transition`. This makes it impossible to track failed transition attempts.
  
  ```ruby
  # The audit log entry created here is LOST on rollback
  after_transition do |record, transition|
    AuditLog.create!(record: record, event: transition.event)  # GONE!
  end
  ```
  
  Developers must resort to "hacks" like manual `commit_db_transaction` calls or out-of-band logging.

- ❌ **Callback hell**
  
  DSL encourages putting business logic (emails, API calls) directly in `before_transition` / `after_transition` blocks, creating unreadable "walls of code."

- ❌ **Opaque failure reasons**
  
  When `fire_event` returns `false`, developers must manually inspect:
  - Was it the current state?
  - Was it a guard?
  - Was it a validation error?
  - Was it a callback returning false?

- ❌ **Initialization edge cases**
  
  Initial state sometimes not correctly set on new records with complex inheritance.

---

### 3. workflow (geekq/workflow)

**GitHub:** https://github.com/geekq/workflow  
**Maintenance:** Stable but slow

#### What Developers LOVE
- ✅ **Lightweight** - minimal DSL, clean "Ruby-ish" feel
- ✅ **Native Graphviz diagram support** - generates visual state charts
- ✅ **Non-Rails friendly** - works with POROs
- ✅ **Convention over configuration**

#### What Developers HATE (Pain Points)
- ❌ **CRITICAL: update_column bypasses ALL ActiveRecord callbacks**
  
  By default, workflow uses `update_column` to persist state changes. This bypasses:
  - `after_save` callbacks
  - `updated_at` timestamp updates
  - Validations
  
  This causes "silent" data integrity bugs that surprise developers.

- ❌ **Workflow::NoTransitionAllowed errors are hard to debug**
  
  When a guard (conditional `:if` logic) fails, you get `NoTransitionAllowed` with no indication of WHY the guard failed.

- ❌ **ActiveRecord extracted to separate gem**
  
  Since v2.0, `workflow-activerecord` is required separately. Version mismatches cause setup friction.

- ❌ **Graphviz dependency issues**
  
  Requires `ruby-graphviz` gem; installation failures common in CI/CD environments.

---

### 4. transitions (troessner/transitions)

**GitHub:** https://github.com/troessner/transitions  
**Maintenance:** Minimal

#### What Developers HATE (Pain Points)
- ❌ **One state machine per class ONLY**
  
  Cannot manage multiple independent states (e.g., `publication_state` AND `moderation_state`) on a single model.

- ❌ **Symbol vs String conflicts**
  
  Requires symbols; using strings causes unpredictable method generation failures.

- ❌ **Naming collisions**
  
  Dynamic method generation (`event_name`, `event_name!`, `can_event_name?`) collides with existing model methods.

- ❌ **Callback complexity**
  
  `after_transition` hooks execute AFTER state change; if they fail, object left in inconsistent state.

---

### 5. stateful_enum (amatsuda/stateful_enum)

**GitHub:** https://github.com/amatsuda/stateful_enum  
**Maintenance:** Minimal

#### What Developers LOVE
- ✅ **Built on Rails enum** - zero learning curve if you know Rails
- ✅ **Minimalist** - adds state machine features to existing enum
- ✅ **Graph generation** - `rails g stateful_enum:graph`

#### What Developers HATE (Pain Points)
- ❌ **Tightly coupled to ActiveRecord**
  
  Cannot use with POROs, Mongoid, or non-database objects.

- ❌ **Limited feature set**
  
  No `after_commit` callbacks, no granular lifecycle control, difficult to have multiple state machines on one model.

- ❌ **Naming confusion**
  
  Both state predicate (`published?`) and event predicate (`can_publish?`) exist simultaneously—unclear which to use.

- ❌ **Same IDE/LSP issues as AASM**
  
  Dynamic method generation breaks autocomplete.

---

### 6. statesman (gocardless/statesman)

**GitHub:** https://github.com/gocardless/statesman  
**Maintenance:** Active (GoCardless production dependency)

#### What Developers LOVE
- ✅ **Built-in audit trail** - separate transition records by design
- ✅ **Decoupled architecture** - state machine in separate class, not mixed into model
- ✅ **Database constraints prevent race conditions**
- ✅ **Explicit machine instantiation** - `OrderStateMachine.new(order)`
- ✅ **JSON metadata per transition**

#### What Developers HATE (Pain Points)
- ❌ **Higher boilerplate**
  
  Requires separate transition model, migration, and state machine class. More files to manage.

- ❌ **Different testing paradigm**
  
  Must test state machine class in isolation, not model-based integration tests. Steeper learning curve.

- ❌ **More verbose**
  
  Less "magic" means more explicit code. Some developers prefer the convenience of AASM's mixed-in approach.

---

## Cross-Cutting Pain Points Summary

| Pain Point | Affected Gems | Severity |
|------------|---------------|----------|
| Guard failures lack error messages | AASM, workflow, transitions | 🔴 Critical |
| Transaction rollback destroys audit logs | state_machines | 🔴 Critical |
| update_column bypasses callbacks | workflow | 🔴 Critical |
| Magic methods break IDE/LSP | AASM, stateful_enum | 🟡 Moderate |
| Model bloat / God Objects | AASM, state_machines | 🟡 Moderate |
| Opaque failure reasons | state_machines, transitions | 🟡 Moderate |
| One machine per class limit | transitions | 🟡 Moderate |
| High boilerplate | statesman | 🟢 Low |

---

## FOSM DX Recommendations

Based on ecosystem learnings, FOSM should adopt these patterns:

### ✅ DO: First-Class Guard Error Messages

```ruby
# FOSM should allow guards to return error messages
guard :has_line_items, on: :send_invoice do |inv|
  return true if inv.line_items.any?
  
  # Instead of just 'false', return a reason:
  GuardFailed.with_reason("Invoice must have at least one line item")
end

# Then the error includes the reason:
# Fosm::GuardFailed: Invoice must have at least one line item
```

**Why:** Developers constantly struggle to answer "why did the transition fail?" Current gems require hacks (instance variables, manual error tracking). FOSM should make this first-class.

### ✅ DO: Audit Logs MUST Survive Rollbacks

```ruby
# FOSM's three strategies (:sync, :async, :buffered) already handle this!
# The transition log write happens:
# - :sync - inside the transaction (current behavior, maybe problematic)
# - :async - outside via SolidQueue (survives rollback!)
# - :buffered - outside via buffer flush (survives rollback!)
```

**Recommendation:** Default to `:async` strategy so failed transitions are still logged. This is a MAJOR differentiator from state_machines.

### ✅ DO: Ship RSpec Matchers with the Gem

```ruby
# FOSM should provide:
require 'fosm/rspec'

# Then developers can write:
expect(invoice).to have_state(:draft)
expect(invoice).to transition_from(:draft).to(:sent).on_event(:send_invoice)
expect(invoice).to have_terminal_state(:paid)
```

**Why:** AASM's RSpec integration is beloved. FOSM should match/exceed it.

### ✅ DO: Clear can_fire? Introspection

```ruby
# FOSM already has this - make it discoverable:
invoice.can_fire?(:send_invoice)  # => true/false
invoice.available_events          # => [:send_invoice, :cancel]

# And for debugging WHY:
invoice.why_cannot_fire?(:send_invoice)  # => "Guard 'has_line_items' failed"
```

**Recommendation:** Add `why_cannot_fire?` for debugging guard failures.

### ✅ DO: Explicit Side-Effect Declarations

```ruby
# FOSM's current approach is good - keep it explicit:
side_effect :notify_client, on: :send_invoice do |inv, transition|
  InvoiceMailer.send_to_client(inv).deliver_later
end
```

**Why:** Avoids the "callback hell" of state_machines where side effects are mixed with transition definitions.

### ✅ DO: Separate Guard and Side-Effect Testing

```ruby
# FOSM should make guards testable in isolation:
RSpec.describe Fosm::Invoice::Guard::HasLineItems do
  it "fails when invoice has no line items" do
    invoice = build(:invoice, line_items: [])
    result = described_class.call(invoice)
    
    expect(result.success?).to be false
    expect(result.reason).to eq("Invoice must have at least one line item")
  end
end
```

**Why:** Current gems require testing through the full model lifecycle. FOSM's named guards/side_effects enable isolated unit testing.

---

## Anti-Patterns to AVOID (Learned from Ecosystem)

### ❌ DON'T: Use update_column for persistence

**workflow gem does this** - it bypasses callbacks and timestamps. Always use proper ActiveRecord save with callbacks.

### ❌ DON'T: Allow guards to have side effects

**Current FOSM principle is correct:** Guards must be pure functions. This enables `can_fire?` calls without triggering side effects.

### ❌ DON'T: Embed business logic in transition blocks

**state_machines does this** - creates "callback hell." FOSM's explicit `side_effect` declarations are cleaner.

### ❌ DON'T: Lose audit logs on transaction rollback

**state_machines does this** - it's a critical flaw. FOSM's async/buffered strategies avoid this.

### ❌ DON'T: Generate methods that break IDE support

**AASM, stateful_enum do this** - makes code harder to navigate. FOSM's explicit `fire!(:event)` approach is better, though predicate methods (`sent?`) are still magic. Consider documenting IDE plugins or providing a LSP manifest.

---

## Community Sentiment Summary

| Gem | Love | Hate | Verdict |
|-----|------|------|---------|
| AASM | RSpec matchers, clear DSL, maintenance | Guard error messages, IDE issues | **Best overall, but guard DX needs work** |
| state_machines | AR integration | Audit log rollback, callback hell | **Avoid for audit-heavy apps** |
| workflow | Lightweight, diagrams | update_column surprise, debugging | **Good for simple POROs** |
| statesman | Audit trail, decoupled | Boilerplate, verbose | **Best for compliance/auditing** |
| transitions | - | One machine limit, naming | **Don't use** |
| stateful_enum | Minimalist | Limited features | **Only for simple enums** |

---

## Final Recommendations for FOSM

1. **Implement `why_cannot_fire?`** - Developers need to know WHY guards failed
2. **Default to `:async` logging** - Failed transitions should still be auditable
3. **Ship RSpec matchers** - Match AASM's excellent testing experience
4. **Document the guard/side-effect separation** - This is a unique FOSM strength
5. **Provide IDE support** - Consider a rubocop plugin or sorbet types for method generation
6. **Keep the explicit philosophy** - Resist "magic" that breaks discoverability

FOSM is well-positioned to address the ecosystem's biggest gaps:
- Guard error messages (nobody does this well)
- Audit log durability (state_machines fails here)
- Clean separation of concerns (avoiding callback hell)

**The opportunity:** Be the first Ruby state machine gem where debugging guard failures is as easy as reading an error message.
