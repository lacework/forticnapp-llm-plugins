#!/bin/bash
# stop.sh — Fortinet Code Security scan orchestrator
# Fires on Stop hook after a session completes.
# Outputs JSON with systemMessage for visibility in Claude Code UI.

SCAN_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCAN_TMPDIR"' EXIT

HOOK_INPUT=$(cat)

# Stop hook provides transcript_path - read the JSONL transcript file
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')

[ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] && exit 0

# Extract files from Write/Edit/MultiEdit tool uses in the transcript
# JSONL format: each line is a JSON object with .message.content[] containing tool_use
CHANGED=$(cat "$TRANSCRIPT_PATH" | jq -r '
  .message?.content[]? |
  select(.type == "tool_use") |
  select(.name == "Write" or .name == "Edit" or .name == "MultiEdit") |
  .input.file_path // empty
' 2>/dev/null | sort -u)

[ -z "$CHANGED" ] && exit 0

# Track scanned files to avoid re-scanning same changes (prevents loop)
SCAN_MARKER_DIR="$HOME/.lacework/scan-markers"
mkdir -p "$SCAN_MARKER_DIR"
CHANGES_HASH=$(echo "$CHANGED" | sha256sum 2>/dev/null | cut -d' ' -f1 || shasum -a 256 2>/dev/null | cut -d' ' -f1)
MARKER_FILE="$SCAN_MARKER_DIR/$CHANGES_HASH"

[ -f "$MARKER_FILE" ] && exit 0

# Get scan directory from cwd in hook input
SCAN_PATH=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
[ -z "$SCAN_PATH" ] && SCAN_PATH=$(echo "$CHANGED" | head -1 | xargs dirname)

PIDS=()
SCAN_TYPE="IaC+SCA"

# Launch both IaC and SCA scans in parallel
lacework iac scan --upload=false --noninteractive \
  --format json --save-result "$SCAN_TMPDIR/iac.json" -d "$SCAN_PATH" >/dev/null 2>&1 &
PIDS+=($!)

lacework sca scan "$SCAN_PATH" --deployment=offprem --noninteractive --save-results=false \
  -f lw-json -o "$SCAN_TMPDIR/sca.json" 2>/dev/null &
PIDS+=($!)

# Wait for all scans
for PID in "${PIDS[@]}"; do wait "$PID"; done

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
  # Includes policyId (IaC) and cveId (SCA) for exception management
  while IFS='§' read -r sev title resource file_path line_num desc policy_id cve_id; do
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

    # Include exception identifier for IaC (policyId) or SCA (cveId)
    if [ "$SCANNER" = "iac" ] && [ -n "$policy_id" ] && [ "$policy_id" != "null" ]; then
      echo "   - Exception ID: \`${policy_id}\`" >> "$FINDINGS_FILE"
    elif [ "$SCANNER" = "sca" ] && [ -n "$cve_id" ] && [ "$cve_id" != "null" ]; then
      echo "   - Exception ID: \`CVE:${cve_id}\`" >> "$FINDINGS_FILE"
    fi

    echo "" >> "$FINDINGS_FILE"
  done < <(jq -r '.findings[]? | select(.pass==false and (.severity=="Critical" or .severity=="High")) | "\(.severity)§\(.title // .ruleId // "Unknown")§\(.resource // "N/A")§\(.filePath // "")§\(.line // "")§\(.description // "")§\(.policyId // "")§\(.cveId // "")"' "$FILE" 2>/dev/null)
done

TOTAL_SEVERE=$((CRITICAL_COUNT + HIGH_COUNT))

# Output findings and control exit code
if [ "$TOTAL_SEVERE" -gt 0 ]; then
  FINDINGS_TEXT=$(cat "$FINDINGS_FILE")

  # Check if codesec.yaml already exists
  CODESEC_FILE="${SCAN_PATH}/.lacework/codesec.yaml"
  if [ -f "$CODESEC_FILE" ]; then
    CODESEC_STATUS="The file \`.lacework/codesec.yaml\` already exists. Add exception IDs to the appropriate \`exceptions\` list."
  else
    CODESEC_STATUS="The file \`.lacework/codesec.yaml\` does not exist yet. Create it at \`.lacework/codesec.yaml\` with the structure shown below."
  fi

  MESSAGE="## Fortinet $SCAN_TYPE Security Scan

**Summary:** ${CRITICAL_COUNT} Critical, ${HIGH_COUNT} High severity issues

$FINDINGS_TEXT
---

**ACTION REQUIRED:** For each finding above, ask the user whether to:

1. **Fix** the security issue in code, OR
2. **Add exception** using the Exception ID shown for each finding

**How to add exceptions:** ${CODESEC_STATUS}

Exception format: \`<criteria>:<value>:<reason>\`

**Criteria** (case-sensitive): \`policy\`, \`CVE\`, \`CWE\`, \`path\`, \`file\`, \`fingerprint\`, \`finding\`
**Reasons** (case-sensitive): \`Accepted risk\`, \`Compensating Controls\`, \`False positive\`, \`Patch incoming\`

Add to \`default.iac.scan.exceptions\` for IaC findings, \`default.sca.scan.exceptions\` for SCA findings.

\`\`\`yaml
# .lacework/codesec.yaml
default:
    iac:
        enabled: true
        scan:
            exceptions:
                - \"policy:<policy-id>:<reason>\"
                - \"path:<glob-pattern>:<reason>\"
                - \"file:<file-path>:<reason>\"
    sca:
        enabled: true
        scan:
            exceptions:
                - \"CVE:<cve-id>:<reason>\"
                - \"path:<glob-pattern>:<reason>\"
                - \"CWE:<cwe-id>:<reason>\"
\`\`\`

**Important:** Only add exceptions the user explicitly approves. Do not auto-suppress findings."

  # Mark these files as scanned to prevent re-scanning loop
  touch "$MARKER_FILE"

  # Output to stderr so Claude sees findings, exit 2 to block and wait for user action
  echo "$MESSAGE" >&2
  exit 2
fi

exit 0
