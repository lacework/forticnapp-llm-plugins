# Fortinet Code Security Plugin for Claude Code

Automatically scans your IaC and dependency files for security vulnerabilities using Lacework Code Security — directly within your Claude Code workflow.

## Features

- **Zero setup**: Lacework CLI and components install automatically on first session
- **Auto-remediation**: Critical/high findings trigger Claude to fix issues without prompting
- **Parallel scanning**: IaC and SCA scans run simultaneously to minimize wait time
- **Smart scoping**: Only scans files changed in the current task, not the whole repo
- **Dependency caching**: SCA scans skipped when dependencies haven't changed

## Install & Configuration

Set your Lacework API credentials, then install the plugin:

```bash
export LW_API_KEY="your-api-key"
export LW_API_SECRET="your-api-secret"

# Latest version
claude plugin install https://github.com/lacework-dev/fortinet-code-security-plugin/releases/latest/download/fortinet-code-security-plugin.zip

# Or a specific version
claude plugin install https://github.com/lacework-dev/fortinet-code-security-plugin/releases/download/v1.2.0/fortinet-code-security-plugin-v1.2.0.zip
```

Replace `v1.2.0` with the version you want. Available versions are listed on the [Releases](../../releases) page.

The plugin is pre-configured with a shared service account (`lacework.lacework.net`). On first session start it installs all dependencies and writes credentials to `~/.lacework.toml` with `chmod 600` — no further setup required.

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

#### `/lacework:scan`
Runs an on-demand scan on the current file or directory.

#### `/lacework:review`
Full security review before committing or opening a PR. Scans all files changed since the last git commit and produces a structured report.

## Session Lifecycle

```
Claude Code session starts
  └─> session-start.sh fires
        └─> Already installed? → exit 0 in <100ms
        └─> First time? → Install CLI, components, write credentials

Developer prompts Claude → Claude writes/edits files

Claude Code task completes
  └─> stop.sh fires
        └─> No changed files? → exit 0 (silent)
        └─> IaC files changed? → lacework iac scan &
        └─> Manifest files changed? → lacework sca scan & (or cache hit)
        └─> Wait for scans...
        └─> Clean / medium/low → exit 0
        └─> Critical/high → exit 2 → Claude auto-remediates
```

## Credential Strategy

Phase 1 uses a shared service account. Two distribution options are available:

| Option | How it works | Recommendation |
|---|---|---|
| **A: Shell env vars** | Add `LW_API_KEY` and `LW_API_SECRET` to `~/.zshrc`. Plugin interpolates at install time. | Preferred — credentials not in version control |
| **B: Baked-in key** | Credentials hardcoded in `plugin.json`. Distributed with the plugin. | Use only for fully internal, air-gapped environments |

The shared service account MUST be:
- Read-only (scan access only)
- Scoped to the Code Security product
- Rotated on a 90-day cycle

## Testing

Run the included test suite:

```bash
# Test session-start.sh logic
bash tests/test-session-start.sh

# Test stop.sh logic
bash tests/test-stop.sh
```

### Test Fixtures

| File | Purpose |
|---|---|
| `tests/fixtures/vulnerable.tf` | Terraform with known misconfigurations (S3 public access, unrestricted SSH, wildcard IAM) for T-03/T-07 |
| `tests/fixtures/vulnerable-package.json` | package.json with known vulnerable dependencies for T-04/T-07 |

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
