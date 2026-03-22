# Nested Modal Transducers: Research for FOSM Composition

## Executive Summary

This research explores **nested modal transducers** as a data-only alternative to full statecharts, with the goal of extending FOSM's lifecycle DSL to support compositional patterns without losing its core philosophy: *lifecycle as documentation*.

## Core Concepts

### 1. Transducer Fundamentals

A **transducer** is a higher-order function that transforms a reducer: `(reducer → reducer)`. In state machine terms:

- **Input**: Current state + event → **Output**: New state + effects
- **Composition**: Transducers compose left-to-right: `t1 >> t2 >> t3`
- **Data-only**: The entire machine state is serializable, replayable, auditable

```ruby
# Pure transducer form - state = f(input, prev_state)
Transition = Data.define(:event, :from, :to, :guard, :effect)

# A transducer is just a function
transduce = ->(state, transition, event) {
  return state unless transition.guard.call(state, event)
  transition.effect.call(state, event)
  transition.to
}
```

### 2. The "Modal" Aspect

**Modal** means context-dependent transition sets. A machine in "mode A" has different available events than in "mode B". This is FOSM's existing `from:` constraint, but extended hierarchically:

```
Parent Machine: Invoice
├── Mode: draft → [send_invoice, delete]
├── Mode: sent → [pay, mark_overdue, cancel]
└── Child Machine: PaymentProcessing (only active in :sent mode)
    ├── Mode: pending → [process]
    ├── Mode: processing → [complete, fail]
    └── Mode: completed → [reconcile]
```

The child machine's existence is modal - it only has state when the parent is in specific modes.

## Research Findings: Existing Patterns

### 1. Redux Nested Reducers (Horizontal + Vertical)

**Horizontal composition** (`combineReducers`) maps to FOSM's flat state space:

```javascript
// Redux: separate slices
combineReducers({
  invoice: invoiceReducer,
  payment: paymentReducer  // parallel, independent
})
```

**Vertical composition** (parent calls child) maps to nested FOSM machines:

```javascript
// Redux: parent delegates to child
function invoiceReducer(state, action) {
  if (state.status === 'sent') {
    // Child machine processes payment-related actions
    return { ...state, payment: paymentReducer(state.payment, action) }
  }
  return state
}
```

**Higher-Order Reducers** as transducers:

```javascript
// withUndo wraps any reducer
const undoableInvoice = withUndo(invoiceReducer, { limit: 10 })
```

**FOSM Mapping**: Events can wrap other events, adding guard/side-effect layers.

### 2. Elm TEA: Parent-Child Communication

Elm's nested architecture uses three key patterns:

**Wrapper Pattern (Structural)**:

```elm
-- Parent holds child's model, parent's Msg wraps child's
type alias Model = { childState : Child.Model }
type Msg = ChildMsg Child.Msg | ParentSpecificMsg

update msg model =
  case msg of
    ChildMsg childMsg ->
      let (newChild, childCmd) = Child.update childMsg model.childState
      in ({ model | childState = newChild }, Cmd.map ChildMsg childCmd)
```

**OutMsg Pattern (Communication)**:

```elm
-- Child signals parent via Maybe OutMsg
type OutMsg = ItemSelected Int | RequestClose
update : Msg -> Model -> ( Model, Cmd Msg, Maybe OutMsg )

-- Parent pattern-matches on OutMsg
```

**Translator Pattern (Decoupling)**:

```elm
-- Parent passes translation dictionary to child
type alias Translator = { onSelect : Int -> ParentMsg, onClose : ParentMsg }
```

**FOSM Mapping**: Child machines communicate to parent via:
1. Return values from `fire!`
2. Side effects that bubble up
3. Shared data in parent record

### 3. Statebox/Boxes (Ruby + Petri Nets)

Statebox uses **Petri Nets** with functional composition:

- **Places** hold tokens (can be in multiple states simultaneously)
- **Transitions** are pure functions: `transition :send, from: :draft, to: :sent, guard: ->(tokens) { ... }`
- **Composition** via wiring outputs to inputs

Key insight: **Concurrent states** - different from FSMs, allows modeling parallel workflows.

### 4. Mealy/Moore + Lenses

