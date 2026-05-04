#!/bin/bash
# pre-commit-scan.sh — PreToolUse hook for pre-commit security scanning
#
# Intercepts Bash tool calls that are `git commit` commands. If the plugin is
# in pre-commit mode, scans staged files and blocks the commit if Critical/High
# findings are found in those files.
#
# How it works:
#   1. Reads hook input JSON (contains tool_input.command and cwd)
#   2. Checks if the command is a git commit (including --amend)
#   3. Reads plugin config — exits if mode isn't "pre-commit" or scanning is disabled
#   4. Gets staged files via git diff --cached --name-only
#   5. Runs IaC + SCA scans in parallel
#   6. Filters findings to staged files only (exact match + directory proximity)
#   7. Blocks commit if Critical/High findings exist in staged files
#
# Output format (PreToolUse hook protocol):
#   Block:  { "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "..." } }
#   Allow:  exit 0 with no output (or empty JSON)
#
# Severity handling:
#   - Critical/High in staged files → block commit
#   - Medium/Low in staged files → allow, informational only
#   - Findings in non-staged files → pre-existing, FYI only
#
# Exception handling:
#   Users can add exceptions to .lacework/codesec.yaml to suppress findings.
#   Suppressed findings (isSuppressed, suppressions) are excluded from counts.

# --- Require jq ---
if ! command -v jq &>/dev/null; then
  exit 0
fi

# --- Read hook input ---
HOOK_INPUT=$(cat)

# --- Check if this is a git commit command ---
# Extract the Bash command from hook input
COMMAND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

# Match git commit commands (including --amend, -m, etc.)
# Must start with "git commit" or contain "git commit" after && or ;
if ! echo "$COMMAND" | grep -qE '(^|&&\s*|;\s*)git\s+commit(\s|$)'; then
  exit 0
fi

# --- Read config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-reader.sh"

HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
resolve_config "$HOOK_CWD"

# Exit if not in pre-commit mode
if [ "$SCAN_MODE" != "pre-commit" ]; then
  exit 0
fi

# Exit if scanning is disabled
if [ "$SCAN_ENABLED" = "false" ]; then
  exit 0
fi

# --- Check if lacework CLI is available ---
if ! command -v lacework &>/dev/null; then
  exit 0
fi

# --- Debug logging ---
LOG_DIR="$HOME/.lacework/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/pre-commit-$(date '+%Y%m%d-%H%M%S').log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== Pre-commit scan started === (cwd: $HOOK_CWD)"
log "Command: $COMMAND"

# --- Get files being committed ---
# The PreToolUse hook fires BEFORE the command runs, so git diff --cached may
# be empty if git add and git commit are chained (e.g., "git add file && git commit").
# Strategy: check already-staged files first, then also extract files from any
# git add commands in the same chain.
SCAN_PATH="$HOOK_CWD"

# 1. Already staged files
COMMIT_FILES=$(cd "$SCAN_PATH" && git diff --cached --name-only 2>/dev/null)

# 2. Extract files from git add in the command chain (handles "git add file1 file2 && git commit")
#    Captures file args after "git add" up to the next && or ; or end of string.
#    Excludes flags like -A, -u, --all, -p, -i, -f, --force
GIT_ADD_FILES=$(echo "$COMMAND" | grep -oE 'git\s+add\s+[^;&]+' | sed 's/git\s*add\s*//' | tr ' ' '\n' | grep -v '^-' | grep -v '^$')

# If git add uses -A or --all or ., treat as "all modified files in repo"
if echo "$COMMAND" | grep -qE 'git\s+add\s+(-A|--all|\.)'; then
  GIT_ADD_FILES=$(cd "$SCAN_PATH" && git diff --name-only 2>/dev/null; cd "$SCAN_PATH" && git ls-files --others --exclude-standard 2>/dev/null)
fi

# Combine both sources, deduplicate
COMMIT_FILES=$(printf '%s\n%s' "$COMMIT_FILES" "$GIT_ADD_FILES" | sort -u | grep -v '^$')

if [ -z "$COMMIT_FILES" ]; then
  log "EXIT: No files to commit (no staged files, no git add files found)"
  exit 0
fi
log "Files being committed: $(echo "$COMMIT_FILES" | tr '\n' ', ')"

