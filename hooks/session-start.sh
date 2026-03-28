#!/bin/bash
# session-start.sh — Fortinet Code Security plugin installer
# Runs on every SessionStart. MUST be non-blocking.

INSTALL_MARKER="${CLAUDE_PLUGIN_DATA}/.lw-installed"
VERSION_FILE="${CLAUDE_PLUGIN_DATA}/.lw-version"
REQUIRED_VERSION="1.3.6"

# Fast exit if already installed at current version
if [ -f "$INSTALL_MARKER" ] && \
   [ "$(cat "$VERSION_FILE" 2>/dev/null)" = "$REQUIRED_VERSION" ]; then
  exit 0
fi

mkdir -p "$CLAUDE_PLUGIN_DATA"

# Check if dependencies are already installed (non-blocking check)
if command -v jq &>/dev/null && command -v lacework &>/dev/null; then
  # Dependencies exist - just mark as installed and exit quickly
  echo "$REQUIRED_VERSION" > "$VERSION_FILE"
  touch "$INSTALL_MARKER"
  exit 0
fi

# Dependencies missing - print setup instructions and exit (don't block)
echo "Fortinet Code Security: Dependencies not found. Run setup manually:" >&2
echo "  brew install jq lacework/tap/lacework-cli" >&2
echo "  lacework configure --noninteractive" >&2
echo "  lacework component install iac sca" >&2

# Still mark as installed to prevent blocking on every session
echo "$REQUIRED_VERSION" > "$VERSION_FILE"
touch "$INSTALL_MARKER"
exit 0
