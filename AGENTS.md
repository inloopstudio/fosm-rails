# AGENTS.md — Understanding and Extending fosm-rails

This file is for AI coding agents, contributors, and developers who want to understand the deep design philosophy behind this engine and contribute to it thoughtfully.

---

## What is FOSM?

**FOSM** stands for **Finite Object State Machine**.

The "finite" part is standard: a countable number of states, with explicit transitions between them. The "object" part is what makes it different: the state machine is **bound to a specific business entity** — an Invoice, a Candidate, a Contract, a Deal. The lifecycle is not an abstract workflow. It *is* the domain object.

### The core problem FOSM solves

Every business application has objects that move through lifecycles. An Invoice gets drafted, sent, paid or disputed, possibly cancelled. A Candidate gets applied, screened, interviewed, offered, hired or rejected. A Contract gets drafted, reviewed, signed, executed.

The conventional CRUD approach models these as a table row with a `status` column — a mutable string with no opinions about what comes before or after. The business rules that govern valid transitions end up scattered across the codebase:

- `if`-statements in controllers
- `before_save` callbacks in models
- validation logic in service objects
- guard conditions in Sidekiq jobs

None of it is connected. Ask a new developer "what are the rules for invoices?" and the honest answer is: read every file that touches the `Invoice` model, then pray.

FOSM declares the rules **as part of what it means to be an Invoice**:

```ruby
class Invoice < ApplicationRecord
  include Fosm::Lifecycle

  lifecycle do
    state :draft,     initial: true
    state :sent
    state :paid,      terminal: true
    state :overdue
    state :cancelled, terminal: true

    event :send_invoice, from: :draft,           to: :sent
    event :pay,          from: [:sent, :overdue], to: :paid
    event :mark_overdue, from: :sent,             to: :overdue
    event :cancel,       from: [:draft, :sent],   to: :cancelled

    guard :has_line_items, on: :send_invoice do |inv|
      inv.line_items.any?
    end

    side_effect :notify_client, on: :send_invoice do |inv, transition|
      InvoiceMailer.send_to_client(inv).deliver_later
    end
  end
end
```

That block is the complete lifecycle specification. There is no path from `draft` to `paid` — the machine won't allow it. There is no path from `paid` to anything — it's terminal. You can see the five states, the four events, the guard condition, and the side effect in twenty lines of code.

---

## The abstraction: one lifecycle definition, three superpowers

When a developer writes a lifecycle block and runs the generator, they get three things without writing any additional code:

**1. A CRUD application that enforces the lifecycle**
The generated controller and views allow users to create records and fire transitions. The UI only offers valid actions — the machine decides what buttons appear. Guards, terminal states, and invalid transitions are enforced at the Rails level.

**2. An immutable audit trail**
Every state change is written to `fosm_transition_logs` with the actor, timestamp, and metadata. No configuration required. The log is tamper-proof — read-only at the database level.

**3. A fully-configured AI agent**
The `Fosm::Agent` base class reads the lifecycle definition at runtime and auto-generates a complete set of Gemlings tools. You don't write a single line of agent code to get a working agent. The agent appears immediately at `/fosm/admin/apps/:slug/agent` after the lifecycle is defined.

This is the beauty of the FOSM abstraction: **the lifecycle is the single source of truth** for the CRUD rules, the audit log schema, and the AI agent's capabilities. They cannot drift from each other because they all read from the same definition.

---

## Why FOSM matters now

State machines have existed for sixty years. The reason they didn't become the default paradigm for business software is the **specification problem**: you had to enumerate every state, every transition, every guard condition upfront. Business processes are messy, requirements shift, and Agile won because upfront specification is too expensive in a fast-moving world.

**AI dissolves this problem.**

An LLM already knows what an invoice lifecycle looks like. Tell it "build me an invoicing module" and it produces a reasonable first-draft state machine in seconds — because invoice processing is one of the most documented business processes in human history.

But there is a deeper point. When you pair AI with a FOSM-structured codebase, you get **bounded autonomy**:

