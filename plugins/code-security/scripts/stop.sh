#!/bin/bash
# stop.sh — Fortinet Code Security scan orchestrator
# Fires on Stop hook after a session completes.
# Outputs findings to stderr so Claude can present them to the user.

# --- Read hook input early (needed for config check and later processing) ---
HOOK_INPUT=$(cat)

# --- Check plugin config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-reader.sh"

HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
resolve_config "$HOOK_CWD"

# Exit if scanning is disabled for this repo
if [ "$SCAN_ENABLED" = "false" ]; then
  exit 0
fi

# Exit if mode is pre-commit — stop hook only runs in post-task mode
if [ "$SCAN_MODE" = "pre-commit" ]; then
  exit 0
fi

# --- Debug logging ---
LOG_DIR="$HOME/.lacework/logs"
mkdir -p "$LOG_DIR"

# Extract session ID and cwd early for logging context
SCAN_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCAN_TMPDIR"' EXIT

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
SESSION_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')

# Per-session log file: stop-hook-<session-id>.log
LOG_FILE="$LOG_DIR/stop-hook-${SESSION_ID:-$(date '+%Y%m%d-%H%M%S')}.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Stop hook started === (cwd: $SESSION_CWD)"

# Stop hook provides transcript_path - read the JSONL transcript file
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty')

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  log "EXIT(0): No transcript path or file not found: ${TRANSCRIPT_PATH:-empty}"
  exit 0
fi
log "Transcript: $TRANSCRIPT_PATH"

