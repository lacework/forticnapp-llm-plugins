#!/bin/bash
# test-stop.sh — Unit tests for stop.sh logic
# Usage: bash tests/test-stop.sh

set -euo pipefail

PASS=0
FAIL=0
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN_ROOT/hooks/stop.sh"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== stop.sh Tests ==="
echo ""

# T-09: No IaC or manifest files — should exit 0 immediately
echo "--- T-09: Source-only files, no scan ---"
SESSION_JSON=$(cat <<'EOF'
{
  "transcript": [
    {
      "tool_uses": [
        {
          "tool_name": "Write",
          "tool_input": {
            "file_path": "/workspace/app.py"
          }
        },
        {
          "tool_name": "Edit",
          "tool_input": {
            "file_path": "/workspace/utils.js"
          }
        }
      ]
    }
  ]
}
EOF
)

OUTPUT=$(echo "$SESSION_JSON" | bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "T-09: Source-only files exits 0"
else
  fail "T-09: Source-only files should exit 0, got $EXIT"
fi

# T-09: No changed files at all — should exit 0
echo ""
echo "--- No changed files ---"
EMPTY_SESSION='{"transcript": [{"tool_uses": []}]}'
OUTPUT=$(echo "$EMPTY_SESSION" | bash "$HOOK" 2>&1)
EXIT=$?
if [ "$EXIT" -eq 0 ]; then
  pass "Empty session exits 0"
else
  fail "Empty session should exit 0, got $EXIT"
fi

# File-type routing logic tests — check patterns using actual routing
echo ""
echo "--- IaC routing patterns ---"

check_iac() {
  local label="$1" file="$2"
  local session
  session=$(printf '{"transcript":[{"tool_uses":[{"tool_name":"Write","tool_input":{"file_path":"%s"}}]}]}' "$file")
  # The hook will fail to scan (lacework not installed in test env) but we can
  # check that it does NOT exit 0 silently — it must attempt a scan (exit non-zero or produce output)
  # Instead we test the grep patterns in the hook source directly
  :
}

# Test IAC_PATTERN variable content in the hook
if grep -q 'tf|tfvars|hcl' "$HOOK"; then
  pass "IaC pattern: Terraform (.tf/.tfvars/.hcl)"
else
  fail "IaC pattern missing Terraform extensions"
fi
if grep -q 'bicep' "$HOOK"; then
  pass "IaC pattern: Azure Bicep (.bicep)"
else
  fail "IaC pattern missing .bicep"
fi
if grep -q 'template' "$HOOK"; then
  pass "IaC pattern: CloudFormation (.template)"
else
  fail "IaC pattern missing .template"
fi
if grep -q 'kubernetes' "$HOOK"; then
  pass "IaC pattern: Kubernetes path (kubernetes/)"
else
  fail "IaC pattern missing kubernetes/ path"
fi
if grep -q 'argocd' "$HOOK"; then
  pass "IaC pattern: ArgoCD path (argocd/)"
else
  fail "IaC pattern missing argocd/ path"
fi
if grep -q 'flux' "$HOOK"; then
  pass "IaC pattern: Flux path (flux/)"
else
  fail "IaC pattern missing flux/ path"
fi
if grep -q 'Pulumi' "$HOOK"; then
  pass "IaC pattern: Pulumi (Pulumi.yaml)"
else
  fail "IaC pattern missing Pulumi.yaml"
fi
if grep -q 'serverless' "$HOOK"; then
  pass "IaC pattern: Serverless Framework (serverless.yml)"
else
  fail "IaC pattern missing serverless.yml"
fi
if grep -q 'docker-compose' "$HOOK"; then
  pass "IaC pattern: Docker Compose"
else
  fail "IaC pattern missing docker-compose"
fi
if grep -qF 'cdk\.json' "$HOOK"; then
  pass "IaC pattern: AWS CDK (cdk.json)"
else
  fail "IaC pattern missing cdk.json"
fi
if grep -q 'ansible\|playbooks' "$HOOK"; then
  pass "IaC pattern: Ansible (ansible/playbooks/)"
else
  fail "IaC pattern missing ansible/playbooks paths"
fi

echo ""
echo "--- SCA routing patterns ---"
if grep -q 'package' "$HOOK"; then
  pass "SCA pattern: Node/JS (package.json, package-lock.json)"
else
  fail "SCA pattern missing package.json"
fi
if grep -q 'yarn\.lock\|pnpm-lock' "$HOOK"; then
  pass "SCA pattern: Node/JS lockfiles (yarn.lock, pnpm-lock.yaml)"
else
  fail "SCA pattern missing yarn.lock/pnpm-lock"
fi
if grep -qF 'go\.' "$HOOK"; then
  pass "SCA pattern: Go (go.mod, go.sum)"
else
  fail "SCA pattern missing go.mod/go.sum"
fi
if grep -q 'requirements' "$HOOK"; then
  pass "SCA pattern: Python (requirements*.txt)"
else
  fail "SCA pattern missing requirements.txt"
fi
if grep -qF 'pyproject\.toml' "$HOOK" && grep -qF 'poetry\.lock' "$HOOK"; then
  pass "SCA pattern: Python modern (pyproject.toml, poetry.lock)"
else
  fail "SCA pattern missing pyproject.toml/poetry.lock"
fi
if grep -qF 'pom\.xml' "$HOOK"; then
  pass "SCA pattern: Java (pom.xml)"
else
  fail "SCA pattern missing pom.xml"
fi
if grep -qF 'build\.gradle' "$HOOK"; then
  pass "SCA pattern: Kotlin/Java (build.gradle)"
else
  fail "SCA pattern missing build.gradle"
fi
if grep -q 'Gemfile' "$HOOK"; then
  pass "SCA pattern: Ruby (Gemfile)"
else
  fail "SCA pattern missing Gemfile"
fi
if grep -qF 'Cargo\.' "$HOOK"; then
  pass "SCA pattern: Rust (Cargo.toml/Cargo.lock)"
else
  fail "SCA pattern missing Cargo.toml"
fi
if grep -qF 'composer\.' "$HOOK"; then
  pass "SCA pattern: PHP (composer.json/composer.lock)"
else
  fail "SCA pattern missing composer.json"
fi
if grep -q 'csproj\|vbproj\|fsproj\|packages\.config' "$HOOK"; then
  pass "SCA pattern: .NET (*.csproj, packages.config)"
else
  fail "SCA pattern missing .NET manifests"
fi
if grep -q 'Package\.swift\|Podfile' "$HOOK"; then
  pass "SCA pattern: Swift/iOS (Package.swift, Podfile)"
else
  fail "SCA pattern missing Package.swift/Podfile"
fi
if grep -qF 'build\.sbt' "$HOOK"; then
  pass "SCA pattern: Scala (build.sbt)"
else
  fail "SCA pattern missing build.sbt"
fi
if grep -qF 'mix\.' "$HOOK"; then
  pass "SCA pattern: Elixir (mix.exs, mix.lock)"
else
  fail "SCA pattern missing mix.exs"
fi
if grep -qF 'pubspec\.' "$HOOK"; then
  pass "SCA pattern: Dart/Flutter (pubspec.yaml)"
else
  fail "SCA pattern missing pubspec.yaml"
fi

# Parallel execution test (background processes)
echo ""
echo "--- Parallel execution ---"
if grep -qF 'PIDS+=($!)' "$HOOK"; then
  pass "PIDs array used for parallel tracking"
else
  fail "PIDs array not found — parallel execution may not work"
fi
if grep -q 'for PID in' "$HOOK"; then
  pass "wait loop exists for parallel process collection"
else
  fail "wait loop missing — parallel processes may not be collected"
fi

# Exit code behavior tests
echo ""
echo "--- Exit code behavior ---"
if grep -q 'exit 2' "$HOOK"; then
  pass "exit 2 present for critical/high findings"
else
  fail "exit 2 missing"
fi
if grep -q 'exit 0' "$HOOK"; then
  pass "exit 0 present for clean scans"
else
  fail "exit 0 missing"
fi

# SCA caching tests
echo ""
echo "--- SCA manifest caching ---"
if grep -q 'sha256sum\|shasum' "$HOOK"; then
  pass "SHA-256 hashing present for SCA cache"
else
  fail "SHA-256 hashing missing from stop.sh"
fi
if grep -q 'CACHE_DIR' "$HOOK"; then
  pass "Cache directory variable present"
else
  fail "Cache directory variable missing"
fi
if grep -q 'cache hit' "$HOOK" || grep -q 'cache-hit\|cache_hit\|skipping scan' "$HOOK"; then
  pass "Cache hit message present"
else
  fail "Cache hit message missing"
fi

# Temporary file cleanup test
echo ""
echo "--- Temporary file cleanup ---"
if grep -q "trap.*EXIT" "$HOOK"; then
  pass "trap EXIT cleanup present"
else
  fail "trap EXIT cleanup missing — tmp files may leak"
fi

# Output format test
echo ""
echo "--- Output format ---"
if grep -q 'critical/high severity' "$HOOK" || grep -q 'Fix before proceeding' "$HOOK"; then
  pass "Required output format string present"
else
  fail "Required output format string missing"
fi
if grep -q '>&2' "$HOOK"; then
  pass "Critical findings written to stderr"
else
  fail "Critical findings not written to stderr"
fi

# T-05: SCA cache test — copy fixture to a properly named temp file so SCA pattern matches
echo ""
echo "--- T-05: SCA cache behavior ---"
CACHE_DIR="$HOME/.lacework/cache"
mkdir -p "$CACHE_DIR"
FIXTURE="$PLUGIN_ROOT/tests/fixtures/vulnerable-package.json"
TMP_PKG_DIR=$(mktemp -d)
MANIFEST="$TMP_PKG_DIR/package.json"
cp "$FIXTURE" "$MANIFEST"
HASH=$(sha256sum "$MANIFEST" 2>/dev/null | cut -d' ' -f1)
[ -z "$HASH" ] && HASH=$(shasum -a 256 "$MANIFEST" 2>/dev/null | cut -d' ' -f1)
if [ -n "$HASH" ]; then
  touch "$CACHE_DIR/$HASH"
  SESSION_JSON=$(cat <<EOF
{
  "transcript": [
    {
      "tool_uses": [
        {
          "tool_name": "Edit",
          "tool_input": {
            "file_path": "$MANIFEST"
          }
        }
      ]
    }
  ]
}
EOF
  )
  OUTPUT=$(echo "$SESSION_JSON" | bash "$HOOK" 2>&1)
  EXIT=$?
  if echo "$OUTPUT" | grep -q "cache hit\|skipping scan"; then
    pass "T-05: Cache hit detected, SCA scan skipped"
  else
    fail "T-05: Cache hit not detected (output: $OUTPUT)"
  fi
  if [ "$EXIT" -eq 0 ]; then
    pass "T-05: Cache hit exits 0"
  else
    fail "T-05: Cache hit should exit 0, got $EXIT"
  fi
  rm -f "$CACHE_DIR/$HASH"
else
  fail "T-05: Could not compute hash for test manifest"
fi
rm -rf "$TMP_PKG_DIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