From functional programming research:

- **Moore Machine**: Output depends only on state: `S → O`
- **Mealy Machine**: Output depends on state + input: `S × I → O`
- **Lens**: `view: S → A` (observe), `set: S → A → S` (update)

**Lens Composition for Nested State**:

```haskell
-- Parent lens focuses into child state
childLens :: Lens' ParentState ChildState

-- Compose machines: parent knows how to "zoom" into child
composed :: Moore ParentState ParentOutput
composed = zoom childLens childMachine parentMachine
```

### 5. XState Actor Model

XState v5 uses the **Actor Model**:

- **Parent → Child**: `sendTo('childId', event)`
- **Child → Parent**: `sendParent(event)`
- **Parallel regions**: Broadcast via parent
- **System**: Global actor registry

## Proposed FOSM Composition Patterns

### Pattern 1: Association-Based Nesting

Child machines attached via ActiveRecord associations:

```ruby
class Fosm::Invoice < ApplicationRecord
  include Fosm::Lifecycle
  
  has_one :payment_processing, class_name: 'Fosm::PaymentProcessing'
  
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    event :send_invoice, from: :draft, to: :sent do
      spawn :payment_processing, initial: :pending
    end
    
    event :pay, from: :sent, to: :paid do
      guard :child_in_state, child: :payment_processing, state: :completed
    end
  end
end
```

### Pattern 2: Higher-Order Lifecycle

Wrap existing lifecycles to add behavior:

```ruby
class Fosm::Invoice < ApplicationRecord
  include Fosm::Lifecycle
  include Fosm::WithUndo
  
  lifecycle do
    state :draft, initial: true
    state :sent
    state :paid, terminal: true
    
    event :send_invoice, from: :draft, to: :sent
    event :pay, from: :sent, to: :paid
    
    with_undo limit: 5  # Adds undo event to all states
  end
end
```

### Pattern 3: Modal Regions

Parallel state regions within one record:

```ruby
class Fosm::Order < ApplicationRecord
  include Fosm::Lifecycle
  
  lifecycle do
    state :created, initial: true
    state :processing
    state :completed, terminal: true
    
    modal :processing do
      region :payment do
        state :pending, initial: true
        state :authorized
        state :captured, terminal: true
        
        event :authorize, from: :pending, to: :authorized
        event :capture, from: :authorized, to: :captured
      end
      
      region :fulfillment do
        state :unfulfilled, initial: true
        state :picked
        state :packed
        state :shipped, terminal: true
        
        event :pick, from: :unfulfilled, to: :picked
        event :pack, from: :picked, to: :packed
        event :ship, from: :packed, to: :shipped
      end
      
      # Synchronization: parent completes when ALL regions terminal
      guard :all_regions_terminal, on: :complete do |record|
        record.payment_terminal? && record.fulfillment_terminal?
      end
    end
    
    event :process, from: :created, to: :processing
    event :complete, from: :processing, to: :completed
  end
end
```

### Pattern 4: Event Delegation

Parent delegates events to children:

```ruby
class Fosm::Invoice < ApplicationRecord
  include Fosm::Lifecycle
  
  has_one :approval_workflow
  
  lifecycle do
    state :draft, initial: true
    state :under_review
    state :approved
    state :rejected, terminal: true
    
    event :submit_for_review, from: :draft, to: :under_review do
      spawn :approval_workflow, initial: :pending_review
    end
    
    # Delegate to child - child's events become valid in parent's context
    delegate :approval_workflow, events: [:approve, :reject, :request_changes]
    
    # Parent handles child OutMsg
    on_child_event :approval_workflow, :approve do |invoice, transition|
      invoice.fire!(:approve, actor: transition.actor)
    end
    
    event :approve, from: :under_review, to: :approved
    event :reject, from: :under_review, to: :rejected
  end
end
```

## Implementation Architecture

### Pure Data Representation

For auditability, nested machines must be fully serializable:

```ruby
# Transition log entry for nested machine
{
  record_type: "Fosm::Invoice",
  record_id: "123",
  event_name: "send_invoice",
  from_state: "draft",
  to_state: "sent",
  modal_states: {
    payment_processing: { state: "pending", created_at: "2024-01-15T10:30:00Z" }
  },
  actor_type: "User",
  actor_id: "42"
}
```