# --- Setup temp directory ---
SCAN_TMPDIR=$(mktemp -d)
trap 'rm -rf "$SCAN_TMPDIR"' EXIT

# Build staged files list for filtering
STAGED_RELATIVE="$SCAN_TMPDIR/staged_relative.txt"
echo "$COMMIT_FILES" > "$STAGED_RELATIVE"

STAGED_DIRS="$SCAN_TMPDIR/staged_dirs.txt"
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  dirname "$rel"
done <<< "$COMMIT_FILES" | sort -u > "$STAGED_DIRS"

# --- Run scans in parallel ---
log "Starting IaC and SCA scans..."
PIDS=()

lacework iac scan --upload=false --noninteractive \
  --format json --save-result "$SCAN_TMPDIR/iac.json" -d "$SCAN_PATH" >/dev/null 2>&1 &
PIDS+=($!)

lacework sca scan "$SCAN_PATH" --deployment=offprem --noninteractive --save-results=false \
  -f sarif -o "$SCAN_TMPDIR/sca.sarif" >/dev/null 2>&1 &
PIDS+=($!)

for PID in "${PIDS[@]}"; do wait "$PID"; done
log "Scans complete."

# --- Helper: check if finding is related to staged files ---
is_related_to_staged() {
  local finding_path="$1"
  [ -z "$finding_path" ] && return 1

  # Strategy 1: exact file match
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    if [ "$finding_path" = "$rel" ] || [[ "$finding_path" == *"$rel" ]]; then
      return 0
    fi
  done < "$STAGED_RELATIVE"

  # Strategy 2: directory proximity
  local finding_dir
  finding_dir=$(dirname "$finding_path")
  while IFS= read -r staged_dir; do
    [ -z "$staged_dir" ] && continue
    if [ "$finding_dir" = "$staged_dir" ]; then
      return 0
    fi
  done < "$STAGED_DIRS"

  return 1
}

# --- Process findings ---
STAGED_CRIT=0; STAGED_HIGH=0
PREEXIST_CRIT=0; PREEXIST_HIGH=0; PREEXIST_MED=0
FINDING_NUM=0

STAGED_FINDINGS="$SCAN_TMPDIR/staged_findings.txt"
PREEXIST_FINDINGS="$SCAN_TMPDIR/preexist_findings.txt"
> "$STAGED_FINDINGS"
> "$PREEXIST_FINDINGS"

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

    if is_related_to_staged "$file_path"; then
      TARGET="$STAGED_FINDINGS"
      if [ "$sev" = "Critical" ]; then STAGED_CRIT=$((STAGED_CRIT + 1)); fi
      if [ "$sev" = "High" ]; then STAGED_HIGH=$((STAGED_HIGH + 1)); fi
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

  IAC_MED=$(jq '[.findings[]? | select(.pass==false and .isSuppressed!=true and .severity=="Medium")] | length' "$IAC_FILE" 2>/dev/null || echo 0)
  PREEXIST_MED=$((PREEXIST_MED + IAC_MED))
fi