- An AI agent operating within a FOSM system can only do what the state machine allows
- It cannot skip a step, invent a transition, or operate outside the declared lifecycle
- The machine is the guardrail — you don't need to trust the AI's judgment, only the state machine
- When the AI fires `send_invoice!(actor: :agent)`, if the invoice isn't in `draft` state, the machine refuses

**FOSM makes AI safe. AI makes FOSM practical. Neither works as well without the other.**

---

## Design principles of this engine

When contributing to fosm-rails, keep these principles in mind. They are not conventions — they are load-bearing.

### 1. `fire!` is the only mutation path

State must never change via `update(state: "paid")` or direct attribute assignment. The only valid path is `fire!(:event_name, actor:)`. This is what makes the audit trail complete, the guards enforceable, and the AI agents bounded.

**Do not** add any method to `Fosm::Lifecycle` that changes state without going through `fire!`.

### 2. Guards are pure functions

A guard receives the record and returns true or false. It has no side effects. This is critical for the `can_fire?` method — it is called to check availability without triggering anything. If a guard had side effects, `can_fire?` would have side effects, which would break the admin UI, the agent's `available_events_for_*` tool, and any code that inspects state.

**Do not** allow guards to modify state or trigger external calls.

### 3. Every transition is logged

`Fosm::TransitionLog` is immutable and append-only. The `before_update` and `before_destroy` callbacks raise `ActiveRecord::ReadOnlyRecord`. This is intentional — the audit trail must be complete and tamper-proof.

**Do not** add `updated_at` to `fosm_transition_logs`. Do not add a soft-delete mechanism.

### 4. Terminal states are irreversible by design

When a state is declared `terminal: true`, any attempt to fire an event from it raises `Fosm::TerminalState`. This is the architectural equivalent of a physical lock. Business logic that needs to "undo" a terminal state should use a compensating event (e.g., `reopen` that goes from `cancelled` to `draft`), not by removing the terminal constraint.

### 5. The lifecycle definition is the documentation

The admin explorer renders the lifecycle definition directly from the Ruby code — it doesn't read a separate diagram file or database record. This means the documentation is always accurate because it IS the running code.

**Do not** add a separate "description" mechanism that could drift from the actual implementation.

### 6. AI agents are bounded, not trusted

The `Fosm::Agent` base class generates exactly one Gemlings tool per lifecycle event. The tool calls `fire!` which enforces the machine rules. The AI cannot fire an event that doesn't exist. The AI cannot bypass a guard. The AI cannot modify state directly.

When adding new agent capabilities, add new **lifecycle events** (which automatically generate new agent tools), not new raw database tools.

---

## Engine architecture

```
lib/
  fosm/
    lifecycle.rb                  ← ActiveSupport::Concern — the main DSL mixin
    lifecycle/
      definition.rb               ← Holds states/events/guards/side_effects for one model
      state_definition.rb         ← Value object: name, initial?, terminal?
      event_definition.rb         ← Value object: name, from_states, to_state, guards, side_effects
      guard_definition.rb         ← Named callable: (record) → bool
      side_effect_definition.rb   ← Named callable: (record, transition) → void
    agent.rb                      ← Base class: model_class DSL + Gemlings tool generation
    configuration.rb              ← Fosm.configure { } block
    registry.rb                   ← Global slug → model_class map
    errors.rb                     ← Fosm::InvalidTransition, GuardFailed, etc.
    engine.rb                     ← Rails::Engine, migration hooks, auto-registration
  fosm-rails.rb                   ← Entry point

app/
  models/fosm/
    transition_log.rb             ← Immutable audit trail (shared across all FOSM apps)
    webhook_subscription.rb       ← Admin-configured HTTP callbacks
  controllers/fosm/
    application_controller.rb     ← Inherits from configured base_controller
    admin/
      base_controller.rb          ← Admin auth before_action
      dashboard_controller.rb
      apps_controller.rb
      transitions_controller.rb
      webhooks_controller.rb
  jobs/fosm/
    webhook_delivery_job.rb       ← Async HTTP POST with HMAC signing, retries

lib/generators/fosm/app/
  app_generator.rb                ← rails generate fosm:app
  templates/
    model.rb.tt
    controller.rb.tt
    agent.rb.tt
    migration.rb.tt
    routes.rb.tt
    views/
```

---

## How `fire!` works

