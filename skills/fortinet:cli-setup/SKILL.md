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
1. Check that required environment variables are set (`LW_ACCOUNT`, `LW_API_KEY`, `LW_API_SECRET`)
2. Install `jq` if missing
3. Install the Lacework CLI if missing
4. Configure the Lacework CLI with the provided credentials
5. Install the IaC and SCA scanning components

## If Environment Variables Are Missing

Tell the user which variables need to be set:
```
export LW_ACCOUNT="your-account.lacework.net"
export LW_API_KEY="your-api-key"
export LW_API_SECRET="your-api-secret"
export LW_SUBACCOUNT="your-subaccount"  # optional, for multi-tenant accounts
```

Then ask them to run `/fortinet:cli-setup` again.

## Output

Report a summary of what happened:
- Which steps were skipped (already installed)
- Which steps were performed
- Final status: ready or failed (with error details)

If everything succeeded, tell the user they can now use `/fortinet:code-review` to scan their code.
