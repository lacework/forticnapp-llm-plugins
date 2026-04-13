#!/bin/bash
# install-lw.sh — Idempotent Lacework CLI installer and configurator
# Installs jq, Lacework CLI, configures credentials, and installs IaC/SCA components.
# Can be called directly or sourced.
#
# Required environment variables:
#   LW_ACCOUNT    - Lacework account URL (e.g. lacework.lacework.net)
#   LW_API_KEY    - Lacework API key
#   LW_API_SECRET - Lacework API secret
#
# Optional environment variables:
#   LW_SUBACCOUNT - Lacework subaccount (if using a multi-tenant account)

set -euo pipefail

OS=$(uname -s | tr '[:upper:]' '[:lower:]')

check_env_vars() {
  local missing=()
  [ -z "${LW_ACCOUNT:-}" ]    && missing+=("LW_ACCOUNT")
  [ -z "${LW_API_KEY:-}" ]    && missing+=("LW_API_KEY")
  [ -z "${LW_API_SECRET:-}" ] && missing+=("LW_API_SECRET")

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required environment variables: ${missing[*]}" >&2
    echo "Set them before running setup:" >&2
    for var in "${missing[@]}"; do
      echo "  export $var=\"your-value\"" >&2
    done
    return 1
  fi
  return 0
}

install_jq() {
  if command -v jq &>/dev/null; then
    echo "jq already installed: $(jq --version 2>/dev/null)" >&2
    return 0
  fi

  echo "Installing jq..." >&2

  if [ "$OS" = "darwin" ] && command -v brew &>/dev/null; then
    brew install jq >&2
  elif [ "$OS" = "linux" ]; then
    if command -v apt-get &>/dev/null; then
      sudo apt-get install -y jq >&2
    elif command -v yum &>/dev/null; then
      sudo yum install -y jq >&2
    elif command -v apk &>/dev/null; then
      sudo apk add jq >&2
    else
      echo "ERROR: No supported package manager found. Install jq manually." >&2
      return 1
    fi
  else
    echo "ERROR: Unsupported OS '$OS'. Install jq manually." >&2
    return 1
  fi

  command -v jq &>/dev/null || {
    echo "ERROR: jq not found after install attempt" >&2
    return 1
  }
  echo "jq installed successfully" >&2
}

install_lacework_cli() {
  if command -v lacework &>/dev/null; then
    echo "Lacework CLI already installed: $(lacework version 2>/dev/null || echo 'unknown version')" >&2
    return 0
  fi

  echo "Installing Lacework CLI for $OS/$(uname -m)..." >&2

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
}

configure_lacework() {
  echo "Configuring Lacework CLI..." >&2
  local configure_args=(
    --noninteractive
    --account "$LW_ACCOUNT"
    --api_key "$LW_API_KEY"
    --api_secret "$LW_API_SECRET"
  )
  if [ -n "${LW_SUBACCOUNT:-}" ]; then
    configure_args+=(--subaccount "$LW_SUBACCOUNT")
  fi
  lacework configure "${configure_args[@]}" >&2 || {
    echo "ERROR: lacework configure failed" >&2
    return 1
  }
  echo "Lacework CLI configured successfully" >&2
}

install_components() {
  echo "Installing IaC and SCA components..." >&2
  lacework component install iac >&2 || {
    echo "ERROR: Failed to install iac component" >&2
    return 1
  }
  lacework component install sca >&2 || {
    echo "ERROR: Failed to install sca component" >&2
    return 1
  }
  echo "IaC and SCA components installed successfully" >&2
}

run_setup() {
  echo "=== Fortinet Code Security Setup ===" >&2

  check_env_vars || return 1
  install_jq || return 1
  install_lacework_cli || return 1
  configure_lacework || return 1
  install_components || return 1

  echo "" >&2
  echo "=== Setup complete ===" >&2
  echo "You can now use /fortinet-review to scan your code." >&2
  return 0
}

# Run if executed directly (not sourced)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run_setup
fi
