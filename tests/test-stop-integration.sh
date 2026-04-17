#!/bin/bash
# test-stop-integration.sh — Integration test for stop.sh with real Lacework scans
# Requires: Lacework CLI installed and configured (run /fortinet:cli-setup first)
# Usage: bash tests/test-stop-integration.sh

set -uo pipefail

PASS=0
FAIL=0
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/scripts/stop.sh"
FIXTURE_DIR="$PLUGIN_ROOT/tests/fixtures"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== stop.sh Integration Tests ==="
echo ""

# Check prerequisites
if ! command -v lacework &>/dev/null; then
  echo "SKIP: Lacework CLI not installed. Run /fortinet:cli-setup first."
  exit 0
fi

# Clean scan markers so hook doesn't skip
rm -rf "$HOME/.lacework/scan-markers"

# Build a JSONL transcript file that references the vulnerable.tf fixture
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TRANSCRIPT="$TMPDIR/transcript.jsonl"
cat > "$TRANSCRIPT" <<EOF
{"message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"$FIXTURE_DIR/vulnerable.tf"}}]}}
EOF

# Build the hook input JSON with transcript_path and cwd
HOOK_INPUT=$(jq -n \
  --arg tp "$TRANSCRIPT" \
  --arg cwd "$PLUGIN_ROOT" \
  '{transcript_path: $tp, cwd: $cwd}')

echo "--- T-INT-01: Changed file with findings — blocks with exit 2 ---"
OUTPUT_STDERR="$TMPDIR/stderr.txt"
OUTPUT_STDOUT="$TMPDIR/stdout.txt"
echo "$HOOK_INPUT" | bash "$HOOK" >"$OUTPUT_STDOUT" 2>"$OUTPUT_STDERR"
EXIT=$?

STDERR_OUT=$(cat "$OUTPUT_STDERR")

# Should exit 2 (critical/high findings in changed files)
if [ "$EXIT" -eq 2 ]; then
  pass "Exit code is 2 (critical/high findings in changed files)"
else
  fail "Expected exit code 2, got $EXIT"
fi

# Should show "Issues in your changed files"
if echo "$STDERR_OUT" | grep -q "Issues in your changed files"; then
  pass "Output shows 'Issues in your changed files' section"
else
  fail "Missing 'Issues in your changed files' section"
fi

# Should list the scanned file
if echo "$STDERR_OUT" | grep -q "vulnerable.tf"; then
  pass "Output lists scanned file (vulnerable.tf)"
else
  fail "Missing scanned file in output"
fi

# Should contain Exception ID for IaC findings
if echo "$STDERR_OUT" | grep -q "Exception ID:.*lacework-iac-"; then
  pass "IaC findings include Exception ID with policy ID"
else
  fail "IaC findings missing Exception ID"
fi

# Should contain the codesec.yaml internal instructions
if echo "$STDERR_OUT" | grep -q "codesec.yaml"; then
  pass "Output contains codesec.yaml reference"
else
  fail "Output missing codesec.yaml instructions"
fi

# Should contain exception instructions for IaC and SCA
if echo "$STDERR_OUT" | grep -q "default.iac.scan.exceptions"; then
  pass "Output contains IaC exception instructions"
else
  fail "Output missing IaC exception instructions"
fi

if echo "$STDERR_OUT" | grep -q "default.sca.scan.exceptions"; then
  pass "Output contains SCA exception instructions"
else
  fail "Output missing SCA exception instructions"
fi

# Should require user approval
if echo "$STDERR_OUT" | grep -q "user explicitly approves"; then
  pass "Output instructs Claude to get user approval before adding exceptions"
else
  fail "Output missing user-approval instruction"
fi

# Should warn not to auto-suppress
if echo "$STDERR_OUT" | grep -q "Do not auto-suppress"; then
  pass "Output contains auto-suppress warning"
else
  fail "Output missing auto-suppress warning"
fi

# Verify specific known policy IDs from our fixture appear
echo ""
echo "--- T-INT-02: Known fixture findings are reported ---"

if echo "$STDERR_OUT" | grep -q "lacework-iac-aws-security-3"; then
  pass "Critical finding: ingress /0 rule (lacework-iac-aws-security-3)"
else
  fail "Missing expected critical finding lacework-iac-aws-security-3"
fi

if echo "$STDERR_OUT" | grep -q "lacework-iac-aws-storage-1"; then
  pass "High finding: S3 public access (lacework-iac-aws-storage-1)"
else
  fail "Missing expected high finding lacework-iac-aws-storage-1"
fi

if echo "$STDERR_OUT" | grep -q "lacework-iac-aws-security-4"; then
  pass "High finding: egress /0 rule (lacework-iac-aws-security-4)"
else
  fail "Missing expected high finding lacework-iac-aws-security-4"
fi

# T-INT-03: codesec.yaml existence detection
echo ""
echo "--- T-INT-03: codesec.yaml existence detection ---"

rm -rf "$HOME/.lacework/scan-markers"

mkdir -p "$PLUGIN_ROOT/.lacework"
touch "$PLUGIN_ROOT/.lacework/codesec.yaml"

OUTPUT_STDERR2="$TMPDIR/stderr2.txt"
echo "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>"$OUTPUT_STDERR2"

if grep -q "already exists" "$OUTPUT_STDERR2"; then
  pass "Detects existing codesec.yaml and says 'already exists'"
else
  fail "Does not detect existing codesec.yaml"
fi

rm -f "$PLUGIN_ROOT/.lacework/codesec.yaml"
rmdir "$PLUGIN_ROOT/.lacework" 2>/dev/null || true

rm -rf "$HOME/.lacework/scan-markers"
mkdir -p "$HOME/.lacework/scan-markers"

OUTPUT_STDERR3="$TMPDIR/stderr3.txt"
echo "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>"$OUTPUT_STDERR3"

if grep -q "does not exist yet" "$OUTPUT_STDERR3"; then
  pass "Reports codesec.yaml does not exist when absent"
else
  fail "Does not report missing codesec.yaml"
fi

# T-INT-04: Changed file with NO findings — should exit 0 and show FYI
echo ""
echo "--- T-INT-04: Changed file with no findings — non-blocking ---"

rm -rf "$HOME/.lacework/scan-markers"
mkdir -p "$HOME/.lacework/scan-markers"

# Create transcript that only edits README.md (no security findings in it)
TRANSCRIPT_CLEAN="$TMPDIR/transcript_clean.jsonl"
cat > "$TRANSCRIPT_CLEAN" <<EOF
{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"$PLUGIN_ROOT/README.md"}}]}}
EOF

