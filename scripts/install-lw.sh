#!/bin/bash
# install-lw.sh — Idempotent Lacework CLI install helper
# Can be called directly or sourced by session-start.sh

set -euo pipefail

install_lacework_cli() {
  if command -v lacework &>/dev/null; then
    echo "Lacework CLI already installed: $(lacework version 2>/dev/null || echo 'unknown version')" >&2
    return 0
  fi

  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  echo "Installing Lacework CLI for $OS/$ARCH..." >&2

  if [ "$OS" = "darwin" ] && command -v brew &>/dev/null; then
    echo "Using Homebrew..." >&2
    brew install lacework/tap/lacework-cli >&2 || {
      echo "ERROR: brew install failed. See https://docs.lacework.net/cli" >&2
      return 1
    }
  elif [ "$OS" = "linux" ] || [ "$OS" = "darwin" ]; then
    echo "Using curl installer..." >&2
    curl -s https://raw.githubusercontent.com/lacework/go-sdk/main/cli/install.sh \
      | bash >&2 || {
      echo "ERROR: curl install failed. See https://docs.lacework.net/cli" >&2
      return 1
    }
  else
    echo "ERROR: Unsupported OS '$OS'. Install manually: https://docs.lacework.net/cli" >&2
    return 1
  fi

  command -v lacework &>/dev/null || {
    echo "ERROR: lacework CLI not found after install attempt" >&2
    return 1
  }

  echo "Lacework CLI installed successfully" >&2
  return 0
}

# Run if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  install_lacework_cli
fi
