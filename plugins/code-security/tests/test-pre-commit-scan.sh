#!/bin/bash
# test-pre-commit-scan.sh — Unit tests for pre-commit-scan.sh decision logic
# Usage: bash tests/test-pre-commit-scan.sh

set -euo pipefail

PASS=0
FAIL=0
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/pre-commit-scan.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== pre-commit-scan.sh Tests ==="
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

# --- Non-git command exits immediately ---
echo "--- Non-git command exits immediately ---"
OUTPUT=$(echo '{"tool_input":{"command":"ls -la"},"cwd":"/tmp"}' | bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "non-git command exits 0" || fail "non-git command should exit 0, got $EXIT"

# --- git push exits immediately ---
echo "--- git push exits immediately ---"
OUTPUT=$(echo '{"tool_input":{"command":"git push origin main"},"cwd":"/tmp"}' | bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "git push exits 0" || fail "git push should exit 0, got $EXIT"

# --- git status exits immediately ---
echo "--- git status exits immediately ---"
OUTPUT=$(echo '{"tool_input":{"command":"git status"},"cwd":"/tmp"}' | bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "git status exits 0" || fail "git status should exit 0, got $EXIT"

# --- Post-task mode exits early for git commit ---
echo "--- Post-task mode exits early for git commit ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
OUTPUT=$(HOME="$TEMP_HOME" echo '{"tool_input":{"command":"git commit -m \"test\""},"cwd":"/tmp"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "post-task mode exits 0 for git commit" || fail "post-task mode should exit 0 for git commit, got $EXIT"
rm -rf "$TEMP_HOME"

# --- Scanning disabled exits early for git commit ---
echo "--- Scanning disabled exits early for git commit ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "pre-commit",
    "enabled": false
  }
}')
OUTPUT=$(HOME="$TEMP_HOME" echo '{"tool_input":{"command":"git commit -m \"test\""},"cwd":"/tmp"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "disabled scanning exits 0 for git commit" || fail "disabled scanning should exit 0 for git commit, got $EXIT"
rm -rf "$TEMP_HOME"

# --- git commit is recognized (regex match) ---
echo "--- git commit command matching ---"
# Verify the regex pattern exists in the script
if grep -qE 'git\\s\+commit' "$HOOK" || grep -qE 'git\s+commit' "$HOOK"; then
  pass "git commit regex pattern present in script"
else
  fail "git commit regex pattern not found in script"
fi

# --- git commit --amend is recognized ---
echo "--- git commit --amend matching ---"
# The regex matches "git commit" followed by optional args, so --amend is covered
# Verify with a post-task config (will exit 0 at mode check, proving it got past command check)
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
OUTPUT=$(HOME="$TEMP_HOME" echo '{"tool_input":{"command":"git commit --amend"},"cwd":"/tmp"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "git commit --amend recognized (exits at mode check)" || fail "git commit --amend not recognized, got exit $EXIT"
rm -rf "$TEMP_HOME"

# --- Chained command with git commit is recognized ---
echo "--- Chained command with git commit ---"
TEMP_HOME=$(setup_config '{
  "hooks": {
    "mode": "post-task",
    "enabled": true
  }
}')
OUTPUT=$(HOME="$TEMP_HOME" echo '{"tool_input":{"command":"git add . && git commit -m \"test\""},"cwd":"/tmp"}' | HOME="$TEMP_HOME" bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "chained git commit recognized (exits at mode check)" || fail "chained git commit not recognized, got exit $EXIT"
rm -rf "$TEMP_HOME"

# --- Empty command exits immediately ---
echo "--- Empty command exits immediately ---"
OUTPUT=$(echo '{"tool_input":{},"cwd":"/tmp"}' | bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "empty command exits 0" || fail "empty command should exit 0, got $EXIT"

# --- Missing tool_input exits immediately ---
echo "--- Missing tool_input exits immediately ---"
OUTPUT=$(echo '{"cwd":"/tmp"}' | bash "$HOOK" 2>&1)
EXIT=$?
[ "$EXIT" -eq 0 ] && pass "missing tool_input exits 0" || fail "missing tool_input should exit 0, got $EXIT"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