## --- SCA findings (SARIF format) ---
SCA_FILE="$SCAN_TMPDIR/sca.sarif"
if [ -f "$SCA_FILE" ] && jq empty "$SCA_FILE" 2>/dev/null; then
  while IFS='§' read -r category sev rule_id file_path line_num pkg_name fix_version desc fingerprint; do
    [ -z "$sev" ] && continue

    first_char=$(echo "$sev" | cut -c1 | tr '[:lower:]' '[:upper:]')
    rest=$(echo "$sev" | cut -c2-)
    display_sev="${first_char}${rest}"

    if [ "$display_sev" != "Critical" ] && [ "$display_sev" != "High" ]; then
      if [ "$display_sev" = "Medium" ]; then
        PREEXIST_MED=$((PREEXIST_MED + 1))
      fi
      continue
    fi

    FINDING_NUM=$((FINDING_NUM + 1))

    if [ -z "$file_path" ] || [ "$file_path" = "null" ]; then
      loc="N/A"
    elif [ -n "$line_num" ] && [ "$line_num" != "null" ]; then
      loc="$file_path:$line_num"
    else
      loc="$file_path"
    fi

    if [ ${#desc} -gt 150 ]; then
      desc="${desc:0:147}..."
    fi

    if is_related_to_staged "$file_path"; then
      TARGET="$STAGED_FINDINGS"
      if [ "$display_sev" = "Critical" ]; then STAGED_CRIT=$((STAGED_CRIT + 1)); fi
      if [ "$display_sev" = "High" ]; then STAGED_HIGH=$((STAGED_HIGH + 1)); fi
    else
      TARGET="$PREEXIST_FINDINGS"
      if [ "$display_sev" = "Critical" ]; then PREEXIST_CRIT=$((PREEXIST_CRIT + 1)); fi
      if [ "$display_sev" = "High" ]; then PREEXIST_HIGH=$((PREEXIST_HIGH + 1)); fi
    fi

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
    select((.suppressions // []) | length == 0) |
    "\(.properties.category // "other")§\(.properties.severity // .level // "unknown")§\(.ruleId // "Unknown")§\(.locations[0].physicalLocation.artifactLocation.uri // "")§\(.locations[0].physicalLocation.region.startLine // "")§\(.properties.dependency.packageVersionedName // "")§\(.properties.fixVersion // "")§\((.message.text // "") | split("\n")[0] | gsub("\r"; ""))§\(.partialFingerprints["hash/v1"] // "")"
  ' "$SCA_FILE" 2>/dev/null)
fi

# --- Build output ---
STAGED_TOTAL=$((STAGED_CRIT + STAGED_HIGH))
PREEXIST_TOTAL=$((PREEXIST_CRIT + PREEXIST_HIGH + PREEXIST_MED))
log "Findings — Staged files: ${STAGED_CRIT} Critical, ${STAGED_HIGH} High | Pre-existing: ${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High, ${PREEXIST_MED} Medium"

# If no Critical/High in staged files, allow the commit
if [ "$STAGED_TOTAL" -eq 0 ]; then
  log "EXIT: No Critical/High in staged files — allowing commit"
  exit 0
fi

# --- Block the commit ---
STAGED_FINDINGS_TEXT=$(cat "$STAGED_FINDINGS")

# Build staged files list for display
STAGED_DISPLAY=$(echo "$COMMIT_FILES" | head -5 | sed 's/^/- /')
STAGED_COUNT=$(echo "$COMMIT_FILES" | wc -l | tr -d ' ')
if [ "$STAGED_COUNT" -gt 5 ]; then
  STAGED_DISPLAY="${STAGED_DISPLAY}
- ... and $((STAGED_COUNT - 5)) more"
fi

# Check if codesec.yaml exists
CODESEC_FILE="${SCAN_PATH}/.lacework/codesec.yaml"
if [ -f "$CODESEC_FILE" ]; then
  CODESEC_STATUS="The file \`.lacework/codesec.yaml\` already exists. Add exception IDs to the appropriate \`exceptions\` list."
else
  CODESEC_STATUS="The file \`.lacework/codesec.yaml\` does not exist yet. Create it at \`.lacework/codesec.yaml\` with the structure shown below."
fi

MESSAGE="## Fortinet Code Security — Commit Blocked

Security scan found **${STAGED_CRIT} Critical, ${STAGED_HIGH} High** issues in your staged files. The commit has been blocked.

**Staged files scanned:**
${STAGED_DISPLAY}

### Issues in staged files

${STAGED_FINDINGS_TEXT}"

if [ "$PREEXIST_TOTAL" -gt 0 ]; then
  MESSAGE="${MESSAGE}
### Pre-existing issues (not in staged files)

${PREEXIST_CRIT} Critical, ${PREEXIST_HIGH} High, ${PREEXIST_MED} Medium findings exist in other files. Run \`/fortinet:code-review\` for the full report.
"
fi

MESSAGE="${MESSAGE}
For each finding you can either **fix** the issue in code or **add an exception**, then retry the commit.

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
After fixing or adding exceptions, retry the git commit command.
-->"

log "EXIT(block): ${STAGED_CRIT} Critical, ${STAGED_HIGH} High findings in staged files"

# Output PreToolUse deny response
# permissionDecision: "deny" blocks the tool call
# permissionDecisionReason: fed back to Claude so it understands why and can fix
jq -n --arg msg "$MESSAGE" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $msg
  }
}'
