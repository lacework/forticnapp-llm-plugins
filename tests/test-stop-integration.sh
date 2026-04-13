#!/bin/bash
# test-stop-integration.sh — Integration test for stop.sh with real Lacework scans
# Requires: Lacework CLI installed and configured (run /fortinet-setup first)
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
  echo "SKIP: Lacework CLI not installed. Run /fortinet-setup first."
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

echo "--- T-INT-01: Hook produces findings with Exception IDs ---"
OUTPUT_STDERR="$TMPDIR/stderr.txt"
OUTPUT_STDOUT="$TMPDIR/stdout.txt"
echo "$HOOK_INPUT" | bash "$HOOK" >"$OUTPUT_STDOUT" 2>"$OUTPUT_STDERR"
EXIT=$?

# Should exit 2 (critical/high findings found)
if [ "$EXIT" -eq 2 ]; then
  pass "Exit code is 2 (critical/high findings detected)"
else
  fail "Expected exit code 2, got $EXIT"
fi

STDERR_OUT=$(cat "$OUTPUT_STDERR")

# Should contain the summary line
if echo "$STDERR_OUT" | grep -q "Critical.*High severity issues"; then
  pass "Summary line present with severity counts"
else
  fail "Summary line missing"
fi

# Should contain Exception ID for IaC findings
if echo "$STDERR_OUT" | grep -q "Exception ID:.*lacework-iac-"; then
  pass "IaC findings include Exception ID with policy ID"
else
  fail "IaC findings missing Exception ID"
fi

# Should contain the codesec.yaml instructions
if echo "$STDERR_OUT" | grep -q "codesec.yaml"; then
  pass "Output contains codesec.yaml reference"
else
  fail "Output missing codesec.yaml instructions"
fi

# Should contain exception instructions for IaC
if echo "$STDERR_OUT" | grep -q "default.iac.scan.exceptions"; then
  pass "Output contains IaC exception instructions"
else
  fail "Output missing IaC exception instructions"
fi

# Should contain exception instructions for SCA
if echo "$STDERR_OUT" | grep -q "default.sca.scan.exceptions"; then
  pass "Output contains SCA exception instructions"
else
  fail "Output missing SCA exception instructions"
fi

# Should tell Claude to ask the user
if echo "$STDERR_OUT" | grep -q "ask the user"; then
  pass "Output instructs Claude to ask user before adding exceptions"
else
  fail "Output missing user-approval instruction"
fi

# Should contain the YAML example block
if echo "$STDERR_OUT" | grep -q "exceptions:"; then
  pass "Output contains YAML example with exceptions field"
else
  fail "Output missing YAML example"
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

# T-INT-03: Test that codesec.yaml existence is detected
echo ""
echo "--- T-INT-03: codesec.yaml existence detection ---"

# Clean markers again for a fresh run
rm -rf "$HOME/.lacework/scan-markers"

# Create a fake .lacework/codesec.yaml
mkdir -p "$PLUGIN_ROOT/.lacework"
touch "$PLUGIN_ROOT/.lacework/codesec.yaml"

OUTPUT_STDERR2="$TMPDIR/stderr2.txt"
echo "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>"$OUTPUT_STDERR2"

if grep -q "already exists" "$OUTPUT_STDERR2"; then
  pass "Detects existing codesec.yaml and says 'already exists'"
else
  fail "Does not detect existing codesec.yaml"
fi

# Clean up the fake codesec.yaml
rm -f "$PLUGIN_ROOT/.lacework/codesec.yaml"
rmdir "$PLUGIN_ROOT/.lacework" 2>/dev/null || true

# Clean markers again and test without codesec.yaml
rm -rf "$HOME/.lacework/scan-markers"

OUTPUT_STDERR3="$TMPDIR/stderr3.txt"
echo "$HOOK_INPUT" | bash "$HOOK" >/dev/null 2>"$OUTPUT_STDERR3"

if grep -q "does not exist yet" "$OUTPUT_STDERR3"; then
  pass "Reports codesec.yaml does not exist when absent"
else
  fail "Does not report missing codesec.yaml"
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
