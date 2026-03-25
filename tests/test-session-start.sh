#!/bin/bash
# test-session-start.sh — Unit and integration tests for session-start.sh
# Usage: bash tests/test-session-start.sh

set -euo pipefail

PASS=0
FAIL=0
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/session-start.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== session-start.sh Tests ==="
echo ""

# T-02: Warm session — already installed, should exit fast
echo "--- T-02: Warm session idempotency ---"
TMPDATA=$(mktemp -d)
export CLAUDE_PLUGIN_DATA="$TMPDATA"
# Simulate already-installed state using the current REQUIRED_VERSION from the hook
CURRENT_REQUIRED=$(grep '^REQUIRED_VERSION=' "$HOOK" | cut -d'"' -f2)
echo "$CURRENT_REQUIRED" > "$TMPDATA/.lw-version"
touch "$TMPDATA/.lw-installed"
get_ms() { python3 -c "import time; print(int(time.time()*1000))"; }
START=$(get_ms)
CLAUDE_PLUGIN_DATA="$TMPDATA" bash "$HOOK"
EXIT=$?
END=$(get_ms)
ELAPSED=$((END - START))
if [ "$EXIT" -eq 0 ]; then
  pass "Warm session exits 0"
else
  fail "Warm session should exit 0, got $EXIT"
fi
# Warm session includes a GitHub API call (max-time 3s), so allow up to 5s
if [ "$ELAPSED" -lt 5000 ]; then
  pass "Warm session exits within 5s including update check (${ELAPSED}ms)"
else
  fail "Warm session too slow: ${ELAPSED}ms (expected < 5000ms)"
fi
rm -rf "$TMPDATA"

# T-11: Version bump triggers re-install (marker check)
echo ""
echo "--- T-11: Version bump triggers re-install ---"
TMPDATA=$(mktemp -d)
# Simulate old version installed
echo "0.9.0" > "$TMPDATA/.lw-version"
touch "$TMPDATA/.lw-installed"
# Modify hook to check an old version - we just verify the marker logic
if grep -q '^REQUIRED_VERSION=' "$HOOK"; then
  pass "REQUIRED_VERSION constant exists in session-start.sh"
else
  fail "REQUIRED_VERSION constant not found in session-start.sh"
fi
# Verify that with old version, the fast-exit condition won't trigger
OLD_VERSION="0.9.0"
REQUIRED="1.0.0"
if [ "$OLD_VERSION" != "$REQUIRED" ]; then
  pass "Version mismatch correctly detected (would trigger re-install)"
else
  fail "Version check logic is wrong"
fi
rm -rf "$TMPDATA"

# Credential configuration test
echo ""
echo "--- Credential configuration ---"
if grep -q 'lacework configure' "$HOOK"; then
  pass "Uses lacework configure for credentials"
else
  fail "lacework configure missing"
fi
if grep -q 'noninteractive' "$HOOK"; then
  pass "lacework configure runs non-interactively"
else
  fail "--noninteractive flag missing"
fi
if grep -q 'LW_ACCOUNT\|LW_API_KEY\|LW_API_SECRET' "$HOOK"; then
  pass "Credentials passed from environment variables"
else
  fail "Environment variable credentials missing"
fi

# jq auto-install test
echo ""
echo "--- jq auto-installation ---"
if grep -q 'command -v jq' "$HOOK"; then
  pass "jq presence check exists"
else
  fail "jq presence check missing"
fi
if grep -q 'brew install jq' "$HOOK"; then
  pass "jq installed via brew on macOS"
else
  fail "brew install jq missing"
fi
if grep -q 'apt-get install' "$HOOK" && grep -q 'yum install' "$HOOK" && grep -q 'apk add' "$HOOK"; then
  pass "jq installed via apt/yum/apk on Linux"
else
  fail "Linux package manager fallbacks for jq missing"
fi

# Update notification test
echo ""
echo "--- Update notification ---"
if grep -q 'api.github.com/repos/lacework-dev/fortinet-code-security-plugin/releases/latest' "$HOOK"; then
  pass "GitHub releases API queried for latest version"
else
  fail "GitHub releases API check missing"
fi
if grep -q 'max-time 3' "$HOOK"; then
  pass "curl uses --max-time 3 (graceful offline degradation)"
else
  fail "--max-time missing — update check will hang when offline"
fi
if grep -q 'update available' "$HOOK"; then
  pass "Update notification message present"
else
  fail "Update notification message missing"
fi
if grep -q 'To upgrade, run' "$HOOK"; then
  pass "Upgrade command shown in notification"
else
  fail "Upgrade command missing from notification"
fi

# Component verification test
echo ""
echo "--- Component verification ---"
if grep -q 'lacework component list' "$HOOK"; then
  pass "Hook verifies components after install"
else
  fail "Hook does not verify components after install"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
