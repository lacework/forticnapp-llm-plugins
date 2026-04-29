---
name: fortinet:cli-setup
description: Install and configure the Lacework CLI with IaC and SCA scanning components
user-invocable: true
---

# Fortinet Code Security Setup

Install and configure the Lacework CLI and security scanning components.

## Execution

Run the setup script:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-lw.sh"
```

The script will:
1. Install `jq` if missing
2. Install the Lacework CLI if missing
3. Ensure Lacework credentials are configured (see resolution order below)
4. Install the IaC and SCA scanning components

## Credential Resolution

The script resolves Lacework credentials in this order:

1. **Existing `~/.lacework.toml`** — if already configured (e.g. from a previous `lacework configure` run), it is used as-is with no prompts.
2. **Environment variables** — if `LW_ACCOUNT`, `LW_API_KEY`, and `LW_API_SECRET` are set, the script runs `lacework configure --noninteractive` to persist them. `LW_SUBACCOUNT` is optional.
3. **Interactive prompt** — if neither of the above applies and the script is running in a terminal, it runs `lacework configure` and the Lacework CLI prompts for the required fields.
4. **Failure** — if none of the above applies (non-TTY with no env vars and no config), the script exits with a message listing the options.

## If Setup Can't Find Credentials

This only happens in a non-interactive environment (e.g. CI) with no existing `~/.lacework.toml` and no env vars set. Tell the user to either:
- Export the variables and re-run:
  ```
  export LW_ACCOUNT="your-account.lacework.net"
  export LW_API_KEY="your-api-key"
  export LW_API_SECRET="your-api-secret"
  export LW_SUBACCOUNT="your-subaccount"  # optional, for multi-tenant accounts
  ```
- Or run `lacework configure` themselves in a terminal to create `~/.lacework.toml`, then re-run setup.

## Output

Report a summary of what happened:
- Which steps were skipped (already installed)
- Which steps were performed
- Final status: ready or failed (with error details)

If everything succeeded, tell the user they can now use `/fortinet:code-review` to scan their code.
