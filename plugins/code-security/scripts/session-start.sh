#!/bin/bash
# session-start.sh — Inject Fortinet Code Security context into Claude Code sessions
#
# Runs as a SessionStart hook. Outputs JSON with additionalContext that Claude Code
# injects as system context at the beginning of every conversation.
#
# Purpose:
#   This hook serves two goals:
#
#   1. SECURITY AWARENESS (proactive secure coding)
#      Without this hook, Claude writes code first and the stop hook catches issues after.
#      With this hook, Claude knows security scanning is active and writes secure defaults
#      from the start — tighter CIDR blocks, public access disabled, safer dependency versions.
#      This reduces the number of findings and remediation loops.
#
#   2. SKILL DISCOVERABILITY (users find the right tools)
#      Users may not know the plugin's slash commands exist. This hook tells Claude about
#      /fortinet:code-review, /fortinet:cli-setup, and /fortinet:settings so it can suggest
#      them when relevant — e.g., when a user asks "how do I check for vulnerabilities?"
#
# How it works:
#   - Reads hook input JSON from stdin (contains cwd, session_id, etc.)
#   - Checks ~/.lacework/plugins/code-security.json to see if scanning is enabled
#   - If scanning is disabled for this repo, outputs empty JSON (no context injected)
#   - If scanning is enabled, outputs { "additionalContext": "..." } with the security message
#
# Output format (Claude Code SessionStart hook protocol):
#   { "additionalContext": "text to inject into session context" }
#
# Config check logic (via config-reader.sh):
#   1. Read ~/.lacework/plugins/code-security.json
#   2. Detect format: v2 (hooks.mode/enabled/overrides) or v1 (hooks.stop.*)
#   3. Resolve SCAN_MODE and SCAN_ENABLED for the given cwd
#   4. If config missing or malformed, default to pre-commit mode, enabled

# --- Require jq ---
# All output paths use jq to produce valid JSON. If jq is missing, output empty
# JSON rather than risking malformed output that could break session start.
if ! command -v jq &>/dev/null; then
  echo '{}'
  exit 0
fi

# --- Read hook input ---
HOOK_INPUT=$(cat)

# --- Read config ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config-reader.sh"

HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
resolve_config "$HOOK_CWD"

if [ "$SCAN_ENABLED" = "false" ]; then
  echo '{}'
  exit 0
fi

# --- Check if Lacework CLI is installed ---
# If not installed, skip context injection. No point telling Claude about scanning
# capabilities that aren't available yet. The user will discover /fortinet:cli-setup
# on their own or via the plugin README.
if ! command -v lacework &>/dev/null; then
  echo '{}'
  exit 0
fi

# --- Inject security context ---
# Adjust the scanning description based on the active mode.
if [ "$SCAN_MODE" = "pre-commit" ]; then
  SCAN_DESC="Security scanning: IaC and SCA scans run automatically before git commit. Critical/High findings in staged files will block the commit until resolved."
else
  SCAN_DESC="Security scanning: IaC and SCA scans run automatically after every task. Critical/High findings in changed files will block until resolved."
fi

CONTEXT="Fortinet Code Security is active in this session.

${SCAN_DESC}

When writing infrastructure code or modifying dependencies:
- Prefer restrictive defaults (least privilege, no public access, encrypted by default)
- The scanner checks for: open CIDR blocks, public storage buckets, missing encryption, overly permissive IAM, vulnerable dependency versions
- Writing secure code upfront avoids remediation loops after the scan

Available security skills:
- /fortinet:code-review — run a security scan on demand AND manage exceptions. Use this skill when users want to add exceptions to suppress findings. It has the full exception format, criteria, and .lacework/codesec.yaml structure.
- /fortinet:cli-setup — install and configure the Lacework CLI and scanning components
- /fortinet:settings — enable or disable scanning, switch scanning mode. NOT for exceptions — use /fortinet:code-review for that.

FortiCNAPP Code Security MCP tools (if the codesec MCP server is connected):
- mcp__codesec__get_weakness — look up detailed weakness info by FortiCNAPP ID (e.g. INJ-CMD-001, INPUT-XSS-001). Returns full description, severity, CWE mapping, remediation recommendation, and language-specific code examples showing vulnerable vs secure patterns. Use this BEFORE attempting to fix any SAST finding to get scanner-specific remediation guidance.
- mcp__codesec__list_weaknesses — list all FortiCNAPP weakness definitions with ID, name, category, and severity. Use to search for weakness types by category or to correlate findings.

When scan findings include a FortiCNAPP ID (like INJ-CMD-001, AUTH-CREDS-001, etc.), ALWAYS call mcp__codesec__get_weakness with that ID before fixing. The MCP response includes code examples with vulnerable and secure patterns that show exactly what the scanner expects — use these to guide your fix.

When scan findings are presented, users can fix the code, add exceptions, or leave as is. The /fortinet:code-review skill has the full exception format and instructions."

jq -n --arg ctx "$CONTEXT" '{ additionalContext: $ctx }'