### Minimal Core Extensions

```ruby
# lib/fosm/lifecycle/definition.rb

class Definition
  def child(name, class_name:, foreign_key: nil)
    @children[name] = ChildDefinition.new(name, class_name, foreign_key)
  end
  
  def modal(name, &block)
    @modals[name] = ModalDefinition.new(&block)
  end
  
  def delegate(child_name, events:)
    events.each do |event_name|
      event "#{child_name}_#{event_name}",
            from: :any,
            to: :no_change,
            delegate_to: child_name,
            delegate_event: event_name
    end
  end
end
```

## Mapping to FOSM Philosophy

### "Lifecycle as Documentation" Preserved

All four patterns maintain the core philosophy:

| Aspect | Current FOSM | With Composition |
|--------|--------------|------------------|
| **States visible** | Flat list | Hierarchical with indentation |
| **Events visible** | All in one block | Grouped by mode/region |
| **Guards** | Inline | Can reference child state |
| **Side effects** | Inline | Can bubble from children |
| **Audit trail** | Single state | Nested state snapshots |

### Example: Complex Invoice with All Patterns

```ruby
class Fosm::Invoice < ApplicationRecord
  include Fosm::Lifecycle
  
  # Association nesting
  has_one :payment
  has_one :approval
  
  lifecycle do
    # ===== STATES =====
    state :draft, initial: true
    state :sent
    state :under_review
    state :approved
    state :paid, terminal: true
    state :cancelled, terminal: true
    
    # ===== CHILD MACHINES =====
    child :payment, class_name: 'Fosm::Payment'
    child :approval, class_name: 'Fosm::Approval'
    
    # ===== EVENTS =====
    
    # Draft mode
    event :send, from: :draft, to: :sent do
      spawn :payment, initial: :pending
      guard :has_line_items
    end
    
    # Sent mode - payment active
    modal :sent do
      # Events delegated to payment child
      delegate :payment, events: [:authorize, :capture, :fail]
      
      # Guard based on child state
      event :request_approval, from: :sent, to: :under_review do
        spawn :approval, initial: :pending
        guard :child_in_state, child: :payment, state: :authorized
      end
    end
    
    # Review mode - approval active
    modal :under_review do
      delegate :approval, events: [:approve, :reject]
      
      on_child_event :approval, :approved do |inv, trans|
        inv.fire!(:approve, actor: trans.actor)
      end
    end
    
    event :approve, from: :under_review, to: :approved
    event :pay, from: :approved, to: :paid
    
    # Universal
    event :cancel, from: [:draft, :sent], to: :cancelled
    
    # ===== ACCESS CONTROL =====
    access do
      role :seller, default: true do
        can :send, :request_approval
      end
      role :finance do
        can :payment_authorize, :payment_capture
        can :pay
      end
      role :manager do
        can :approval_approve, :approval_reject
        can :cancel
      end
    end
  end
end
```

## Recommendations

### Priority 1: Association-Based Nesting
- Most natural fit for Rails
- Leverages existing ActiveRecord patterns
- Minimal DSL additions needed

### Priority 2: Modal Guard Enhancement
- Allow guards to reference child state
- `guard :child_in_state, child: :name, state: :X`
- No structural changes to state machine

### Priority 3: Event Delegation
- Clean Elm-style OutMsg pattern
- Parent remains source of truth
- Child machines remain reusable

### Defer: Full Parallel Regions
- More complex, affects audit trail
- Petri-net semantics differ from FSM
- Consider as separate extension

## References

1. **Redux**: https://redux.js.org/faq/reducers
2. **Elm TEA**: https://sporto.github.io/elm-patterns/architecture/nested-tea.html
3. **Statebox**: https://github.com/statebox
4. **Lensy Moore**: https://blog.cofree.coffee/2024-07-02-lensy-moore/
5. **XState**: https://stately.ai/docs/parent-states
6. **dry-lifecycle**: https://github.com/hashrabbit/dry-lifecycle

---

*Research completed: 2026-03-20*
*Author: NiceMoon (Nested Modal Transducer Researcher)*
