#!/bin/bash
# install-lw.sh — Idempotent Lacework CLI installer and configurator
# Installs jq, Lacework CLI, ensures credentials are configured, and installs IaC/SCA components.
# Can be called directly or sourced.
#
# Credential resolution (in order):
#   1. ~/.lacework.toml already exists → use it as-is
#   2. LW_ACCOUNT + LW_API_KEY + LW_API_SECRET (+ optional LW_SUBACCOUNT) set →
#      run `lacework configure --noninteractive`
#   3. Interactive TTY → run `lacework configure` and let the CLI prompt
#   4. Otherwise → error

set -euo pipefail

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
LACEWORK_TOML="${HOME}/.lacework.toml"

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

configure_lacework_from_env() {
  echo "Configuring Lacework CLI from environment variables..." >&2
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

configure_lacework_interactive() {
  echo "No Lacework configuration found — launching interactive setup..." >&2
  echo "(The Lacework CLI will prompt for account, API key, and secret.)" >&2
  lacework configure || {
    echo "ERROR: interactive 'lacework configure' failed" >&2
    return 1
  }
  echo "Lacework CLI configured successfully" >&2
}

validate_lacework_toml() {
  # Checks that $LACEWORK_TOML has non-empty values for account, api_key, api_secret.
  # Returns 0 if all three are populated, 1 otherwise. Populates $MISSING_TOML_FIELDS.
  local field
  MISSING_TOML_FIELDS=()
  for field in account api_key api_secret; do
    # Match: field = "non-empty string" anywhere in the file.
    # Skips: field = "", missing field entirely.
    if ! grep -Eq "^[[:space:]]*${field}[[:space:]]*=[[:space:]]*\"[^\"]+\"" "$LACEWORK_TOML"; then
      MISSING_TOML_FIELDS+=("$field")
    fi
  done
  [ ${#MISSING_TOML_FIELDS[@]} -eq 0 ]
}

ensure_lacework_configured() {
  if [ -f "$LACEWORK_TOML" ]; then
    if validate_lacework_toml; then
      echo "Lacework CLI already configured — using $LACEWORK_TOML" >&2
      return 0
    fi
    echo "WARNING: $LACEWORK_TOML exists but is missing values for: ${MISSING_TOML_FIELDS[*]}" >&2
    echo "Falling back to environment variables or interactive setup..." >&2
  fi

  if [ -n "${LW_ACCOUNT:-}" ] && [ -n "${LW_API_KEY:-}" ] && [ -n "${LW_API_SECRET:-}" ]; then
    configure_lacework_from_env
    return $?
  fi

  if [ -t 0 ]; then
    configure_lacework_interactive
    return $?
  fi

  echo "ERROR: No Lacework credentials configured." >&2
  echo "Pick one of:" >&2
  echo "  1. Run setup from an interactive terminal — 'lacework configure' will prompt" >&2
  echo "  2. Export LW_ACCOUNT, LW_API_KEY, LW_API_SECRET (and optional LW_SUBACCOUNT) and re-run" >&2
  echo "  3. Run 'lacework configure' yourself to create $LACEWORK_TOML, then re-run setup" >&2
  return 1
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

  install_jq || return 1
  install_lacework_cli || return 1
  ensure_lacework_configured || return 1
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
