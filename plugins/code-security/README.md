# Fortinet Code Security Plugin for Claude Code

Automatically scans your IaC and dependency files for security vulnerabilities using Fortinet Code Security — directly within your Claude Code workflow.

## Features

- **Easy setup**: Run `/fortinet-setup` to install and configure the Lacework CLI and scanning components
- **Auto-remediation**: Critical/high findings trigger Claude to fix issues without prompting
- **Parallel scanning**: IaC and SCA scans run simultaneously to minimize wait time
- **Smart scoping**: Only scans files changed in the current task, not the whole repo
- **Dependency caching**: SCA scans skipped when dependencies haven't changed

## Install & Configuration

> **Note**: This is a private plugin distributed via GitHub Releases. Only organization members with repo access can install it.

### Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Lacework API credentials (provided by your team)

### Installation

Download and install the plugin:

```bash
# Download and extract (latest version)
gh release download -R lacework/forticnapp-llm-plugins -A zip
unzip -o forticnapp-llm-plugins-*.zip
cd forticnapp-llm-plugins-*

# Or download a specific version
# gh release download v1.3.4 -R lacework/forticnapp-llm-plugins -A zip
# unzip -o forticnapp-llm-plugins-1.3.4.zip
# cd forticnapp-llm-plugins-1.3.4

# Register marketplace and install (marketplace name "fortinet-plugins" is defined in .claude-plugin/marketplace.json)
claude plugin marketplace add $PWD
claude plugin install code-security@fortinet-plugins
```

Available versions are listed on the [Releases](../../releases) page.

### Setup

After installing, run `/fortinet-setup` in Claude Code. This installs the Lacework CLI, ensures credentials are configured, and installs the IaC and SCA scanning components.

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

## Releases

Releases are managed automatically via GitHub Actions:

- **Auto-release**: Every push to `main` triggers a version bump and release. The bump type is determined from [conventional commit](https://www.conventionalcommits.org/) prefixes:

  | Commit prefix | Version bump |
  |---|---|
  | `feat!:`, `fix!:` (breaking change) | Major (`1.0.0` → `2.0.0`) |
  | `feat:` | Minor (`1.0.0` → `1.1.0`) |
  | `fix:`, `chore:`, `refactor:`, etc. | Patch (`1.0.0` → `1.0.1`) |

- **Manual release**: Go to **Actions → Release → Run workflow** and enter a specific version (e.g. `2.1.0`) to cut a release at an exact version. Use this to skip ahead, backport, or hotfix.

Each release publishes a `.zip` artifact and updates the install command in the release notes.

## How It Works

### Automatic Scanning (Stop Hook)

After every Claude Code task completes:

1. Changed file paths are extracted from the session
2. Files are classified as IaC (`*.tf`, `*.hcl`, etc.) or SCA manifests (`package.json`, `go.mod`, etc.)
3. Appropriate scanners launch in parallel
4. Results are aggregated:
   - **Critical/High findings** → printed to stderr, Claude re-invokes automatically to remediate
   - **Medium/Low findings** → printed to stdout as informational (no re-invocation)
   - **No findings** → silent exit

### File-Type Routing

**IaC scan** (`lacework iac scan`):

| Match | Examples |
|---|---|
| `*.tf`, `*.tfvars`, `*.hcl` | Terraform, HCL configs |
| `*.bicep` | Azure Bicep |
| `*.template` | CloudFormation templates |
| `*.yaml`/`*.json` in `k8s/`, `kubernetes/`, `helm/`, `charts/`, `manifests/`, `argocd/`, `flux/` | Kubernetes manifests, Helm charts |
| `*.yaml`/`*.json` in `cloudformation/`, `infra/`, `iac/`, `ansible/`, `playbooks/` | CloudFormation, Ansible |
| `Pulumi.yaml`, `Pulumi.*.yaml` | Pulumi stacks |
| `serverless.yml`, `serverless.yaml` | Serverless Framework |
| `docker-compose*.yml`, `compose.yml` | Docker Compose |
| `cdk.json` | AWS CDK |

**SCA scan** (`lacework sca scan`):

| Match | Ecosystem |
|---|---|
| `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `npm-shrinkwrap.json` | Node/JS |
| `requirements*.txt`, `Pipfile`, `pyproject.toml`, `poetry.lock`, `setup.py`, `setup.cfg` | Python |
| `go.mod`, `go.sum` | Go |
| `pom.xml`, `build.gradle`, `build.gradle.kts`, `*.gradle` | Java/Kotlin |
| `Gemfile`, `Gemfile.lock` | Ruby |
| `Cargo.toml`, `Cargo.lock` | Rust |
| `composer.json`, `composer.lock` | PHP |
| `*.csproj`, `*.vbproj`, `*.fsproj`, `packages.config` | .NET |
| `Package.swift`, `Package.resolved`, `Podfile`, `Podfile.lock` | Swift/iOS |
| `build.sbt` | Scala |
| `mix.exs`, `mix.lock` | Elixir |
| `pubspec.yaml`, `pubspec.lock` | Dart/Flutter |

**No scan**: source-only changes (`.py`, `.js`, `.ts`, `.go`, etc.) — SAST out of scope for Phase 1.

### Slash Commands

#### `/fortinet-setup`
Installs and configures the Lacework CLI with IaC and SCA scanning components. Resolves credentials from `~/.lacework.toml` if it exists, then environment variables (`LW_ACCOUNT`, `LW_API_KEY`, `LW_API_SECRET`, and optionally `LW_SUBACCOUNT`), otherwise runs `lacework configure` interactively.

#### `/fortinet-review`
Runs a security scan on IaC and dependency files in the current directory. Detects file types automatically and runs appropriate scanners (IaC, SCA, or both). Produces a unified report grouped by severity with remediation recommendations.

## Session Lifecycle

```
First time setup
  └─> User runs /fortinet-setup
        └─> scripts/install-lw.sh runs
        └─> Installs jq, Lacework CLI, configures credentials, installs components

Developer prompts Claude → Claude writes/edits files

Claude Code task completes
  └─> scripts/stop.sh fires
        └─> No changed files? → exit 0 (silent)
        └─> IaC files changed? → lacework iac scan &
        └─> Manifest files changed? → lacework sca scan & (or cache hit)
        └─> Wait for scans...
        └─> Clean / medium/low → exit 0
        └─> Critical/high → exit 2 → Claude auto-remediates
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

Run `/fortinet-setup` in Claude Code, or run the script directly:

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
