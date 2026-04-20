#!/bin/bash
# approve-permissions.sh — Auto-approve known Fortinet Code Security commands
# Runs as a PermissionRequest hook. Inspects the Bash command being requested
# and auto-approves commands the plugin needs to function.
# User's permissions.deny rules still take precedence over these approvals.

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

[ -z "$COMMAND" ] && exit 0

approve() {
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }'
  exit 0
}

# Lacework CLI commands (scan, configure, component install)
[[ "$COMMAND" =~ ^lacework\  ]] && approve

# Plugin scripts (stop.sh, install-lw.sh, approve-permissions.sh)
[[ "$COMMAND" =~ scripts/stop\.sh ]] && approve
[[ "$COMMAND" =~ scripts/install-lw\.sh ]] && approve

# jq for JSON parsing (used by stop hook and skills)
[[ "$COMMAND" =~ ^jq\  ]] && approve

# brew install for cli-setup (lacework CLI, jq)
[[ "$COMMAND" =~ ^brew\ install ]] && approve
[[ "$COMMAND" =~ ^brew\ tap ]] && approve

# Hash utilities for scan marker dedup
[[ "$COMMAND" =~ ^sha256sum\  ]] && approve
[[ "$COMMAND" =~ ^shasum\  ]] && approve

# Everything else — don't approve, let normal permission flow handle it
exit 0
