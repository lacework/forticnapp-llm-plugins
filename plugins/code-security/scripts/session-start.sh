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
# Config check logic:
#   Reuses the same resolution as stop.sh:
#   1. Read ~/.lacework/plugins/code-security.json
#   2. Check hooks.stop.overrides[] for longest path prefix match on cwd
#   3. Fall back to hooks.stop.enabled global default
#   4. If config missing or malformed, default to enabled

# --- Require jq ---
# All output paths use jq to produce valid JSON. If jq is missing, output empty
# JSON rather than risking malformed output that could break session start.
if ! command -v jq &>/dev/null; then
  echo '{}'
  exit 0
fi

# --- Read hook input ---
HOOK_INPUT=$(cat)

# --- Check if scanning is enabled for this repo ---
# Uses the same config file and resolution logic as stop.sh.
# If scanning is disabled, we skip context injection — no point telling Claude
# about security scanning if it's turned off for this repo.
PLUGIN_CONFIG="$HOME/.lacework/plugins/code-security.json"
if [ -f "$PLUGIN_CONFIG" ] && command -v jq &>/dev/null; then
  HOOK_CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty')
  HOOK_CWD="${HOOK_CWD%/}"

  ENABLED=$(jq -r --arg cwd "$HOOK_CWD" '
    .hooks.stop as $stop |
    ($stop.enabled // true) as $global |
    [ $stop.overrides[]? | select(.path != null) | .path as $p |
      select($cwd | startswith(($p | rtrimstr("/")))) ] |
    sort_by(.path | length) | last // { "enabled": $global } | .enabled
  ' "$PLUGIN_CONFIG" 2>/dev/null)

  if [ "$ENABLED" = "false" ]; then
    # Scanning disabled for this repo — inject nothing
    echo '{}'
    exit 0
  fi
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
# This message becomes part of Claude's system context for the entire session.
# It is NOT shown to the user — it shapes Claude's behavior silently.
CONTEXT="Fortinet Code Security is active in this session.

Security scanning: IaC and SCA scans run automatically after every task. Critical/High findings in changed files will block until resolved.

When writing infrastructure code or modifying dependencies:
- Prefer restrictive defaults (least privilege, no public access, encrypted by default)
- The scanner checks for: open CIDR blocks, public storage buckets, missing encryption, overly permissive IAM, vulnerable dependency versions
- Writing secure code upfront avoids remediation loops after the scan

Available security skills:
- /fortinet:code-review — run a full IaC and SCA security scan on demand
- /fortinet:cli-setup — install and configure the Lacework CLI and scanning components
- /fortinet:settings — enable or disable automatic scanning globally or per repo"

jq -n --arg ctx "$CONTEXT" '{ additionalContext: $ctx }'