# Extract files from Write/Edit/MultiEdit tool uses in the transcript
# JSONL format: each line is a JSON object with .message.content[] containing tool_use
CHANGED=$(cat "$TRANSCRIPT_PATH" | jq -r '
  .message?.content[]? |
  select(.type == "tool_use") |
  select(.name == "Write" or .name == "Edit" or .name == "MultiEdit") |
  .input.file_path // empty
' 2>/dev/null | sort -u)

if [ -z "$CHANGED" ]; then
  log "EXIT(0): No changed files found in transcript"
  exit 0
fi
log "Changed files: $(echo "$CHANGED" | tr '\n' ', ')"

# Track scanned files to avoid re-scanning same changes (prevents loop)
# Hash includes transcript path + file paths + file mtimes so content changes trigger re-scan
SCAN_MARKER_DIR="$HOME/.lacework/scan-markers"
mkdir -p "$SCAN_MARKER_DIR"
FILE_MTIMES=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if [ -f "$f" ]; then
    FILE_MTIMES="${FILE_MTIMES}:$(stat -f '%m' "$f" 2>/dev/null || stat -c '%Y' "$f" 2>/dev/null || echo "0")"
  fi
done <<< "$CHANGED"
CHANGES_HASH=$(echo "${TRANSCRIPT_PATH}:${CHANGED}:${FILE_MTIMES}" | sha256sum 2>/dev/null | cut -d' ' -f1 || echo "${TRANSCRIPT_PATH}:${CHANGED}:${FILE_MTIMES}" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
MARKER_FILE="$SCAN_MARKER_DIR/$CHANGES_HASH"

if [ -f "$MARKER_FILE" ]; then
  log "EXIT(0): Scan marker exists (already scanned this session+files). Hash: $CHANGES_HASH"
  exit 0
fi
log "No scan marker found, proceeding with scan. Hash: $CHANGES_HASH"

# Get scan directory from cwd in hook input
SCAN_PATH=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
[ -z "$SCAN_PATH" ] && SCAN_PATH=$(echo "$CHANGED" | head -1 | xargs dirname)
log "Scan path: $SCAN_PATH"

# Build list of changed file relative paths (strip SCAN_PATH prefix) for matching
CHANGED_RELATIVE="$SCAN_TMPDIR/changed_relative.txt"
> "$CHANGED_RELATIVE"
while IFS= read -r f; do
  [ -z "$f" ] && continue
  rel="${f#$SCAN_PATH/}"
  echo "$rel" >> "$CHANGED_RELATIVE"
done <<< "$CHANGED"

# Build list of changed file directories for proximity matching
CHANGED_DIRS="$SCAN_TMPDIR/changed_dirs.txt"
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  dirname "$rel" >> "$CHANGED_DIRS"
done < "$CHANGED_RELATIVE"
# Deduplicate
sort -u "$CHANGED_DIRS" -o "$CHANGED_DIRS"

PIDS=()
SCAN_TYPE="IaC+SCA"

# Launch both IaC and SCA scans in parallel
# IaC: JSON format (has .findings[] with filePath, policyId, isSuppressed)
# SCA: SARIF format (has file paths for all finding types — CVEs, SAST, secrets, licenses)
log "Starting IaC and SCA scans..."
lacework iac scan --upload=false --noninteractive \
  --format json --save-result "$SCAN_TMPDIR/iac.json" -d "$SCAN_PATH" >/dev/null 2>&1 &
PIDS+=($!)

lacework sca scan "$SCAN_PATH" --deployment=offprem --noninteractive --save-results=false \
  -f sarif -o "$SCAN_TMPDIR/sca.sarif" >/dev/null 2>&1 &
PIDS+=($!)

# Wait for all scans
for PID in "${PIDS[@]}"; do wait "$PID"; done
log "Scans complete. IaC JSON: $([ -f "$SCAN_TMPDIR/iac.json" ] && echo "exists" || echo "missing"), SCA SARIF: $([ -f "$SCAN_TMPDIR/sca.sarif" ] && echo "exists" || echo "missing")"

# --- Helper: check if a finding's file path is related to changed files ---
# Uses two strategies:
# 1. Exact match: finding file path matches a changed file
# 2. Directory proximity: finding file is in the same directory as a changed file
is_related_to_changes() {
  local finding_path="$1"
  [ -z "$finding_path" ] && return 1

  # Strategy 1: exact file match
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if [ "$finding_path" = "$rel" ]; then
      return 0
    fi
  done < "$CHANGED_RELATIVE"

  # Strategy 2: directory proximity — finding is in same dir as a changed file
  local finding_dir
  finding_dir=$(dirname "$finding_path")
  while IFS= read -r changed_dir; do
    [ -z "$changed_dir" ] && continue
    if [ "$finding_dir" = "$changed_dir" ]; then
      return 0
    fi
  done < "$CHANGED_DIRS"

  return 1
}

# Separate findings into changed-file vs pre-existing
CHANGED_CRIT=0; CHANGED_HIGH=0
PREEXIST_CRIT=0; PREEXIST_HIGH=0; PREEXIST_MED=0
FINDING_NUM=0

CHANGED_FINDINGS="$SCAN_TMPDIR/changed_findings.txt"
PREEXIST_FINDINGS="$SCAN_TMPDIR/preexist_findings.txt"
> "$CHANGED_FINDINGS"
> "$PREEXIST_FINDINGS"

# Build a list of changed files for display
CHANGED_FILES_DISPLAY=$(cat "$CHANGED_RELATIVE" | head -5)
CHANGED_FILES_COUNT=$(cat "$CHANGED_RELATIVE" | wc -l | tr -d ' ')

## --- IaC findings (JSON format) ---
IAC_FILE="$SCAN_TMPDIR/iac.json"
if [ -f "$IAC_FILE" ] && jq empty "$IAC_FILE" 2>/dev/null; then
  while IFS='§' read -r sev title resource file_path line_num desc policy_id; do
    [ -z "$sev" ] && continue
    FINDING_NUM=$((FINDING_NUM + 1))

    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
      loc="N/A"
    elif [ -z "$line_num" ] || [ "$line_num" = "null" ]; then
      loc="$file_path"
    else
      loc="$file_path:$line_num"
    fi

    if [ ${#desc} -gt 150 ]; then
      desc="${desc:0:147}..."
    fi

    if is_related_to_changes "$file_path"; then
      TARGET="$CHANGED_FINDINGS"
      if [ "$sev" = "Critical" ]; then CHANGED_CRIT=$((CHANGED_CRIT + 1)); fi
      if [ "$sev" = "High" ]; then CHANGED_HIGH=$((CHANGED_HIGH + 1)); fi
    else
      TARGET="$PREEXIST_FINDINGS"
      if [ "$sev" = "Critical" ]; then PREEXIST_CRIT=$((PREEXIST_CRIT + 1)); fi
      if [ "$sev" = "High" ]; then PREEXIST_HIGH=$((PREEXIST_HIGH + 1)); fi
    fi

    echo "**${FINDING_NUM}. [${sev}] ${title}**" >> "$TARGET"
    echo "   - Resource: \`${resource}\`" >> "$TARGET"
    echo "   - Location: \`${loc}\`" >> "$TARGET"
    echo "   - ${desc}" >> "$TARGET"
    echo "   - Exception ID: \`${policy_id}\`" >> "$TARGET"
    echo "" >> "$TARGET"
  done < <(jq -r '.findings[]? | select(.pass==false and .isSuppressed!=true and (.severity=="Critical" or .severity=="High")) | "\(.severity)§\(.title // .ruleId // "Unknown")§\(.resource // "N/A")§\(.filePath // "")§\(.line // "")§\((.description // "") | gsub("\n"; " "))§\(.policyId // "")"' "$IAC_FILE" 2>/dev/null)

  # Count medium findings separately (pre-existing only, never shown in detail)
  IAC_MED=$(jq '[.findings[]? | select(.pass==false and .isSuppressed!=true and .severity=="Medium")] | length' "$IAC_FILE" 2>/dev/null || echo 0)
  PREEXIST_MED=$((PREEXIST_MED + IAC_MED))
fi

## --- SCA findings (SARIF format) ---
SCA_FILE="$SCAN_TMPDIR/sca.sarif"
if [ -f "$SCA_FILE" ] && jq empty "$SCA_FILE" 2>/dev/null; then
  # SARIF has .runs[0].results[] with:
  # - .properties.category: "vulnerability", "license", or others (SAST, secrets)
  # - .properties.severity: lowercase (critical, high, medium, low)
  # - .ruleId: CVE ID, CWE ID, or license name
  # - .locations[0].physicalLocation.artifactLocation.uri: file path
  # - .locations[0].physicalLocation.region.startLine: line number
  # - .properties.dependency.packageVersionedName: package@version
  # - .properties.fixVersion: fix version
  # - .message.text: full description
  # - .partialFingerprints["hash/v1"]: fingerprint for exceptions

  while IFS='§' read -r category sev rule_id file_path line_num pkg_name fix_version desc fingerprint; do
    [ -z "$sev" ] && continue

    # Capitalize severity
    first_char=$(echo "$sev" | cut -c1 | tr '[:lower:]' '[:upper:]')
    rest=$(echo "$sev" | cut -c2-)
    display_sev="${first_char}${rest}"

    # Only process critical and high — medium and below are counted as pre-existing only
    if [ "$display_sev" != "Critical" ] && [ "$display_sev" != "High" ]; then
      if [ "$display_sev" = "Medium" ]; then
        PREEXIST_MED=$((PREEXIST_MED + 1))
      fi
      continue
    fi

    FINDING_NUM=$((FINDING_NUM + 1))

    # Format location
    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
      loc="N/A"
    elif [ -n "$line_num" ] && [ "$line_num" != "null" ]; then
      loc="$file_path:$line_num"
    else
      loc="$file_path"
    fi

    # Truncate description
    if [ ${#desc} -gt 150 ]; then
      desc="${desc:0:147}..."
    fi

    # Determine if related to changes using file path proximity
    if is_related_to_changes "$file_path"; then
      TARGET="$CHANGED_FINDINGS"
      if [ "$display_sev" = "Critical" ]; then CHANGED_CRIT=$((CHANGED_CRIT + 1)); fi
      if [ "$display_sev" = "High" ]; then CHANGED_HIGH=$((CHANGED_HIGH + 1)); fi
    else
      TARGET="$PREEXIST_FINDINGS"
      if [ "$display_sev" = "Critical" ]; then PREEXIST_CRIT=$((PREEXIST_CRIT + 1)); fi
      if [ "$display_sev" = "High" ]; then PREEXIST_HIGH=$((PREEXIST_HIGH + 1)); fi
    fi

    # Format output based on category
    if [ "$category" = "vulnerability" ]; then
      echo "**${FINDING_NUM}. [${display_sev}] ${rule_id}**" >> "$TARGET"
      if [ -n "$pkg_name" ] && [ "$pkg_name" != "null" ]; then
        echo "   - Package: \`${pkg_name}\`" >> "$TARGET"
      fi
      echo "   - Location: \`${loc}\`" >> "$TARGET"
      if [ -n "$fix_version" ] && [ "$fix_version" != "null" ]; then
        echo "   - Fix: upgrade to \`${fix_version}\`" >> "$TARGET"
      fi
      echo "   - ${desc}" >> "$TARGET"
      echo "   - Exception ID: \`CVE:${rule_id}\`" >> "$TARGET"
    elif [ "$category" = "license" ]; then
      echo "**${FINDING_NUM}. [${display_sev}] License: ${rule_id}**" >> "$TARGET"
      if [ -n "$pkg_name" ] && [ "$pkg_name" != "null" ]; then
        echo "   - Package: \`${pkg_name}\`" >> "$TARGET"
      fi
      echo "   - Location: \`${loc}\`" >> "$TARGET"
      echo "   - ${desc}" >> "$TARGET"
    else
      # SAST, secrets, or other finding types
      echo "**${FINDING_NUM}. [${display_sev}] ${rule_id}**" >> "$TARGET"
      echo "   - Location: \`${loc}\`" >> "$TARGET"
      echo "   - ${desc}" >> "$TARGET"
      if [ -n "$fingerprint" ] && [ "$fingerprint" != "null" ]; then
        echo "   - Exception ID: \`finding:${fingerprint}\`" >> "$TARGET"
      fi
    fi
    echo "" >> "$TARGET"
  done < <(jq -r '
    .runs[0].results[]? |
    # Filter out suppressed/excepted findings (equivalent to isSuppressed in IaC)
    select((.suppressions // []) | length == 0) |
    "\(.properties.category // "other")§\(.properties.severity // .level // "unknown")§\(.ruleId // "Unknown")§\(.locations[0].physicalLocation.artifactLocation.uri // "")§\(.locations[0].physicalLocation.region.startLine // "")§\(.properties.dependency.packageVersionedName // "")§\(.properties.fixVersion // "")§\((.message.text // "") | split("\n")[0] | gsub("\r"; ""))§\(.partialFingerprints["hash/v1"] // "")"
  ' "$SCA_FILE" 2>/dev/null)
fi

# --- Build output message ---
CHANGED_TOTAL=$((CHANGED_CRIT + CHANGED_HIGH))
PREEXIST_TOTAL=$((PREEXIST_CRIT + PREEXIST_HIGH + PREEXIST_MED))
log "Findings — Changed files: ${CHANGED_CRIT} Critical, ${CHANGED_HIGH} High | Pre-existing: ${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High, ${PREEXIST_MED} Medium"

CHANGED_FINDINGS_TEXT=$(cat "$CHANGED_FINDINGS")
PREEXIST_FINDINGS_TEXT=$(cat "$PREEXIST_FINDINGS")

# Check if codesec.yaml already exists
CODESEC_FILE="${SCAN_PATH}/.lacework/codesec.yaml"
if [ -f "$CODESEC_FILE" ]; then
  CODESEC_STATUS="The file \`.lacework/codesec.yaml\` already exists. Add exception IDs to the appropriate \`exceptions\` list."
else
  CODESEC_STATUS="The file \`.lacework/codesec.yaml\` does not exist yet. Create it at \`.lacework/codesec.yaml\` with the structure shown below."
fi

# Build the changed files list for display
if [ "$CHANGED_FILES_COUNT" -le 5 ]; then
  FILES_LIST=$(echo "$CHANGED_FILES_DISPLAY" | sed 's/^/- /')
else
  FILES_LIST=$(echo "$CHANGED_FILES_DISPLAY" | sed 's/^/- /')
  FILES_LIST="${FILES_LIST}
- ... and $((CHANGED_FILES_COUNT - 5)) more"
fi

# --- Determine exit code and message based on changed-file findings ---
if [ "$CHANGED_TOTAL" -gt 0 ]; then
  MESSAGE="<!-- INSTRUCTIONS FOR CLAUDE:
1. First, briefly summarize the changes you completed for the user
2. Then say: Fortinet Code Security scanned the modified files and found security issues that need attention
3. Present the 'Issues in your changed files' section below
4. If there are pre-existing issues, mention them briefly as FYI
5. Ask the user what they would like to do about the findings in their changed files
-->

## Fortinet Code Security Scan

**Files scanned:**
${FILES_LIST}

### Issues in your changed files (${CHANGED_CRIT} Critical, ${CHANGED_HIGH} High)

${CHANGED_FINDINGS_TEXT}"

  if [ "$PREEXIST_TOTAL" -gt 0 ]; then
    MESSAGE="${MESSAGE}
### Pre-existing issues (not related to your changes)

${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High, ${PREEXIST_MED} Medium findings exist in other files. Run \`/fortinet:code-review\` for the full report.
"
  fi

  MESSAGE="${MESSAGE}
For each finding you can either **fix** the issue in code or **add an exception**. What would you like to do?

<!-- INTERNAL INSTRUCTIONS (do not show to user):

When the user chooses to add an exception, use the Exception ID shown for each finding.

How to add exceptions: ${CODESEC_STATUS}

Exception format: <criteria>:<value>:<reason>

Criteria (case-sensitive): policy, CVE, CWE, path, file, fingerprint, finding
Reasons (case-sensitive): Accepted risk, Compensating Controls, False positive, Patch incoming

For IaC findings, add to default.iac.scan.exceptions in .lacework/codesec.yaml
For SCA findings, add to default.sca.scan.exceptions in .lacework/codesec.yaml

Example .lacework/codesec.yaml structure:
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

Important: Only add exceptions the user explicitly approves. Do not auto-suppress findings.
-->"

  touch "$MARKER_FILE"
  log "EXIT(2): ${CHANGED_CRIT} Critical, ${CHANGED_HIGH} High findings in changed files — blocking"
  echo "$MESSAGE" >&2
  exit 2

elif [ "$PREEXIST_TOTAL" -gt 0 ]; then
  MESSAGE="<!-- INSTRUCTIONS FOR CLAUDE:
1. First, summarize the changes you completed
2. Briefly mention: Fortinet Code Security scanned your changes and found no new issues
3. Mention the pre-existing findings as an FYI — do NOT present them as action items
-->

## Fortinet Code Security Scan

**Files scanned:**
${FILES_LIST}

No security issues found in your changed files.

**FYI:** ${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High, ${PREEXIST_MED} Medium pre-existing issues exist in other files. Run \`/fortinet:code-review\` for details."

  touch "$MARKER_FILE"
  log "EXIT(0): No findings in changed files. ${PREEXIST_TOTAL} pre-existing findings reported as FYI"
  echo "$MESSAGE" >&2
  exit 0
fi

log "EXIT(0): No findings at all"
exit 0
