#!/bin/bash
# approve-permissions.sh — Auto-approve known Fortinet Code Security commands
# Runs as a PermissionRequest hook. Inspects the Bash command being requested
# and auto-approves commands the plugin needs to function.
# User's permissions.deny rules still take precedence over these approvals.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

approve() {
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "allow" }
    }
  }'
  exit 0
}

# --- File operations (Read/Write/Edit) on plugin-managed paths ---
if [[ "$TOOL_NAME" == "Read" || "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -z "$FILE_PATH" ] && exit 0

  # Auto-approve operations on ~/.lacework/ (plugin config, scan results, logs)
  [[ "$FILE_PATH" == "$HOME/.lacework/"* ]] && approve
  [[ "$FILE_PATH" == *"/.lacework/codesec.yaml" ]] && approve

  exit 0
fi

# --- Bash commands ---
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

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

# Temp directory creation (used by code-review skill and stop hook)
[[ "$COMMAND" =~ ^mktemp\  ]] && approve
[[ "$COMMAND" =~ ^TMPDIR=.*mktemp ]] && approve

# mkdir for plugin directories
[[ "$COMMAND" =~ ^mkdir\ -p.*\.lacework ]] && approve

# Everything else — don't approve, let normal permission flow handle it
exit 0