```
record.fire!(:send_invoice, actor: current_user)

1. Look up the event definition in fosm_lifecycle
2. Check: does the event exist? → raise UnknownEvent if not
3. Check: is current state terminal? → raise TerminalState if yes
4. Check: is the event valid from current state? → raise InvalidTransition if not
5. Run guards: each guard.call(record) → raise GuardFailed if any return false
6. Begin database transaction:
   a. UPDATE record SET state = 'sent'
   b. INSERT INTO fosm_transition_logs (...)
   c. Run each side_effect.call(record, transition_data)
   d. COMMIT (or ROLLBACK if any step raises)
7. Enqueue WebhookDeliveryJob asynchronously (outside transaction)
8. Return true
```

The transaction ensures that if a side effect raises, the state update is rolled back. The webhook job fires outside the transaction so it doesn't delay the response and doesn't roll back if the HTTP call fails.

---

## Gemlings: the required agent dependency

`gemlings` is declared as a **required dependency** in `fosm-rails.gemspec` — not optional. This is a deliberate design decision: the agent capability is not a plugin or an afterthought, it is a first-class output of every lifecycle definition.

When you add `gem "fosm-rails"` to a project, you get the agent framework automatically. Set `ANTHROPIC_API_KEY` (or another provider key such as `OPENAI_API_KEY` or `GEMINI_API_KEY`) in your environment and the agent is ready to use.

Supported LLM providers come from the `ruby_llm` gem that Gemlings depends on. The default model is `anthropic/claude-sonnet-4-20250514`. Override it per-agent:

```ruby
class Fosm::InvoiceAgent < Fosm::Agent
  model_class Fosm::Invoice
  default_model "openai/gpt-4o"
end
```

### Compatibility note

The engine's `initializer "fosm.configuration"` includes two runtime patches to `Gemlings::Memory` and `Gemlings::Models::RubyLLMAdapter`. These patches fix Anthropic API incompatibilities in Gemlings' `ToolCallingAgent`:

1. **Trailing whitespace** — Anthropic rejects assistant messages whose content ends with whitespace. The patch strips it from all messages in `to_messages`.
2. **Tool result format** — After a tool_use block, Anthropic requires a structured `tool_result` block in the next user message. Gemlings generates a plain `"Observation: ..."` text message instead. The patch rewrites these into the correct `{ type: "tool_result", tool_use_id: ..., content: ... }` format, and `load_messages` uses `role: :tool` when passing them to `ruby_llm`.

These patches are applied once at boot via `prepend` and are invisible to application code. If Gemlings fixes these issues upstream, the patches become no-ops.

---

## The Admin Agent Explorer

For every registered FOSM app, the admin provides two agent-specific pages:

**`/fosm/admin/apps/:slug/agent`** — The Tool Catalog
- Lists all auto-generated tools (read tools and mutate tools) with their descriptions and parameter signatures
- Provides a **Direct Tool Tester** — invoke any tool from the browser with no LLM involved. Useful for verifying tool behaviour and debugging lifecycle configurations.
- Shows the **System Prompt** — the exact constraints injected into the LLM, including terminal states and the instruction to always call `available_events_for_*` before firing.

**`/fosm/admin/apps/:slug/agent/chat`** — The Agent Chat
- Multi-turn conversation with the live Gemlings agent
- Each response shows a collapsible **reasoning trace**: tool calls, observations, and the LLM's thought process
- "New conversation" clears context and starts fresh

The Tool Tester is particularly valuable during development: you can verify that your guards are working correctly, that events are available in the right states, and that your lifecycle behaves as designed — all without writing a test.

---

## The Gemlings agent tools

For a model with this lifecycle:

```ruby
lifecycle do
  state :draft, initial: true
  state :sent
  state :paid, terminal: true

  event :send_invoice, from: :draft, to: :sent
  event :pay,          from: :sent,  to: :paid
end
```

The following Gemlings tools are auto-generated:

