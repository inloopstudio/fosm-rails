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
gem "gemlings"  # required for AI agent support
```

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

Configure auth in `config/initializers/fosm.rb`:

```ruby
Fosm.configure do |config|
  # The base controller the FOSM engine inherits from
  config.base_controller = "ApplicationController"

  # Who can access /fosm/admin — should be superadmin only
  config.admin_authorize = -> { redirect_to root_path unless current_user&.superadmin? }

  # How to authorize individual FOSM apps
  config.app_authorize = ->(_level) { authenticate_user! }

  # How to get the current user (for transition log actor tracking)
  config.current_user_method = -> { current_user }

  # Layouts
  config.admin_layout = "admin"    # your admin layout
  config.app_layout   = "application"
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

- **Dashboard** — all FOSM apps with state distribution
- **App detail** — lifecycle definition table, state distribution chart, stuck record detection
- **Transition log** — complete audit trail, filterable by app / event / actor (human vs AI agent)
- **Webhooks** — configure HTTP callbacks for any FOSM event (with HMAC-SHA256 signing)

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
    transition_log.rb     ← Shared audit trail
    webhook_subscription.rb
  app/controllers/fosm/admin/
    dashboard_controller.rb
    ...
  lib/fosm/
    lifecycle.rb          ← The DSL concern
    agent.rb              ← Gemlings base agent
    engine.rb
```

---

## Requirements

- Ruby >= 3.2
- Rails >= 8.1
- PostgreSQL (for JSONB columns in transition log) or adapt migrations for other DBs
- `gemlings` gem (for AI agent support)

---

## Contributing

FOSM is open source and welcomes contributions. See [AGENTS.md](AGENTS.md) for a deep explanation of the design philosophy and how to extend the engine thoughtfully.

## License

FSL-1.1-Apache-2.0 — Copyright 2026 [Abhishek Parolkar](https://parolkar.com) and INLOOP.STUDIO PTE LTD. See [LICENSE](LICENSE) for details.