HOOK_INPUT_CLEAN=$(jq -n \
  --arg tp "$TRANSCRIPT_CLEAN" \
  --arg cwd "$PLUGIN_ROOT" \
  '{transcript_path: $tp, cwd: $cwd}')

OUTPUT_STDERR4="$TMPDIR/stderr4.txt"
echo "$HOOK_INPUT_CLEAN" | bash "$HOOK" >/dev/null 2>"$OUTPUT_STDERR4"
EXIT_CLEAN=$?

STDERR_CLEAN=$(cat "$OUTPUT_STDERR4")

if [ "$EXIT_CLEAN" -eq 0 ]; then
  pass "Exit code is 0 (no findings in changed files — non-blocking)"
else
  fail "Expected exit code 0, got $EXIT_CLEAN"
fi

if echo "$STDERR_CLEAN" | grep -q "No security issues found in your changed files"; then
  pass "Output says no issues in changed files"
else
  fail "Missing 'No security issues' message"
fi

if echo "$STDERR_CLEAN" | grep -q "pre-existing"; then
  pass "Output mentions pre-existing issues as FYI"
else
  fail "Missing pre-existing issues FYI"
fi

if echo "$STDERR_CLEAN" | grep -q "fortinet:code-review"; then
  pass "Output suggests /fortinet:code-review for full report"
else
  fail "Missing /fortinet:code-review suggestion"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -eq 0 ]; then
  echo "All integration tests passed!"
  exit 0
else
  echo ""
  echo "--- Full hook output for debugging ---"
  cat "$OUTPUT_STDERR"
  exit 1
fi
