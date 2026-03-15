#!/bin/bash
# =============================================================================
# util/setup_and_test.sh — FOSM integration test utility
# =============================================================================
#
# PURPOSE
#   Bootstraps a fresh Rails 8 app with the fosm-rails gem, generates an
#   example Invoice FOSM app (with a full lifecycle), and prints the URLs
#   to verify the result. Use this to confirm the gem works end-to-end
#   after making changes to the fosm-rails source.
#
# PREREQUISITES
#   - Ruby + Rails CLI installed (rails new must be on PATH)
#   - The fosm-rails source checked out locally (this script lives inside it)
#   - Run from a FRESH terminal — not inside another Rails server process,
#     as that causes gem activation conflicts (e.g. sqlite3 version clash)
#
# STEP 1 — Create a minimal Rails 8 app (if you haven't already)
#
#   rails new my-test-app \
#     --skip-git --database=sqlite3 --asset-pipeline=propshaft \
#     --skip-action-mailer --skip-action-mailbox --skip-action-text \
#     --skip-active-storage --skip-action-cable --skip-solid --skip-kamal
#
#   --skip-* drops services not needed for testing (faster bundle install).
#   Use sqlite3 so no external database server is required.
#   Remove stale_when_importmap_changes from ApplicationController if present.
#
# STEP 2 — Run this script
#
#   Option A: from inside the new Rails app directory (most common)
#
#     cd my-test-app
#     bash /path/to/fosm-rails/util/setup_and_test.sh
#
#   Option B: pass the app path as the first argument (run from anywhere)
#
#     bash /path/to/fosm-rails/util/setup_and_test.sh /path/to/my-test-app
#
# WHAT THE SCRIPT DOES (7 steps)
#   [0] bundle add fosm-rails --path <gem-source>   (adds gem to Gemfile)
#   [1] bundle install
#   [2] rails db:create                             (skips if DB already exists)
#   [3] rails generate fosm:app invoice             (scaffolds model/controller/views)
#   [4] rails fosm:install:migrations + db:migrate  (creates FOSM tables)
#   [5] Injects engine mount into routes.rb and writes config/initializers/fosm.rb
#   [6] Replaces the lifecycle stub with a complete Invoice lifecycle
#   [7] Injects FOSM agent instructions into CLAUDE.md
#
# AFTER SETUP — start the server and verify:
#
#   bin/rails server -p 3001
#
#   http://localhost:3001/fosm/apps/invoices   Invoice list, create, fire events
#   http://localhost:3001/fosm/admin           Admin: state distribution, transition log
#
# IDEMPOTENCY
#   The script is safe to re-run. Routes and initializer writes check for
#   existing content before modifying files, and db:create tolerates an
#   already-existing database.
# =============================================================================

set -e

# Resolve paths: gem is one level above this script; app is cwd (or $1 if provided)
FOSM_GEM_PATH="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$(pwd)}"
cd "$APP_DIR"

echo "=== FOSM Fresh Rails 8 App Test ==="
echo "  gem: $FOSM_GEM_PATH"
echo "  app: $APP_DIR"

echo ""
echo "[0/6] Adding required gems..."
bundle add fosm-rails --path "$FOSM_GEM_PATH"

echo ""
echo "[1/6] bundle install..."
bundle install

echo ""
echo "[2/6] Create database (if not already exists)..."
bin/rails db:create 2>&1 | grep -v "already exists" || true

echo ""
echo "[3/6] Generate fosm:app invoice..."
bin/rails generate fosm:app invoice \
  --fields "name:string amount:decimal client_name:string due_date:date" \
  --states "draft,sent,paid,overdue,cancelled"

echo ""
echo "[4/6] Install FOSM migrations and migrate..."
bin/rails fosm:install:migrations
bin/rails db:migrate

echo ""
echo "[5/6] Mount engine and configure..."

# Mount engine in routes (if not already there)
if ! grep -q "Fosm::Engine" config/routes.rb; then
  python3 - << 'PYTHON'
f = "config/routes.rb"
with open(f) as fp: content = fp.read()
mount_line = '\n  mount Fosm::Engine => "/fosm"\n  draw :fosm if File.exist?(Rails.root.join("config/routes/fosm.rb"))\n'
content = content.replace("Rails.application.routes.draw do", "Rails.application.routes.draw do" + mount_line)
with open(f, 'w') as fp: fp.write(content)
print("  config/routes.rb updated")
PYTHON
fi

# Create initializer (if not already there)
if [ ! -f config/initializers/fosm.rb ]; then
  cat > config/initializers/fosm.rb << 'INITIALIZER'
Fosm.configure do |config|
  config.base_controller = "ApplicationController"

  # Open access for testing — lock down in production
  config.admin_authorize     = -> {}
  config.app_authorize       = ->(_level) {}
  config.current_user_method = -> { nil }
end
INITIALIZER
  echo "  config/initializers/fosm.rb created"
fi

echo ""
echo "[6/6] Add lifecycle to invoice model..."
python3 - << 'PYTHON'
import re
f = "app/models/fosm/invoice.rb"
with open(f) as fp:
    content = fp.read()
lifecycle = """    lifecycle do
      state :draft,     initial: true
      state :sent
      state :paid,      terminal: true
      state :overdue
      state :cancelled, terminal: true

      event :send_invoice, from: :draft,            to: :sent
      event :pay,          from: [:sent, :overdue], to: :paid
      event :mark_overdue, from: :sent,             to: :overdue
      event :cancel,       from: [:draft, :sent],   to: :cancelled

      guard :has_amount, on: :send_invoice do |invoice|
        invoice.amount.present? && invoice.amount > 0
      end

      guard :has_client, on: :send_invoice do |invoice|
        invoice.client_name.present?
      end

      side_effect :log_payment, on: :pay do |invoice, transition|
        Rails.logger.info("[FOSM] Invoice paid")
      end
    end"""
content = re.sub(r'    lifecycle do.*?    end', lifecycle, content, flags=re.DOTALL)
with open(f, 'w') as fp:
    fp.write(content)
print("  lifecycle added to app/models/fosm/invoice.rb")
PYTHON

echo ""
echo "[7/7] Injecting FOSM agent instructions into CLAUDE.md..."

SENTINEL="<!-- fosm:agent-instructions -->"
CLAUDE_MD="$APP_DIR/CLAUDE.md"
GEM_PATH=$(cd "$FOSM_GEM_PATH" && pwd)
AGENTS_MD="$GEM_PATH/AGENTS.md"

if [ -f "$CLAUDE_MD" ] && grep -q "$SENTINEL" "$CLAUDE_MD"; then
  echo "  CLAUDE.md already has FOSM agent instructions (skipped)"
else
  cat >> "$CLAUDE_MD" << FOSM_INSTRUCTIONS

$SENTINEL
## FOSM (fosm-rails)

This project uses \`fosm-rails\` — a Finite Object State Machine engine.
When the user asks to build, extend, or modify features involving state machines,
lifecycles, FOSM, or any code under \`app/models/fosm/\`, \`app/controllers/fosm/\`,
or \`app/agents/fosm/\`, you **must** read and follow the instructions in:

\`$AGENTS_MD\`
FOSM_INSTRUCTIONS
  echo "  CLAUDE.md updated with FOSM agent instructions"
fi

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Start the server:   bin/rails server -p 3001"
echo ""
echo "Test URLs:"
echo "  http://localhost:3001/fosm/apps/invoices   <- Invoice CRUD + state machine"
echo "  http://localhost:3001/fosm/admin           <- FOSM Admin dashboard"
