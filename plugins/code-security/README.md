# Fortinet Code Security Plugin for Claude Code

Automatically scans your IaC and dependency files for security vulnerabilities using Fortinet Code Security — directly within your Claude Code workflow.

## Features

- **Easy setup**: Run `/fortinet:cli-setup` to install and configure the Lacework CLI and scanning components
- **Auto-remediation**: Critical/high findings trigger Claude to fix issues without prompting
- **Parallel scanning**: IaC and SCA scans run simultaneously to minimize wait time
- **Smart scoping**: Only scans files changed in the current task, not the whole repo
- **Dependency caching**: SCA scans skipped when dependencies haven't changed

## Install & Configuration

> **Note**: This is a private plugin distributed via GitHub Releases. Only organization members with repo access can install it.

### Prerequisites

- Git SSH access or GitHub CLI auth (`gh auth login`) to the `lacework/forticnapp-llm-plugins` repo
- Lacework API credentials (provided by your team)

### Installation

In Claude Code, register the marketplace and install the plugin:

```
/plugin marketplace add lacework/forticnapp-llm-plugins
/plugin install code-security@fortinet-plugins
```

### Setup

After installing, run `/fortinet:cli-setup` in Claude Code. This installs the Lacework CLI, ensures credentials are configured, and installs the IaC and SCA scanning components.

Credentials are resolved in this order:

1. **Existing `~/.lacework.toml`** — if you've already run `lacework configure` at any point, setup uses it as-is.
2. **Environment variables** — preferred for CI / automation. Export them before running setup:
   ```bash
   export LW_ACCOUNT="your-account.lacework.net"
   export LW_API_KEY="your-api-key"
   export LW_API_SECRET="your-api-secret"
   export LW_SUBACCOUNT="your-subaccount"  # optional, for multi-tenant accounts
   ```
3. **Interactive prompt** — if neither of the above applies, setup runs `lacework configure` and the Lacework CLI prompts for the required fields. The result is persisted to `~/.lacework.toml` so subsequent runs skip this step.

