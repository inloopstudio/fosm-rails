# fosm-rails

**Finite Object State Machine for Rails** — declarative lifecycles for business objects, with an AI agent interface that enforces bounded autonomy.

```ruby
class Invoice < ApplicationRecord
  include Fosm::Lifecycle

  lifecycle do
    state :draft,     initial: true
    state :sent
    state :paid,      terminal: true
    state :cancelled, terminal: true

    event :send_invoice, from: :draft,  to: :sent
    event :pay,          from: :sent,   to: :paid
    event :cancel,       from: [:draft, :sent], to: :cancelled

    guard :has_line_items, on: :send_invoice do |invoice|
      invoice.amount > 0
    end

    side_effect :notify_client, on: :send_invoice do |invoice, transition|
      InvoiceMailer.send_to_client(invoice).deliver_later
    end
  end
end
```

That block is the complete lifecycle specification. There is no path from `draft` to `paid`. There is no path out of `paid` — it's terminal. A guard blocks sending an empty invoice. A side effect fires the notification email. The machine enforces all of it.

---

## Installation

Add to your `Gemfile`:

```ruby
gem "fosm-rails"
```

`gemlings` (the AI agent framework) is a **required dependency** — it is declared in `fosm-rails.gemspec` and installed automatically. You do not need to add it separately. Set the API key for your LLM provider (e.g. `ANTHROPIC_API_KEY`) and the agent is ready to use with no extra configuration.

Run:

```bash
bundle install
rails fosm:install:migrations
rails db:migrate
```

Mount the engine in `config/routes.rb`:

```ruby
Rails.application.routes.draw do
  mount Fosm::Engine => "/fosm"
  draw :fosm  # draws config/routes/fosm.rb (auto-created by generators)
end
```

Configure auth and performance in `config/initializers/fosm.rb`:

```ruby
Fosm.configure do |config|
  # The base controller the FOSM engine inherits from
  config.base_controller = "ApplicationController"

  # Who can access /fosm/admin — should be superadmin only
  config.admin_authorize = -> { redirect_to root_path unless current_user&.superadmin? }

  # How to authorize individual FOSM apps
  config.app_authorize = ->(_level) { authenticate_user! }

  # How to get the current user (for transition log actor tracking and RBAC)
  config.current_user_method = -> { current_user }

  # Layouts
  config.admin_layout = "admin"    # your admin layout
  config.app_layout   = "application"

  # Transition log write strategy:
  #   :sync     — INSERT inside the fire! transaction (strictest consistency, default)
  #   :async    — SolidQueue job after commit (non-blocking, recommended for production)
  #   :buffered — bulk INSERT every ~1s via background thread (highest throughput)
  config.transition_log_strategy = :async
end
```

---

## Quickstart: create a new FOSM app

```bash
rails generate fosm:app invoice \
  --fields name:string amount:decimal client_name:string due_date:date \
  --states draft,sent,paid,overdue,cancelled \
  --access authenticate_user!
```

This generates:

```
app/models/fosm/invoice.rb          # Model with lifecycle DSL stub
app/controllers/fosm/invoice_controller.rb
app/views/fosm/invoice/             # index, show, new, _form
app/agents/fosm/invoice_agent.rb    # Gemlings AI agent
db/migrate/..._create_fosm_invoices.rb
config/routes/fosm.rb               # Route registration
```

Then run `rails db:migrate` and visit `/fosm/apps/invoices`.

> **One lifecycle definition → three things for free**
>
> When you run `rails generate fosm:app invoice`, FOSM generates a model with a lifecycle stub, a CRUD controller, HTML views, database migration, and a Gemlings AI agent — all wired together. Define the states, events, guards, and side effects once. The CRUD UI enforces them. The AI agent is bounded by them. The admin dashboard visualises them.

---

## Defining lifecycles

### States

```ruby
lifecycle do
  state :draft,  initial: true   # starting state (exactly one allowed)
  state :active
  state :closed, terminal: true  # no transitions out of terminal states
end
```

