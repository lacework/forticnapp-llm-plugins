#!/bin/bash
# test-stop.sh — Unit tests for stop.sh mode-aware logic
# Usage: bash tests/test-stop.sh

set -euo pipefail

PASS=0
FAIL=0
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/stop.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== stop.sh Tests ==="
echo ""

# Helper: create a temp HOME with a given config
setup_config() {
  local temp_home
  temp_home=$(mktemp -d)
  mkdir -p "$temp_home/.lacework/plugins"
  cat > "$temp_home/.lacework/plugins/code-security.json" << EOF
$1
EOF
  echo "$temp_home"
}

# --- Post-task mode proceeds past mode check ---
echo "--- Post-task mode proceeds past mode check ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
# No transcript_path provided, so it will exit 0 after the transcript check
OUTPUT=$(echo '{"cwd":"/tmp","session_id":"test-123"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "post-task mode proceeds (exits 0 at missing transcript)"
else
  fail "post-task mode should exit 0 at missing transcript, got $EXIT"
fi
rm -rf "$TEMP_HOME"

# --- Pre-commit mode exits immediately ---
echo "--- Pre-commit mode exits immediately ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "pre-commit",
    "enabled": true
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp","session_id":"test-456"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "pre-commit mode exits 0 immediately"
else
  fail "pre-commit mode should exit 0 immediately, got $EXIT"
fi
rm -rf "$TEMP_HOME"

# --- Disabled exits immediately ---
echo "--- Disabled exits immediately ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": false
  }
}')
OUTPUT=$(echo '{"cwd":"/tmp","session_id":"test-789"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "disabled config exits 0 immediately"
else
  fail "disabled config should exit 0 immediately, got $EXIT"
fi
rm -rf "$TEMP_HOME"

# --- No changed files exits 0 ---
echo "--- No changed files exits 0 ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
# Create a transcript file with no Write/Edit tool uses
TRANSCRIPT_FILE=$(mktemp)
echo '{"message":{"content":[{"type":"text","text":"hello"}]}}' > "$TRANSCRIPT_FILE"
OUTPUT=$(echo "{\"cwd\":\"/tmp\",\"session_id\":\"test-empty\",\"transcript_path\":\"$TRANSCRIPT_FILE\"}" | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "no changed files exits 0"
else
  fail "no changed files should exit 0, got $EXIT"
fi
rm -f "$TRANSCRIPT_FILE"
rm -rf "$TEMP_HOME"

# --- Parallel execution structure ---
echo ""
echo "--- Parallel execution structure ---"
if grep -qF 'PIDS+=($!)' "$HOOK"; then
  pass "PIDs array used for parallel tracking"
else
  fail "PIDs array not found — parallel execution may not work"
fi
if grep -q 'for PID in' "$HOOK" && grep -q 'wait' "$HOOK"; then
  pass "wait loop exists for parallel process collection"
else
  fail "wait loop missing — parallel processes may not be collected"
fi

# --- Exit code 2 present ---
echo ""
echo "--- Exit code behavior ---"
if grep -q 'exit 2' "$HOOK"; then
  pass "exit 2 present for critical/high findings"
else
  fail "exit 2 missing"
fi

# --- Temp cleanup present ---
echo ""
echo "--- Temporary file cleanup ---"
if grep -q "trap.*EXIT" "$HOOK"; then
  pass "trap EXIT cleanup present"
else
  fail "trap EXIT cleanup missing — tmp files may leak"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
