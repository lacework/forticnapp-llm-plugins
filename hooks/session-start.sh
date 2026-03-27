#!/bin/bash
# session-start.sh — Fortinet Code Security plugin installer
# Runs on every SessionStart. Idempotent.

INSTALL_MARKER="${CLAUDE_PLUGIN_DATA}/.lw-installed"
VERSION_FILE="${CLAUDE_PLUGIN_DATA}/.lw-version"
REQUIRED_VERSION="1.3.1"

# Fast exit if already installed at current version — skip update check to avoid blocking
if [ -f "$INSTALL_MARKER" ] && \
   [ "$(cat "$VERSION_FILE" 2>/dev/null)" = "$REQUIRED_VERSION" ]; then
  exit 0
fi

echo "Fortinet Code Security: first-time setup..." >&2
mkdir -p "$CLAUDE_PLUGIN_DATA"

# Step 1: Install jq (required for session JSON parsing in stop.sh)
if ! command -v jq &>/dev/null; then
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  if [ "$OS" = "darwin" ] && command -v brew &>/dev/null; then
    brew install jq >&2 || {
      echo "ERROR: Failed to install jq via brew. Install manually: https://jqlang.org/download/" >&2
      exit 1
    }
  elif [ "$OS" = "linux" ]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y jq >&2
    elif command -v yum &>/dev/null; then
      sudo yum install -y jq >&2
    elif command -v apk &>/dev/null; then
      sudo apk add jq >&2
    else
      echo "ERROR: Cannot install jq — unsupported package manager. Install manually: https://jqlang.org/download/" >&2
      exit 1
    fi
  else
    echo "ERROR: Cannot install jq on this OS. Install manually: https://jqlang.org/download/" >&2
    exit 1
  fi
  command -v jq &>/dev/null || {
    echo "ERROR: jq not found after install" >&2; exit 1
  }
fi

# Step 2: Install Lacework CLI
if ! command -v lacework &>/dev/null; then
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  if [ "$OS" = "darwin" ] && command -v brew &>/dev/null; then
    brew install lacework/tap/lacework-cli >&2 || {
      echo "ERROR: brew install failed. See https://docs.lacework.net/cli" >&2
      exit 1
    }
  elif [ "$OS" = "linux" ] || [ "$OS" = "darwin" ]; then
    curl -s https://raw.githubusercontent.com/lacework/go-sdk/main/cli/install.sh \
      | bash >&2 || {
      echo "ERROR: curl install failed. See https://docs.lacework.net/cli" >&2
      exit 1
    }
  else
    echo "ERROR: Unsupported OS. Install manually: https://docs.lacework.net/cli" >&2
    exit 1
  fi
fi

command -v lacework &>/dev/null || {
  echo "ERROR: lacework CLI not found after install" >&2; exit 1
}

# Step 3: Configure credentials
lacework configure --account "${LW_ACCOUNT}" \
  --api_key "${LW_API_KEY}" \
  --api_secret "${LW_API_SECRET}" \
  --noninteractive >&2 || {
  echo "ERROR: lacework configure failed" >&2; exit 1
}

# Step 4 & 5: Install components
for COMPONENT in iac sca; do
  echo "Installing $COMPONENT component..." >&2
  lacework component install "$COMPONENT" >&2 || {
    echo "ERROR: Failed to install $COMPONENT component" >&2; exit 1
  }
done

# Step 6: Verify
INSTALLED=$(lacework component list 2>/dev/null)
for COMPONENT in iac sca; do
  echo "$INSTALLED" | grep -q "$COMPONENT" || {
    echo "ERROR: $COMPONENT component not found after install" >&2; exit 1
  }
done

# Mark installed
echo "$REQUIRED_VERSION" > "$VERSION_FILE"
touch "$INSTALL_MARKER"
echo "Fortinet Code Security ready (IaC + SCA components installed)" >&2
exit 0