### Events

```ruby
event :activate,  from: :draft,             to: :active
event :close,     from: [:draft, :active],  to: :closed
```

### Guards

Guards are **pure functions** — they block a transition if they return false. No side effects inside guards.

```ruby
guard :has_required_fields, on: :activate do |record|
  record.name.present? && record.amount.positive?
end
```

### Side effects

Side effects run **after** the state persists, within the same database transaction.

```ruby
side_effect :send_notification, on: :activate do |record, transition|
  # transition contains: { from:, to:, event:, actor: }
  NotificationMailer.activated(record).deliver_later
end
```

### Access control (RBAC)

Declare role-based access control inside the `lifecycle` block. Without an `access` block the object is **open-by-default** (all authenticated actors can do everything — backwards-compatible). Once you add an `access` block, the object becomes **deny-by-default**: only explicitly granted capabilities work.

```ruby
lifecycle do
  state :draft, initial: true
  state :sent
  state :paid, terminal: true
  state :cancelled, terminal: true

  event :send_invoice, from: :draft,          to: :sent
  event :pay,          from: [:sent],         to: :paid
  event :cancel,       from: [:draft, :sent], to: :cancelled

  # ── Access control ────────────────────────────────────────────────
  access do
    # default: true → this role is auto-assigned to the record creator on create
    role :owner, default: true do
      can :crud                      # shorthand: create + read + update + delete
      can :send_invoice, :cancel     # lifecycle events this role may fire
    end

    role :approver do
      can :read                      # view the record
      can :pay                       # fire the :pay event (separation of duties)
    end

    role :viewer do
      can :read                      # read-only, no event access
    end
  end
end
```

**`can` accepts:**

| Argument | Meaning |
|---|---|
| `:crud` | Shorthand for all four CRUD operations |
| `:create` / `:read` / `:update` / `:delete` | Individual CRUD permission |
| `:send_invoice`, `:pay`, etc. | Permission to fire that specific lifecycle event |

**Bypass rules (never blocked by RBAC):**

| Actor | Reason |
|---|---|
| `actor: nil` | No user context (cron jobs, migrations, console) |
| `actor: :system` or any Symbol | Programmatic / internal invocations |
| Superadmin (`actor.superadmin? == true`) | Root equivalent — bypasses all checks |

#### Role assignment database

Roles are stored in `fosm_role_assignments`. Two scopes:

```ruby
# Type-level: Alice is an :approver for ALL Fosm::Invoice records
Fosm::RoleAssignment.create!(
  user_type:     "User",
  user_id:       alice.id.to_s,
  resource_type: "Fosm::Invoice",
  resource_id:   nil,           # nil = type-level
  role_name:     "approver"
)

# Record-level: Bob is an :owner for Invoice #42 only
Fosm::RoleAssignment.create!(
  user_type:     "User",
  user_id:       bob.id.to_s,
  resource_type: "Fosm::Invoice",
  resource_id:   "42",          # specific record
  role_name:     "owner"
)
```

**Auto-assignment on create:** if `default: true` is set on a role and the record has a `created_by` association, FOSM automatically assigns that role to the creator when the record is saved.

#### Runtime performance

The first RBAC check in a request loads ALL role assignments for the current actor in **one SQL query**, then serves all subsequent checks in the same request from an in-memory hash (O(1)). The cache resets automatically at the end of each request via `ActiveSupport::CurrentAttributes`.

#### CRUD enforcement in controllers

Use `fosm_authorize!` in generated controllers to enforce CRUD permissions:

```ruby
class Fosm::InvoiceController < Fosm::ApplicationController
  before_action -> { fosm_authorize!(:read,   Fosm::Invoice) }, only: [:index, :show]
  before_action -> { fosm_authorize!(:create, Fosm::Invoice) }, only: [:new, :create]
  before_action -> { fosm_authorize!(:update, @record) },       only: [:edit, :update]
  before_action -> { fosm_authorize!(:delete, @record) },       only: [:destroy]
end
```