| Tool name | What it does |
|---|---|
| `list_invoices` | `Invoice.all` (or filtered by `state:`) |
| `get_invoice` | `Invoice.find(id)` with state + available_events |
| `available_events_for_invoice` | `record.available_events` |
| `transition_history_for_invoice` | `TransitionLog.for_record(...)` |
| `send_invoice_invoice` | `record.fire!(:send_invoice, actor: :agent)` |
| `pay_invoice` | `record.fire!(:pay, actor: :agent)` |

The event tools are named `{event_name}_{model_name}` to avoid ambiguity in multi-model agent workflows.

The agent's system prompt includes:
- The valid states for the model
- The terminal states
- The available events
- Explicit instructions to always call `available_events_for_*` before firing
- Instructions to accept `{ success: false }` responses without retrying

---

## How to add a new FOSM app

```bash
rails generate fosm:app lead_capture \
  --fields first_name:string last_name:string email:string company:string \
  --states new,qualified,contacted,converted,lost \
  --access authenticate_user!
```

Then:
1. Edit `app/models/fosm/lead_capture.rb` — fill in the events
2. Edit `app/agents/fosm/lead_capture_agent.rb` — add custom tools if needed
3. Edit `app/views/fosm/lead_capture/` — customize the UI
4. `rails db:migrate`
5. Visit `/fosm/apps/lead_captures`

---

## How to extend the admin UI

The admin views are plain ERB in `app/views/fosm/admin/`. They use basic HTML with Tailwind-compatible classes. To customize for a specific host app (e.g., to use the app's UI component library), override the views by creating matching paths in the host app:

```
app/views/fosm/admin/dashboard/index.html.erb  ← overrides the engine view
```

Rails view inheritance means host app views take precedence over engine views.

---

## Testing FOSM models

```ruby
# test/models/fosm/invoice_test.rb
class Fosm::InvoiceTest < ActiveSupport::TestCase
  setup do
    @invoice = Fosm::Invoice.create!(name: "Test", amount: 100, state: "draft")
  end

  test "draft invoice can be sent" do
    assert @invoice.can_send_invoice?
    @invoice.send_invoice!(actor: :test)
    assert @invoice.sent?
  end

  test "cannot pay a draft invoice directly" do
    assert_raises(Fosm::InvalidTransition) do
      @invoice.pay!(actor: :test)
    end
  end

  test "paid invoice is terminal" do
    @invoice.send_invoice!(actor: :test)
    @invoice.pay!(actor: :test)
    assert_raises(Fosm::TerminalState) do
      @invoice.cancel!(actor: :test)
    end
  end

  test "every transition is logged" do
    @invoice.send_invoice!(actor: :test)
    log = Fosm::TransitionLog.for_record("Fosm::Invoice", @invoice.id).last
    assert_equal "send_invoice", log.event_name
    assert_equal "draft", log.from_state
    assert_equal "sent", log.to_state
  end

  test "guard blocks sending empty invoice" do
    empty = Fosm::Invoice.create!(name: "Empty", amount: 0, state: "draft")
    assert_raises(Fosm::GuardFailed) do
      empty.send_invoice!(actor: :test)
    end
  end
end
```

---

## Contributing guidelines

1. **Read the design principles above** before writing any code
2. **No direct state mutations** — always go through `fire!`
3. **Keep the lifecycle DSL simple** — resist adding complexity (priorities, concurrent states, history states). FOSM is deliberately simple. If you need those features, look at XState or Statecharts.
4. **The admin UI is secondary** — the DSL and the transition log are the core. Admin views can be overridden by host apps.
5. **Test the lifecycle, not the persistence** — unit tests for FOSM models should test state machine behavior, not database queries
6. **Document new events in lifecycles** — use `guard` and `side_effect` names that are self-documenting

---

## Key references

- **FOSM paper**: [parolkar.com/fosm](https://parolkar.com/fosm)
- **FOSM book **: [fosm-book.inloop.studio](https://fosm-book.inloop.studio)
- **Gemlings** (AI agent framework): [github.com/khasinski/gemlings](https://github.com/khasinski/gemlings)
- **Rails Engine Guide**: [guides.rubyonrails.org/engines.html](https://guides.rubyonrails.org/engines.html)

---

*fosm-rails is an open-source implementation of ideas from Abhishek Parolkar's FOSM research. The goal is to make business software that is auditable, AI-safe, and self-documenting by design.*
