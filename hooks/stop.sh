#!/bin/bash
# stop.sh — Fortinet Code Security scan orchestrator
# Fires after Write/Edit tool calls via PostToolUse hook.
# Outputs JSON with systemMessage for visibility in Claude Code UI.

SCAN_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCAN_TMPDIR"' EXIT

HOOK_INPUT=$(cat)

# PostToolUse hook provides tool_input with file_path directly
CHANGED=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

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

# Exit silently if no relevant files
[ -z "$IAC_FILES" ] && [ -z "$SCA_FILES" ] && exit 0

PIDS=()
SCAN_TYPE=""

# Launch IaC scan if infra files changed
if [ -n "$IAC_FILES" ]; then
  SCAN_PATH=$(echo "$IAC_FILES" | head -1 | xargs dirname)
  SCAN_TYPE="IaC"
  # --upload=false: skip uploading to Lacework cloud
  # --quiet: suppress logging noise
  # --save-result: direct file output (still outputs to stdout, so redirect to /dev/null)
  lacework iac scan --format json --upload=false --quiet \
    --save-result "$SCAN_TMPDIR/iac.json" -d "$SCAN_PATH" >/dev/null 2>&1 &
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
    # Cache hit - skip SCA scan silently
    :
  else
    SCAN_PATH=$(echo "$SCA_FILES" | head -1 | xargs dirname)
    [ -n "$SCAN_TYPE" ] && SCAN_TYPE="IaC+SCA" || SCAN_TYPE="SCA"
    # --quiet: suppress logging noise
    # -f lw-json: Lacework JSON format
    # -o: output to file
    lacework sca scan --quiet -f lw-json -o "$SCAN_TMPDIR/sca.json" "$SCAN_PATH" 2>/dev/null &
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

# Aggregate findings and extract details
CRITICAL_COUNT=0
HIGH_COUNT=0
MEDIUM_COUNT=0
FINDING_NUM=0

# Build findings list in temp file for proper formatting
FINDINGS_FILE="$SCAN_TMPDIR/findings.txt"
> "$FINDINGS_FILE"

for SCANNER in iac sca; do
  FILE="$SCAN_TMPDIR/${SCANNER}.json"
  [ -f "$FILE" ] || continue

  # Check if jq can parse the file
  if ! jq empty "$FILE" 2>/dev/null; then
    continue
  fi

  # Count only failed findings (pass == false)
  # Lacework uses capitalized severity values: "Critical", "High", "Medium"
  CRIT=$(jq '[.findings[]? | select(.pass==false and .severity=="Critical")] | length' "$FILE" 2>/dev/null || echo 0)
  HIGH=$(jq '[.findings[]? | select(.pass==false and .severity=="High")] | length' "$FILE" 2>/dev/null || echo 0)
  MED=$(jq '[.findings[]? | select(.pass==false and .severity=="Medium")] | length' "$FILE" 2>/dev/null || echo 0)

  CRITICAL_COUNT=$((CRITICAL_COUNT + CRIT))
  HIGH_COUNT=$((HIGH_COUNT + HIGH))
  MEDIUM_COUNT=$((MEDIUM_COUNT + MED))

  # Extract critical and high FAILED findings with full details
  # Uses correct field names: filePath, line, resource, title, description
  while IFS='§' read -r sev title resource file_path line_num desc; do
    [ -z "$sev" ] && continue
    FINDING_NUM=$((FINDING_NUM + 1))

    # Format location as file:line
    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
      loc="N/A"
    elif [ -z "$line_num" ] || [ "$line_num" = "null" ]; then
      loc="$file_path"
    else
      loc="$file_path:$line_num"
    fi

    # Truncate description if too long (keep first 150 chars)
    if [ ${#desc} -gt 150 ]; then
      desc="${desc:0:147}..."
    fi

    # Output as formatted list item
    echo "**${FINDING_NUM}. [${sev}] ${title}**" >> "$FINDINGS_FILE"
    echo "   - Resource: \`${resource}\`" >> "$FINDINGS_FILE"
    echo "   - Location: \`${loc}\`" >> "$FINDINGS_FILE"
    echo "   - ${desc}" >> "$FINDINGS_FILE"
    echo "" >> "$FINDINGS_FILE"
  done < <(jq -r '.findings[]? | select(.pass==false and (.severity=="Critical" or .severity=="High")) | "\(.severity)§\(.title // .ruleId // "Unknown")§\(.resource // "N/A")§\(.filePath // "")§\(.line // "")§\(.description // "")"' "$FILE" 2>/dev/null)
done

TOTAL_SEVERE=$((CRITICAL_COUNT + HIGH_COUNT))

# Output JSON with findings list and actionable instructions for Claude
if [ "$TOTAL_SEVERE" -gt 0 ]; then
  # Read findings and escape for JSON
  FINDINGS_LIST=$(cat "$FINDINGS_FILE" | sed 's/"/\\"/g' | sed 's/$/\\n/' | tr -d '\n')

  SUMMARY="**Summary:** ${CRITICAL_COUNT} Critical, ${HIGH_COUNT} High severity issues"
  INSTRUCTION="**ACTION REQUIRED:** Fix these security issues OR ask user to add exceptions for specific findings."

  MSG="## Fortinet $SCAN_TYPE Security Scan\\n\\n${SUMMARY}\\n\\n${FINDINGS_LIST}${INSTRUCTION}"

  echo "{\"systemMessage\": \"$MSG\", \"continue\": true}"
elif [ "$MEDIUM_COUNT" -gt 0 ]; then
  echo "{\"systemMessage\": \"Fortinet $SCAN_TYPE Security: $MEDIUM_COUNT medium severity issues (informational)\", \"continue\": true}"
else
  echo "{\"systemMessage\": \"Fortinet $SCAN_TYPE Security: No issues found\", \"continue\": true}"
fi

exit 0