Raises `Fosm::AccessDenied` (a subclass of `Fosm::Error`) if the actor lacks the required role. RBAC is only checked if the lifecycle has an `access` block — otherwise `fosm_authorize!` is a no-op.

#### Admin UI for roles

- **App detail page** (`/fosm/admin/apps/:slug`) — shows a read-only access control matrix below the lifecycle definition table, with one column per CRUD action and one per lifecycle event
- **Role assignments** (`/fosm/admin/roles`) — manage role assignments, view declared roles per app, and browse the immutable access event audit trail

---

## Firing events

```ruby
# Dynamic bang method (generated per event)
invoice.send_invoice!(actor: current_user)
invoice.pay!(actor: current_user)
invoice.cancel!(actor: current_user, metadata: { reason: "client request" })

# Or via the generic fire! method
invoice.fire!(:send_invoice, actor: current_user)

# Check before firing
invoice.can_send_invoice?     # => true/false
invoice.available_events      # => [:pay, :cancel]
invoice.draft?                # => false (state predicate)
invoice.sent?                 # => true
```

When a transition is invalid, `fire!` raises a `Fosm::InvalidTransition` error. When a guard fails, it raises `Fosm::GuardFailed`. There is no silent state corruption.

---

## AI Agents (powered by Gemlings)

**Every FOSM app automatically has a fully-configured AI agent.** You don't write any agent code to get started — the tools are derived directly from the lifecycle definition at runtime. The agent is bounded by the same rules as the human UI: it can only fire events that exist, it cannot bypass guards, and every action is written to the immutable transition log.

Each FOSM app auto-generates standard Gemlings tools from the lifecycle definition. The agent can only fire events that exist in the machine.

```ruby
# app/agents/fosm/invoice_agent.rb
class Fosm::InvoiceAgent < Fosm::Agent
  model_class Fosm::Invoice
  default_model "anthropic/claude-sonnet-4-20250514"

  # Optional: add custom tools
  fosm_tool :find_overdue,
            description: "Find sent invoices past their due date",
            inputs: {} do
    Fosm::Invoice.where(state: "sent")
                 .where("due_date < ?", Date.today)
                 .map { |inv| { id: inv.id, due_date: inv.due_date.to_s } }
  end
end

# Use it
agent = Fosm::InvoiceAgent.build_agent
agent.run("Mark all sent invoices older than 30 days as overdue")

# Or use a different model
agent = Fosm::InvoiceAgent.build_agent(model: "openai/gpt-4o")
agent.run("Pay invoice #42 if it's in the correct state")
```

**Standard tools auto-generated for every FOSM app:**

| Tool | Description |
|---|---|
| `list_invoices` | List records, optionally filtered by state |
| `get_invoice` | Get a record by ID with state + available events |
| `available_events_for_invoice` | What events can fire from current state |
| `transition_history_for_invoice` | Full audit trail for a record |
| `send_invoice_invoice` | Fire the `send_invoice` event (one per lifecycle event) |
| `pay_invoice` | Fire the `pay` event |
| `cancel_invoice` | Fire the `cancel` event |

The agent cannot fire an event that doesn't exist in the lifecycle. Invalid transitions return `{ success: false }` — the machine refuses, not the LLM.

---

## Admin UI

The engine mounts an admin interface at `/fosm/admin` (access controlled by `config.admin_authorize`):

