#!/bin/bash
# stop.sh — Fortinet Code Security scan orchestrator
# Fires on Stop hook after a session completes.
# Outputs findings to stderr so Claude can present them to the user.

# --- Read hook input early (needed for config check and later processing) ---
HOOK_INPUT=$(cat)

# --- Check plugin config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-reader.sh"
source "$SCRIPT_DIR/file-utils.sh"

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
# Prune log files older than 7 days to prevent unbounded growth
find "$LOG_DIR" -name "*.log" -mtime +7 -delete 2>/dev/null

# Extract session ID and cwd early for logging context
SCAN_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCAN_TMPDIR"' EXIT

SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')
SESSION_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')

# Per-session log file: stop-hook-<session-id>.log
LOG_FILE="$LOG_DIR/stop-hook-${SESSION_ID:-$(date '+%Y%m%d-%H%M%S')}.log"

# Cap log file at 1MB — keep the last 500 lines if over limit
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 1048576 ]; then
  tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

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

# Resolve scan directory: prefer the git root of the first changed file over
# the session cwd. This handles the case where Claude edits files in a repo
# different from the working directory it was launched in.
SCAN_PATH=""
FIRST_CHANGED=$(echo "$CHANGED" | head -1)
if [ -n "$FIRST_CHANGED" ] && [ -f "$FIRST_CHANGED" ]; then
  FIRST_DIR=$(dirname "$FIRST_CHANGED")
  GIT_ROOT=$(cd "$FIRST_DIR" && git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$GIT_ROOT" ]; then
    SCAN_PATH="$GIT_ROOT"
    log "Resolved scan path from changed files git root: $SCAN_PATH"
  fi
fi
if [ -z "$SCAN_PATH" ]; then
  SCAN_PATH=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
  [ -z "$SCAN_PATH" ] && SCAN_PATH=$(echo "$CHANGED" | head -1 | xargs dirname)
fi
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

# Expand modified files with companion manifests/lock files for SCA --modified-files
SCA_MODIFIED_LIST=$(expand_with_companions "$(cat "$CHANGED_RELATIVE")" "$SCAN_PATH")
SCA_MODIFIED_FILES=$(echo "$SCA_MODIFIED_LIST" | grep -v '^$' | paste -sd ',' -)
log "SCA modified files (with companions): $SCA_MODIFIED_FILES"

PIDS=()

# Launch scans — IaC only if changed files include IaC patterns
CHANGED_FILES_LIST=$(cat "$CHANGED_RELATIVE")
if has_iac_files "$CHANGED_FILES_LIST"; then
  log "Starting IaC and SCA scans..."
  lacework iac scan --upload=false --noninteractive \
    --format json --save-result "$SCAN_TMPDIR/iac.json" -d "$SCAN_PATH" >/dev/null 2>"$SCAN_TMPDIR/iac.stderr" &
  PIDS+=($!)
else
  log "No IaC files in changed files — skipping IaC scan"
  log "Starting SCA scan only..."
fi

lacework sca scan "$SCAN_PATH" --deployment=offprem --noninteractive --save-results=false \
  -f sarif -o "$SCAN_TMPDIR/sca.sarif" \
  --modified-files="$SCA_MODIFIED_FILES" >/dev/null 2>"$SCAN_TMPDIR/sca.stderr" &
PIDS+=($!)

# Wait for all scans
for PID in "${PIDS[@]}"; do wait "$PID"; done
[ -s "$SCAN_TMPDIR/iac.stderr" ] && log "IaC stderr: $(cat "$SCAN_TMPDIR/iac.stderr")"
[ -s "$SCAN_TMPDIR/sca.stderr" ] && log "SCA stderr: $(cat "$SCAN_TMPDIR/sca.stderr")"
log "Scans complete. IaC JSON: $([ -f "$SCAN_TMPDIR/iac.json" ] && echo "exists" || echo "missing"), SCA SARIF: $([ -f "$SCAN_TMPDIR/sca.sarif" ] && echo "exists" || echo "missing")"

# --- Helper: check if a finding's file path matches a changed file ---
# Exact match only — finding file path must match a changed file exactly.
is_related_to_changes() {
  local finding_path="$1"
  [ -z "$finding_path" ] && return 1

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if [ "$finding_path" = "$rel" ]; then
      return 0
    fi
  done < "$CHANGED_RELATIVE"

  return 1
}

# Separate findings into changed-file vs pre-existing
CHANGED_CRIT=0; CHANGED_HIGH=0; CHANGED_MED=0
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

    echo "- [${sev}] ${title} — ${loc} (${policy_id})" >> "$TARGET"
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

    if [ "$display_sev" != "Critical" ] && [ "$display_sev" != "High" ]; then
      if [ "$display_sev" = "Medium" ]; then
        if is_related_to_changes "$file_path"; then
          CHANGED_MED=$((CHANGED_MED + 1))
        else
          PREEXIST_MED=$((PREEXIST_MED + 1))
        fi
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

    # Format finding
    sca_title="$rule_id"
    sca_resource=""
    exception_id=""

    if [ "$category" = "vulnerability" ]; then
      [ -n "$pkg_name" ] && [ "$pkg_name" != "null" ] && sca_resource="$pkg_name"
      exception_id="CVE:${rule_id}"
    elif [ "$category" = "license" ]; then
      sca_title="License: ${rule_id}"
      [ -n "$pkg_name" ] && [ "$pkg_name" != "null" ] && sca_resource="$pkg_name"
      exception_id=""
    else
      [ -n "$fingerprint" ] && [ "$fingerprint" != "null" ] && exception_id="finding:${fingerprint}"
    fi

    sca_pkg_info=""
    [ -n "$sca_resource" ] && sca_pkg_info=" (${sca_resource})"
    echo "- [${display_sev}] ${sca_title}${sca_pkg_info} — ${loc} (${exception_id:-—})" >> "$TARGET"
  done < <(jq -r '
    .runs[0].results[]? |
    # Filter out suppressed/excepted findings (equivalent to isSuppressed in IaC)
    select((.suppressions // []) | length == 0) |
    "\(.properties.category // "other")§\(.properties.severity // .level // "unknown")§\(.ruleId // "Unknown")§\(.locations[0].physicalLocation.artifactLocation.uri // "")§\(.locations[0].physicalLocation.region.startLine // "")§\(.properties.dependency.packageVersionedName // "")§\(.properties.fixVersion // "")§\((.message.text // "") | split("\n")[0] | gsub("\r"; ""))§\(.partialFingerprints["hash/v1"] // "")"
  ' "$SCA_FILE" 2>/dev/null)
fi

# --- Build output message ---
CHANGED_TOTAL=$((CHANGED_CRIT + CHANGED_HIGH))
PREEXIST_TOTAL=$((PREEXIST_CRIT + PREEXIST_HIGH))
log "Findings — Changed: ${CHANGED_CRIT} Critical, ${CHANGED_HIGH} High, ${CHANGED_MED} Medium | Pre-existing: ${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High, ${PREEXIST_MED} Medium"

CHANGED_FINDINGS_TEXT=$(cat "$CHANGED_FINDINGS")
PREEXIST_FINDINGS_TEXT=$(cat "$PREEXIST_FINDINGS")

# Build the changed files list for display
if [ "$CHANGED_FILES_COUNT" -le 5 ]; then
  FILES_LIST=$(echo "$CHANGED_FILES_DISPLAY" | sed 's/^/- /')
else
  FILES_LIST=$(echo "$CHANGED_FILES_DISPLAY" | sed 's/^/- /')
  FILES_LIST="${FILES_LIST}
- ... and $((CHANGED_FILES_COUNT - 5)) more"
fi

# --- Build output ---
# Output to stderr with exit 2: Claude Code re-invokes Claude with the stderr
# content as context. Claude sees the findings and presents them nicely to the user.
# No internal instructions here — exception handling details live in the
# /fortinet:code-review skill, which Claude knows about via SessionStart context.

if [ "$CHANGED_TOTAL" -gt 0 ]; then
  MESSAGE="Fortinet Code Security scanned your changes and detected ${CHANGED_CRIT} Critical, ${CHANGED_HIGH} High security issues.

Files changed: $(echo "$CHANGED_FILES_DISPLAY" | tr '\n' ', ' | sed 's/,$//')

Findings:
${CHANGED_FINDINGS_TEXT}"

  if [ "$PREEXIST_TOTAL" -gt 0 ]; then
    MESSAGE="${MESSAGE}
Pre-existing issues (not related to your changes):
${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High findings in other files. Run /fortinet:code-review for the full report.
"
  fi

  MESSAGE="${MESSAGE}
What would you like to do?
1. Fix the issues - update the code to resolve the security findings
2. Add exceptions - suppress specific findings via .lacework/codesec.yaml
3. Skip for now - leave findings as-is and continue working"

  touch "$MARKER_FILE"
  log "EXIT(2): ${CHANGED_CRIT} Critical, ${CHANGED_HIGH} High findings in changed files — blocking"
  echo "$MESSAGE" >&2
  exit 2

elif [ "$PREEXIST_TOTAL" -gt 0 ]; then
  MESSAGE="Fortinet Code Security scanned your changes and found no new issues. ${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High pre-existing issues exist in other files. Run /fortinet:code-review for details."

  touch "$MARKER_FILE"
  log "EXIT(0): No findings in changed files. ${PREEXIST_TOTAL} pre-existing findings reported as FYI"
  echo "$MESSAGE" >&2
  exit 0
fi

log "EXIT(0): No findings at all"
exit 0
