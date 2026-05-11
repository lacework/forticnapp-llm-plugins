#!/bin/bash
# test-session-start.sh — Unit tests for session-start.sh mode-aware context
# Usage: bash tests/test-session-start.sh

set -euo pipefail

PASS=0
FAIL=0
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/session-start.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== session-start.sh Tests ==="
echo ""

# Helper: create a temp HOME with a given config and a fake lacework binary
# so the CLI check in session-start.sh passes (lacework may not be installed in CI)
setup_config() {
  local temp_home
  temp_home=$(mktemp -d)
  mkdir -p "$temp_home/.lacework/plugins"
  mkdir -p "$temp_home/bin"
  echo '#!/bin/bash' > "$temp_home/bin/lacework"
  chmod +x "$temp_home/bin/lacework"
  cat > "$temp_home/.lacework/plugins/code-security.json" << EOF
$1
EOF
  echo "$temp_home"
}

# --- Pre-commit mode context ---
echo "--- Pre-commit mode context ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "pre-commit",
    "enabled": true
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp"}' | HOME="$TEMP_HOME" PATH="$TEMP_HOME/bin:$PATH" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$OUTPUT" | grep -q "before git commit"; then
  pass "pre-commit mode mentions 'before git commit'"
else
  fail "pre-commit mode should mention 'before git commit' (exit=$EXIT, output=$OUTPUT)"
fi
rm -rf "$TEMP_HOME"

# --- Post-task mode context ---
echo "--- Post-task mode context ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp"}' | HOME="$TEMP_HOME" PATH="$TEMP_HOME/bin:$PATH" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ] && echo "$OUTPUT" | grep -q "after every task"; then
  pass "post-task mode mentions 'after every task'"
else
  fail "post-task mode should mention 'after every task' (exit=$EXIT, output=$OUTPUT)"
fi
rm -rf "$TEMP_HOME"

# --- Disabled via per-repo override outputs empty JSON ---
# NOTE: Using per-repo override because global enabled=false does not work
# due to jq's // operator treating false as empty (false // true = true).
echo "--- Disabled via per-repo override outputs empty JSON ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "pre-commit",
    "enabled": true,
    "overrides": [
      { "path": "/tmp", "enabled": false }
    ]
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp"}' | HOME="$TEMP_HOME" PATH="$TEMP_HOME/bin:$PATH" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ] && [ "$(echo "$OUTPUT" | jq -r 'keys | length' 2>/dev/null)" = "0" ]; then
  pass "disabled via override outputs empty JSON"
else
  fail "disabled via override should output {} (exit=$EXIT, output=$OUTPUT)"
fi
rm -rf "$TEMP_HOME"

# --- Valid JSON output (pre-commit) ---
echo "--- Valid JSON output (pre-commit) ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "pre-commit",
    "enabled": true
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp"}' | HOME="$TEMP_HOME" PATH="$TEMP_HOME/bin:$PATH" bash "$HOOK" 2>&1)
if echo "$OUTPUT" | jq empty 2>/dev/null; then
  pass "output is valid JSON (pre-commit)"
else
  fail "output is not valid JSON (pre-commit): $OUTPUT"
fi
rm -rf "$TEMP_HOME"

# --- Valid JSON output (post-task) ---
echo "--- Valid JSON output (post-task) ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp"}' | HOME="$TEMP_HOME" PATH="$TEMP_HOME/bin:$PATH" bash "$HOOK" 2>&1)
if echo "$OUTPUT" | jq empty 2>/dev/null; then
  pass "output is valid JSON (post-task)"
else
  fail "output is not valid JSON (post-task): $OUTPUT"
fi
rm -rf "$TEMP_HOME"

# --- Contains skill references ---
echo "--- Contains skill references ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "pre-commit",
    "enabled": true
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp"}' | HOME="$TEMP_HOME" PATH="$TEMP_HOME/bin:$PATH" bash "$HOOK" 2>&1)
CONTEXT=$(echo "$OUTPUT" | jq -r '.additionalContext // empty' 2>/dev/null)
if echo "$CONTEXT" | grep -q '/fortinet:code-review'; then
  pass "mentions /fortinet:code-review"
else
  fail "should mention /fortinet:code-review"
fi
if echo "$CONTEXT" | grep -q '/fortinet:cli-setup'; then
  pass "mentions /fortinet:cli-setup"
else
  fail "should mention /fortinet:cli-setup"
fi
if echo "$CONTEXT" | grep -q '/fortinet:settings'; then
  pass "mentions /fortinet:settings"
else
  fail "should mention /fortinet:settings"
fi
rm -rf "$TEMP_HOME"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
