#!/bin/bash
# =============================================================================
# util/test_agent_injection.sh — Verify FOSM agent instruction injection
# =============================================================================
#
# Tests the CLAUDE.md injection logic used by both the Rails generator
# and the setup script. Runs entirely in a temp directory — no side effects.
#
# Usage:
#   bash util/test_agent_injection.sh
#
# =============================================================================

set -e

FOSM_GEM_PATH="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_MD="$FOSM_GEM_PATH/AGENTS.md"
SENTINEL="<!-- fosm:agent-instructions -->"
PASS=0
FAIL=0
TESTS=0

# --- helpers ----------------------------------------------------------------

assert() {
  local description="$1"
  local condition="$2"
  TESTS=$((TESTS + 1))
  if eval "$condition"; then
    echo "  PASS: $description"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $description"
    FAIL=$((FAIL + 1))
  fi
}

inject_fosm_section() {
  local target="$1"
  if [ -f "$target" ] && grep -q "$SENTINEL" "$target"; then
    return 1  # already present
  fi
  cat >> "$target" << FOSM_INSTRUCTIONS

$SENTINEL
## FOSM (fosm-rails)

This project uses \`fosm-rails\` — a Finite Object State Machine engine.
When the user asks to build, extend, or modify features involving state machines,
lifecycles, FOSM, or any code under \`app/models/fosm/\`, \`app/controllers/fosm/\`,
or \`app/agents/fosm/\`, you **must** read and follow the instructions in:

\`$AGENTS_MD\`
FOSM_INSTRUCTIONS
  return 0
}

# --- setup ------------------------------------------------------------------

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "=== FOSM Agent Injection Tests ==="
echo "  gem path: $FOSM_GEM_PATH"
echo "  temp dir: $TMPDIR"
echo ""

# --- Test 1: AGENTS.md exists in gem ---------------------------------------

echo "Test 1: AGENTS.md exists in gem"
assert "AGENTS.md file exists" "[ -f '$AGENTS_MD' ]"
assert "AGENTS.md is non-empty" "[ -s '$AGENTS_MD' ]"
echo ""

# --- Test 2: Inject into existing CLAUDE.md ---------------------------------

echo "Test 2: Inject into existing CLAUDE.md"
echo "# My Project" > "$TMPDIR/CLAUDE.md"
echo "Some existing content." >> "$TMPDIR/CLAUDE.md"

inject_fosm_section "$TMPDIR/CLAUDE.md"

assert "Sentinel comment present" "grep -q '$SENTINEL' '$TMPDIR/CLAUDE.md'"
assert "FOSM heading present" "grep -q '## FOSM (fosm-rails)' '$TMPDIR/CLAUDE.md'"
assert "AGENTS.md path referenced" "grep -q 'AGENTS.md' '$TMPDIR/CLAUDE.md'"
assert "Points to gem path" "grep -q '$FOSM_GEM_PATH' '$TMPDIR/CLAUDE.md'"
assert "Original content preserved" "grep -q '# My Project' '$TMPDIR/CLAUDE.md'"
echo ""

# --- Test 3: Injected section is minimal (no rules duplicated) --------------

echo "Test 3: Minimal injection (no duplicated rules)"
INJECTED_LINES=$(sed -n "/$SENTINEL/,\$p" "$TMPDIR/CLAUDE.md" | wc -l | tr -d ' ')
assert "Injected section is ≤ 10 lines" "[ '$INJECTED_LINES' -le 10 ]"
assert "No fire! rule duplicated" "! grep -q 'ONLY way to change state' '$TMPDIR/CLAUDE.md'"
assert "No guards rule duplicated" "! grep -q 'Guards are pure' '$TMPDIR/CLAUDE.md'"
echo ""

# --- Test 4: Idempotency — second injection is a no-op ---------------------

echo "Test 4: Idempotency"
LINE_COUNT_BEFORE=$(wc -l < "$TMPDIR/CLAUDE.md")

inject_fosm_section "$TMPDIR/CLAUDE.md" || true  # returns 1 = already present

LINE_COUNT_AFTER=$(wc -l < "$TMPDIR/CLAUDE.md")
SENTINEL_COUNT=$(grep -c "$SENTINEL" "$TMPDIR/CLAUDE.md")

assert "Line count unchanged" "[ '$LINE_COUNT_BEFORE' = '$LINE_COUNT_AFTER' ]"
assert "Sentinel appears exactly once" "[ '$SENTINEL_COUNT' = '1' ]"
echo ""

# --- Test 5: Inject when CLAUDE.md does not exist ---------------------------

echo "Test 5: Create CLAUDE.md when missing"
NEW_FILE="$TMPDIR/subdir/CLAUDE.md"
mkdir -p "$TMPDIR/subdir"

inject_fosm_section "$NEW_FILE"

assert "CLAUDE.md created" "[ -f '$NEW_FILE' ]"
assert "Sentinel present in new file" "grep -q '$SENTINEL' '$NEW_FILE'"
assert "FOSM heading present in new file" "grep -q '## FOSM (fosm-rails)' '$NEW_FILE'"
echo ""

# --- Summary ----------------------------------------------------------------

echo "=== Results: $PASS/$TESTS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