- **Dashboard** — all FOSM apps with state distribution; link to role assignments
- **App detail** — lifecycle definition table, state distribution chart, stuck record detection, and **access control matrix** (read-only view of declared roles and permissions)
- **Role assignments** (`/fosm/admin/roles`) — grant/revoke roles, view declared roles per app, browse immutable access event audit trail; accessible only to `config.admin_authorize` actors
- **Agent explorer** (`/fosm/admin/apps/:slug/agent`) — the auto-generated tool catalog for the app's AI agent, a direct tool tester (no LLM required), and the system prompt injected into agents
- **Agent chat** (`/fosm/admin/apps/:slug/agent/chat`) — live multi-turn chat with the agent; see tool calls, thoughts, and state changes in real time
- **Transition log** — complete audit trail, filterable by app / event / actor (human vs AI agent)
- **Webhooks** — configure HTTP callbacks for any FOSM event (with HMAC-SHA256 signing)
- **Settings** — LLM provider key status, engine configuration overview

---

## Webhooks

Configure via the admin UI at `/fosm/admin/webhooks` or programmatically:

```ruby
Fosm::WebhookSubscription.create!(
  model_class_name: "Fosm::Invoice",
  event_name: "send_invoice",
  url: "https://your-app.com/webhooks/fosm",
  secret_token: "your_signing_secret",
  active: true
)
```

FOSM POSTs a JSON payload to your URL with headers:
- `X-FOSM-Event`: the event name
- `X-FOSM-Record-Type`: the model class name
- `X-FOSM-Signature`: `sha256=HMAC-SHA256(secret_token, payload)` (if secret token set)

---

## Transition log

Every state change is written to `fosm_transition_logs` — an immutable, append-only table. Records cannot be updated or deleted.

```ruby
Fosm::TransitionLog.for_record("Fosm::Invoice", 42).recent
# => [{ event: "send_invoice", from: "draft", to: "sent", actor: "user@example.com", at: "..." }]

Fosm::TransitionLog.for_app(Fosm::Invoice).by_event("pay").count
# => 17
```

---

## Architecture

```
your_rails_app/
  app/
    models/fosm/          ← Your FOSM models (generated)
      invoice.rb
    controllers/fosm/     ← Your FOSM controllers (generated)
      invoice_controller.rb
    views/fosm/           ← Your FOSM views (generated, customizable)
      invoice/
    agents/fosm/          ← Your Gemlings AI agents (generated)
      invoice_agent.rb
  config/
    routes/fosm.rb        ← Route registration (auto-updated by generator)
    initializers/fosm.rb  ← Engine configuration

# Engine provides (from gem):
  app/models/fosm/
    transition_log.rb     ← Shared immutable transition audit trail
    webhook_subscription.rb
    role_assignment.rb    ← RBAC: actor → role → resource
    access_event.rb       ← RBAC: immutable audit log of grants/revokes
  app/controllers/fosm/admin/
    dashboard_controller.rb
    roles_controller.rb   ← Role assignment management (superadmin only)
    ...
  lib/fosm/
    lifecycle.rb          ← The DSL concern (states, events, guards, access)
    lifecycle/
      definition.rb       ← Holds all lifecycle + access metadata
      access_definition.rb ← access{} block: role declarations
      role_definition.rb  ← Individual role with CRUD + event permissions
    current.rb            ← Per-request RBAC cache (one SQL query per actor)
    transition_buffer.rb  ← :buffered log strategy (bulk INSERT thread)
    agent.rb              ← Gemlings base agent
    engine.rb
```

---

## Requirements

- Ruby >= 3.1
- Rails >= 8.1
- Any SQL database supported by Rails (SQLite, PostgreSQL, MySQL)
- `ANTHROPIC_API_KEY` (or another provider key) to use the AI agent chat — see `/fosm/admin/settings` for status

`gemlings` is bundled automatically as a required dependency. No separate configuration needed unless you want to choose a different LLM provider.

---

## Contributing

FOSM is open source and welcomes contributions. See [AGENTS.md](AGENTS.md) for a deep explanation of the design philosophy and how to extend the engine thoughtfully.

## License

FSL-1.1-Apache-2.0 — Copyright 2026 [Abhishek Parolkar](https://parolkar.com) and INLOOP.STUDIO PTE LTD. See [LICENSE](LICENSE) for details.
