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

# Debug log
DEBUG_LOG="/tmp/stop-hook-debug.log"
echo "=== $(date) ===" > "$DEBUG_LOG"
echo "CHANGED files:" >> "$DEBUG_LOG"
echo "$CHANGED" >> "$DEBUG_LOG"

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

# Debug: log scan results
echo "SCAN_PATH: $SCAN_PATH" >> "$DEBUG_LOG"
echo "IAC result exists: $([ -f "$SCAN_TMPDIR/iac.json" ] && echo yes || echo no)" >> "$DEBUG_LOG"
echo "SCA result exists: $([ -f "$SCAN_TMPDIR/sca.json" ] && echo yes || echo no)" >> "$DEBUG_LOG"
[ -f "$SCAN_TMPDIR/iac.json" ] && echo "IAC size: $(wc -c < "$SCAN_TMPDIR/iac.json")" >> "$DEBUG_LOG"
[ -f "$SCAN_TMPDIR/sca.json" ] && echo "SCA size: $(wc -c < "$SCAN_TMPDIR/sca.json")" >> "$DEBUG_LOG"

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
  FINDINGS_TEXT=$(cat "$FINDINGS_FILE")
  REASON="## Fortinet $SCAN_TYPE Security Scan

**Summary:** ${CRITICAL_COUNT} Critical, ${HIGH_COUNT} High severity issues

$FINDINGS_TEXT

**ACTION REQUIRED:** Fix these security issues OR ask user to add exceptions for specific findings."

  USER_MSG="Fortinet $SCAN_TYPE Security: ${CRITICAL_COUNT} critical, ${HIGH_COUNT} high severity issues found. Review above."

  # Correct Stop hook format: decision=block shows reason to Claude, systemMessage to user
  OUTPUT=$(jq -c -n \
    --arg reason "$REASON" \
    --arg msg "$USER_MSG" \
    '{"decision": "block", "reason": $reason, "systemMessage": $msg}')
  echo "$OUTPUT" >> "$DEBUG_LOG"
  echo "$OUTPUT"
elif [ "$MEDIUM_COUNT" -gt 0 ]; then
  OUTPUT=$(jq -c -n --arg msg "Fortinet $SCAN_TYPE Security: $MEDIUM_COUNT medium severity issues (informational)" '{"systemMessage": $msg}')
  echo "$OUTPUT" >> "$DEBUG_LOG"
  echo "$OUTPUT"
else
  OUTPUT=$(jq -c -n --arg msg "Fortinet $SCAN_TYPE Security: No issues found" '{"systemMessage": $msg}')
  echo "$OUTPUT" >> "$DEBUG_LOG"
  echo "$OUTPUT"
fi

echo "Final counts: CRIT=$CRITICAL_COUNT HIGH=$HIGH_COUNT MED=$MEDIUM_COUNT" >> "$DEBUG_LOG"
exit 0
