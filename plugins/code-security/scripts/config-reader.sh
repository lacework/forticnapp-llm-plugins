#!/bin/bash
# config-reader.sh — Shared config resolution for Fortinet Code Security hooks
#
# Sourced by stop.sh, session-start.sh, and pre-commit-scan.sh.
# Reads ~/.lacework/plugins/code-security.json and resolves:
#   - SCAN_MODE: "pre-commit" or "post-task"
#   - SCAN_ENABLED: "true" or "false" (resolved for the given cwd)
#
# Supports two config formats:
#   v2 (new): hooks.mode, hooks.enabled, hooks.overrides
#   v1 (legacy): hooks.stop.enabled, hooks.stop.overrides (assumes mode=post-task)
#
# Usage:
#   source "$(dirname "$0")/config-reader.sh"
#   resolve_config "/path/to/cwd"
#   # Now SCAN_MODE and SCAN_ENABLED are set

SCAN_MODE="pre-commit"
SCAN_ENABLED="true"

resolve_config() {
  local cwd="$1"
  cwd="${cwd%/}"  # Normalize: strip trailing slash

  local config_file="$HOME/.lacework/plugins/code-security.json"

  # If config missing or jq unavailable, use defaults
  if [ ! -f "$config_file" ] || ! command -v jq &>/dev/null; then
    SCAN_MODE="pre-commit"
    SCAN_ENABLED="true"
    return 0
  fi

  # Detect config format: v2 has hooks.mode, v1 has hooks.stop
  local has_mode
  has_mode=$(jq -r '.hooks.mode // empty' "$config_file" 2>/dev/null)

  if [ -n "$has_mode" ]; then
    # --- v2 format ---
    SCAN_MODE="$has_mode"

    # Global kill switch: if hooks.enabled is explicitly false, scanning is
    # off everywhere — overrides are ignored. This is an absolute off switch.
    # Note: jq's // operator treats false as empty, so we use if/then/else.
    local global_enabled
    global_enabled=$(jq -r 'if .hooks.enabled == null then "true" else (.hooks.enabled | tostring) end' "$config_file" 2>/dev/null)
    if [ "$global_enabled" = "false" ]; then
      SCAN_ENABLED="false"
      return 0
    fi

    # Global is enabled — check per-repo overrides (longest prefix match wins)
    SCAN_ENABLED=$(jq -r --arg cwd "$cwd" '
      .hooks as $h |
      [ $h.overrides[]? | select(.path != null) | .path as $p |
        select($cwd | startswith(($p | rtrimstr("/")))) ] |
      sort_by(.path | length) | last // null |
      if . == null then "true" elif .enabled == null then "true" else (.enabled | tostring) end
    ' "$config_file" 2>/dev/null)
  else
    # --- v1 format (legacy) ---
    SCAN_MODE="post-task"

    # Same global kill switch for v1
    local global_enabled_v1
    global_enabled_v1=$(jq -r 'if .hooks.stop.enabled == null then "true" else (.hooks.stop.enabled | tostring) end' "$config_file" 2>/dev/null)
    if [ "$global_enabled_v1" = "false" ]; then
      SCAN_ENABLED="false"
      return 0
    fi

    # Global is enabled — check per-repo overrides
    SCAN_ENABLED=$(jq -r --arg cwd "$cwd" '
      .hooks.stop as $stop |
      [ $stop.overrides[]? | select(.path != null) | .path as $p |
        select($cwd | startswith(($p | rtrimstr("/")))) ] |
      sort_by(.path | length) | last // null |
      if . == null then "true" elif .enabled == null then "true" else (.enabled | tostring) end
    ' "$config_file" 2>/dev/null)
  fi

  # Default to enabled if resolution failed
  [ -z "$SCAN_ENABLED" ] && SCAN_ENABLED="true"
  [ -z "$SCAN_MODE" ] && SCAN_MODE="pre-commit"
}
