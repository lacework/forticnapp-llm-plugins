#!/bin/bash
# stop.sh — Lacework scan orchestrator
# Fires after every Claude Code task. Routes, scans, reports.

SCAN_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCAN_TMPDIR"' EXIT

SESSION=$(cat)

# Extract changed file paths from session JSON
CHANGED=$(echo "$SESSION" | jq -r '
  .transcript[-1].tool_uses[]?
  | select(.tool_name == "Write" or .tool_name == "Edit"
           or .tool_name == "MultiEdit")
  | .tool_input.file_path // .tool_input.path
' 2>/dev/null | sort -u)

[ -z "$CHANGED" ] && exit 0

# IaC: Terraform/HCL, Azure Bicep, CloudFormation templates, Kubernetes manifests,
#       Helm charts, Pulumi, Serverless Framework, Docker Compose, CDK, Ansible
IAC_PATTERN='\.(tf|tfvars|hcl|bicep|template)$'
IAC_PATTERN+='|(terraform|infra|iac|k8s|kubernetes|helm|charts|cloudformation|manifests|ansible|playbooks|argocd|flux)/'
IAC_PATTERN+='|(Pulumi\.(yaml|yml)|serverless\.(yaml|yml)|docker-compose(\.[a-z]+)?\.(yaml|yml)|compose\.(yaml|yml)|cdk\.json)$'

# SCA: Node/JS, Python, Go, Java/Kotlin, Ruby, Rust, PHP, .NET, Swift, Scala, Elixir, Dart
SCA_PATTERN='(^|/)(package(-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|npm-shrinkwrap\.json)$'
SCA_PATTERN+='|(^|/)go\.(mod|sum)$'
SCA_PATTERN+='|(^|/)(requirements[^/]*\.txt|Pipfile(\.lock)?|pyproject\.toml|poetry\.lock|setup\.(py|cfg))$'
SCA_PATTERN+='|(^|/)(pom\.xml|build\.gradle(\.kts)?|.*\.gradle|gradle\.lockfile)$'
SCA_PATTERN+='|(^|/)Gemfile(\.lock)?$'
SCA_PATTERN+='|(^|/)Cargo\.(toml|lock)$'
SCA_PATTERN+='|(^|/)composer\.(json|lock)$'
SCA_PATTERN+='|(^|/).*\.(csproj|vbproj|fsproj)$|(^|/)packages\.config$'
SCA_PATTERN+='|(^|/)(Package\.(swift|resolved)|Podfile(\.lock)?)$'
SCA_PATTERN+='|(^|/)build\.sbt$'
SCA_PATTERN+='|(^|/)mix\.(exs|lock)$'
SCA_PATTERN+='|(^|/)pubspec\.(yaml|lock)$'

IAC_FILES=$(echo "$CHANGED" | grep -E "$IAC_PATTERN" || true)
SCA_FILES=$(echo "$CHANGED" | grep -E "$SCA_PATTERN" || true)

PIDS=()

# Launch IaC scan if infra files changed
if [ -n "$IAC_FILES" ]; then
  SCAN_PATH=$(echo "$IAC_FILES" | head -1 | xargs dirname)
  lacework iac scan --output json --path "$SCAN_PATH" \
    > "$SCAN_TMPDIR/iac.json" 2>&1 &
  PIDS+=($!)
fi

# Launch SCA scan if manifest files changed (with caching)
SCA_MANIFEST=""
SCA_HASH=""
if [ -n "$SCA_FILES" ]; then
  MANIFEST=$(echo "$SCA_FILES" | head -1)
  HASH=$(sha256sum "$MANIFEST" 2>/dev/null | cut -d' ' -f1)
  # macOS fallback
  if [ -z "$HASH" ]; then
    HASH=$(shasum -a 256 "$MANIFEST" 2>/dev/null | cut -d' ' -f1)
  fi
  CACHE_DIR="$HOME/.lacework/cache"
  mkdir -p "$CACHE_DIR"
  if [ -n "$HASH" ] && [ -f "$CACHE_DIR/$HASH" ]; then
    echo "Lacework SCA: no dependency changes, skipping scan (cache hit)"
  else
    SCAN_PATH=$(echo "$SCA_FILES" | head -1 | xargs dirname)
    lacework sca scan --output json --path "$SCAN_PATH" \
      > "$SCAN_TMPDIR/sca.json" 2>&1 &
    PIDS+=($!)
    SCA_MANIFEST="$MANIFEST"
    SCA_HASH="$HASH"
  fi
fi

[ ${#PIDS[@]} -eq 0 ] && exit 0

# Wait for all scans
for PID in "${PIDS[@]}"; do wait "$PID"; done

# Cache SCA manifest hash on success
[ -n "$SCA_HASH" ] && touch "$HOME/.lacework/cache/$SCA_HASH"

# Aggregate findings
CRITICAL_COUNT=0
REPORT=""

for SCANNER in iac sca; do
  FILE="$SCAN_TMPDIR/${SCANNER}.json"
  [ -f "$FILE" ] || continue

  # Check if jq can parse the file
  if ! jq empty "$FILE" 2>/dev/null; then
    echo "[$SCANNER] WARNING: Could not parse scan output" >&2
    continue
  fi

  COUNT=$(jq '[.findings[]? | select(.severity=="critical" or .severity=="high")] | length' \
    "$FILE" 2>/dev/null || echo 0)
  CRITICAL_COUNT=$((CRITICAL_COUNT + COUNT))

  if [ "$COUNT" -gt 0 ]; then
    REPORT+="[$SCANNER] $COUNT critical/high finding(s):\n"
    FINDING_LINES=$(jq -r '.findings[]? |
      select(.severity=="critical" or .severity=="high") |
      "  - [\(.severity | ascii_upcase)] \(.file):\(.line // "N/A") \(.rule): \(.message)"' \
      "$FILE" 2>/dev/null)
    REPORT+="${FINDING_LINES}\n"
  else
    TOTAL=$(jq '.findings | length // 0' "$FILE" 2>/dev/null || echo 0)
    [ "$TOTAL" -gt 0 ] && \
      echo "[$SCANNER] $TOTAL medium/low finding(s) — review recommended"
  fi
done

if [ "$CRITICAL_COUNT" -gt 0 ]; then
  printf "Lacework found %d critical/high severity issue(s). Fix before proceeding:\n\n%b" \
    "$CRITICAL_COUNT" "$REPORT" >&2
  exit 2
fi

exit 0