> For credential distribution options, see [Credential Strategy](#credential-strategy).

## How It Works

### Scanning Modes

The plugin supports two scanning modes. Choose during setup (`/fortinet:cli-setup`) or switch anytime via `/fortinet:settings`.

| | Pre-commit (default) | Post-task |
|---|---|---|
| **When** | Before `git commit` | After every Claude Code task |
| **Scans** | Staged files only | All files changed in session |
| **Blocking** | Commit rejected | Claude re-invokes to fix |
| **Hook** | PreToolUse (Bash matcher) | Stop |

### Security Context (SessionStart Hook)

When a Claude Code session starts, the plugin injects security awareness context into the conversation. This serves two purposes:

1. **Proactive secure coding** — Claude knows security scanning is active and writes secure defaults from the start (restrictive CIDR blocks, no public access, encrypted by default), reducing the number of findings and remediation loops.
2. **Skill discoverability** — Claude knows about `/fortinet:code-review`, `/fortinet:cli-setup`, and `/fortinet:settings` and can suggest them when relevant.

The context injection respects the settings toggle — if scanning is disabled for a repo via `/fortinet:settings`, no context is injected. If the Lacework CLI is not yet installed, no context is injected either.

### Automatic Scanning (Stop Hook)

After every Claude Code task completes:

1. Changed file paths are extracted from the session transcript
2. Both IaC and SCA scanners launch in parallel on the project directory
3. Findings are filtered to only those related to your changed files (exact match or same directory)
4. Results are aggregated:
   - **Critical/High findings in changed files** → printed to stderr, Claude re-invokes automatically to remediate
   - **Pre-existing findings** → summarized as FYI (no re-invocation)
   - **No findings** → silent exit

### Slash Commands

#### `/fortinet:cli-setup`
Installs and configures the Lacework CLI with IaC and SCA scanning components. Resolves credentials from `~/.lacework.toml` if it exists, then environment variables (`LW_ACCOUNT`, `LW_API_KEY`, `LW_API_SECRET`, and optionally `LW_SUBACCOUNT`), otherwise runs `lacework configure` interactively.

#### `/fortinet:code-review`
Runs a security scan on IaC and dependency files in the current directory. Detects file types automatically and runs appropriate scanners (IaC, SCA, or both). Produces a unified report grouped by severity with remediation recommendations.

#### `/fortinet:settings`
Configure plugin settings — enable or disable automatic scanning globally or per repo. Settings are stored in `~/.lacework/plugins/code-security.json`. Supports:
- **Disable/enable scanning globally** — turns off the stop hook for all repos
- **Disable/enable scanning for a specific repo** — adds a per-repo override (longest path prefix match wins)
- **Show current settings** — displays the global default and any repo overrides

## Session Lifecycle

```
Session starts
  └─> scripts/session-start.sh fires
        └─> Scanning disabled or CLI missing? → no context injected
        └─> Scanning enabled? → inject security awareness context (mode-aware)

First time setup
  └─> User runs /fortinet:cli-setup
        └─> scripts/install-lw.sh runs
        └─> Installs jq, Lacework CLI, configures credentials, installs components
        └─> User selects scanning mode (pre-commit or post-task)

Developer prompts Claude → Claude writes/edits files (with security awareness)

Pre-commit mode:
  Claude runs git commit
    └─> scripts/pre-commit-scan.sh fires (PreToolUse hook)
          └─> Not a git commit? → allow
          └─> No staged files? → allow
          └─> Scan staged files → lacework iac scan & lacework sca scan &
          └─> Filter findings to staged files
          └─> No Critical/High in staged files → allow commit
          └─> Critical/High in staged files → block commit → Claude fixes or adds exception → retry

Post-task mode:
  Claude Code task completes
    └─> scripts/stop.sh fires
          └─> No changed files? → exit 0 (silent)
          └─> Changed files found? → lacework iac scan & lacework sca scan &
          └─> Filter findings to changed files
          └─> No findings in changed files → exit 0
          └─> Critical/high in changed files → exit 2 → Claude auto-remediates
```

## Credential Strategy

Phase 1 uses a shared service account. Setup accepts credentials in the following forms (resolved in order):

| Option | How it works | Recommendation |
|---|---|---|
| **A: Existing `~/.lacework.toml`** | The Lacework CLI writes this file on `lacework configure`. If present, setup uses it as-is. | Default — lowest friction once configured |
| **B: Shell env vars** | Export `LW_ACCOUNT`, `LW_API_KEY`, `LW_API_SECRET` (and optionally `LW_SUBACCOUNT`). Setup runs `lacework configure --noninteractive`, which writes `~/.lacework.toml`. | Preferred for CI / automation |
| **C: Interactive prompt** | If neither of the above is present and setup is running in a terminal, it invokes `lacework configure` and the CLI prompts for credentials. | First-run bootstrap on a developer machine |
| **D: Baked-in key** | Credentials hardcoded in `plugin.json`. Distributed with the plugin. | Use only for fully internal, air-gapped environments |

The shared service account MUST be scoped to the Code Security product.

## Local Development

### 1. Install the plugin from your local clone

```bash
git clone git@github.com:lacework/forticnapp-llm-plugins.git
cd forticnapp-llm-plugins
git checkout dev  # development branch

# Register marketplace and install
claude plugin marketplace add $PWD
claude plugin install code-security@fortinet-plugins
```

> **Note**: When the plugin is installed, it is **copied to the cache** (`~/.claude/plugins/cache/...`). Edits to your local source directory are NOT picked up automatically — you must reinstall after making changes:
> ```bash
> claude plugin uninstall code-security@fortinet-plugins
> claude plugin install code-security@fortinet-plugins
> ```

### 2. Run setup

Run `/fortinet:cli-setup` in Claude Code, or run the script directly:

```bash
bash scripts/install-lw.sh
```

Setup will use your existing `~/.lacework.toml` if present, otherwise fall back to env vars, otherwise prompt interactively via `lacework configure`. For non-interactive runs (e.g. CI) you can export credentials first:

```bash
export LW_ACCOUNT="your-account.lacework.net"
export LW_API_KEY="your-api-key"
export LW_API_SECRET="your-api-secret"
export LW_SUBACCOUNT="your-subaccount"  # optional

bash scripts/install-lw.sh
```

### 3. Test the Stop hook directly

Pipe a crafted session JSON to simulate Claude Code completing a task. The `file_path` values drive which scanner(s) are invoked.

**IaC scan (Terraform):**
```bash
echo '{
  "transcript": [{
    "tool_uses": [{
      "tool_name": "Write",
      "tool_input": { "file_path": "tests/fixtures/vulnerable.tf" }
    }]
  }]
}' | bash scripts/stop.sh
```

**SCA scan (package.json):**
```bash
echo '{
  "transcript": [{
    "tool_uses": [{
      "tool_name": "Write",
      "tool_input": { "file_path": "tests/fixtures/vulnerable-package.json" }
    }]
  }]
}' | bash scripts/stop.sh
```

**Both scanners in parallel:**
```bash
echo '{
  "transcript": [{
    "tool_uses": [
      { "tool_name": "Write", "tool_input": { "file_path": "tests/fixtures/vulnerable.tf" } },
      { "tool_name": "Write", "tool_input": { "file_path": "tests/fixtures/vulnerable-package.json" } }
    ]
  }]
}' | bash scripts/stop.sh
```

**No scan (source files only):**
```bash
echo '{
  "transcript": [{
    "tool_uses": [{
      "tool_name": "Edit",
      "tool_input": { "file_path": "src/app.py" }
    }]
  }]
}' | bash scripts/stop.sh
echo "Exit code: $?"
```

### 4. Run the automated test suite

```bash
bash plugins/code-security/tests/test-stop.sh
```

### Test Fixtures

| File | Purpose |
|---|---|
| `tests/fixtures/vulnerable.tf` | Terraform with known misconfigurations (S3 public access, unrestricted SSH, wildcard IAM) |
| `tests/fixtures/vulnerable-package.json` | npm manifest with known vulnerable dependency versions |

## Platform Support

| Platform | Install Method |
|---|---|
| macOS (Intel + Apple Silicon) with Homebrew | `brew install lacework/tap/lacework-cli` |
| macOS without Homebrew | curl installer |
| Linux (x86_64, arm64) | curl installer |
| Windows | Not supported in Phase 1 |

## Known Limitations

### Pre-commit mode and subagents

Claude Code's `PreToolUse` hooks do not fire for tool calls made by subagents spawned via the Agent tool ([anthropics/claude-code#34692](https://github.com/anthropics/claude-code/issues/34692)). This means if a subagent runs `git commit`, the pre-commit scan will not trigger.

**Workaround:** Have subagents make code changes (Write/Edit) without committing. The main session stages and commits after reviewing, which triggers the pre-commit scan normally.

This is a Claude Code platform limitation, not a plugin issue. The post-task mode (Stop hook) has the same limitation — it fires on main session task completion, not on individual subagent completions.

## Requirements

- bash 3.2+
- macOS 13+ or Linux (Ubuntu 22.04+ recommended)
- Internet access for initial install

## Phase 2 Roadmap

- MCP server with `lacework_scan_file`, `lacework_get_findings`, `lacework_explain_finding` tools
- SAST integration
- Per-user authentication
- Windows support
- Async scan mode with background notification
