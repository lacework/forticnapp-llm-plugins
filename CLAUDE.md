# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Claude Code plugin** that integrates Fortinet Code Security (IaC and SCA scanning) directly into the Claude Code workflow. The plugin automatically scans infrastructure-as-code and dependency manifests for security vulnerabilities after each task completes.

## Development Commands

### Run tests
```bash
bash tests/test-session-start.sh   # Test session-start hook logic
bash tests/test-stop.sh            # Test stop hook logic
```

### Install plugin locally for development
```bash
export LW_API_KEY="your-api-key"
export LW_API_SECRET="your-api-secret"

claude plugin marketplace add $PWD
claude plugin install code-security@fortinet-plugins
```

### Test hooks manually
```bash
# Session start (first-time setup)
export CLAUDE_PLUGIN_DATA="$HOME/.claude/plugins/fortinet-code-security-plugin/data"
export LW_ACCOUNT="lacework.lacework.net"
bash hooks/session-start.sh

# Stop hook (scan simulation)
echo '{"transcript":[{"tool_uses":[{"tool_name":"Write","tool_input":{"file_path":"tests/fixtures/vulnerable.tf"}}]}]}' | bash hooks/stop.sh
```

## Architecture

### Plugin Structure
```
.claude-plugin/plugin.json  # Plugin manifest (name: "code-security", version, hook registration)
hooks/
  session-start.sh          # Runs on SessionStart: installs jq, Lacework CLI, configures credentials
  stop.sh                   # Runs on Stop: routes files to IaC/SCA scanners, aggregates findings
scripts/
  install-lw.sh             # Reusable Lacework CLI installer (can be sourced or run directly)
skills/
  fortinet-scan/SKILL.md    # Defines /fortinet-scan slash command
  fortinet-review/SKILL.md  # Defines /fortinet-review slash command
tests/
  fixtures/                 # Intentionally vulnerable files for testing scanners
```

### Hook Flow
1. **SessionStart** (`session-start.sh`): Idempotent setup — checks version marker, installs dependencies (jq, lacework CLI), configures credentials, installs iac/sca components. Checks for plugin updates via GitHub API (3s timeout).

2. **Stop** (`stop.sh`): Reads session JSON from stdin, extracts changed files from `Write`/`Edit`/`MultiEdit` tool uses, routes to scanners:
   - IaC files (`.tf`, `.bicep`, k8s paths, etc.) → `lacework iac scan`
   - SCA manifests (`package.json`, `go.mod`, etc.) → `lacework sca scan` (with SHA-256 caching)
   - Both scan types run in parallel when applicable
   - Exit code 2 triggers Claude auto-remediation for critical/high findings

### Version Management
- Version stored in both `.claude-plugin/plugin.json` and `REQUIRED_VERSION` in `session-start.sh`
- GitHub Actions workflow (`release.yml`) auto-bumps version based on conventional commits
- Version mismatch between installed marker and `REQUIRED_VERSION` triggers re-install

## Key Patterns

- **File routing**: `stop.sh` uses regex patterns (`IAC_PATTERN`, `SCA_PATTERN`) to classify changed files
- **Parallel execution**: Scans run as background processes, PIDs collected, waited on together
- **SCA caching**: Manifest hash stored in `~/.lacework/cache/` to skip unchanged dependencies
- **Exit codes**: 0 = clean/medium-low findings, 2 = critical/high findings (triggers remediation)
- **Output routing**: Critical findings → stderr (visible to Claude), informational → stdout

## Releases

Automated via GitHub Actions on push to `main`:
- `feat!:` / `fix!:` → major bump
- `feat:` → minor bump
- `fix:` / `chore:` / etc. → patch bump

Manual release: Actions → Release → Run workflow with specific version.

## Roadmap

### False Positive Reduction & Finding Noise Management

The current scanning output includes noise from test directories, README examples with dummy secrets, and other benign patterns. The goal is to add intelligence to the plugin that reduces needless findings while maintaining a clear audit trail.

#### 1. Context-Aware False Positive Detection
- Add a skill that analyzes scan findings against the repo context (test dirs, fixture files, documentation, example configs)
- Detect suspected false positives: dummy secrets in READMEs, intentionally vulnerable test fixtures, example/placeholder values
- Classify findings into: **confirmed**, **suspected false positive**, and **accepted low risk**

#### 2. Findings Summary Table
- After each scan, display a summary table with:
  - **Raw findings**: total unfiltered count from IaC/SCA scanners
  - **Suspected false positives**: findings flagged by context-aware analysis
  - **Cleaned findings**: actionable findings after filtering (raw minus suspected FPs)
- Table should break down by severity (critical/high/medium/low) and scan type (IaC/SCA)

#### 3. `codesec.yaml` Exception File
- Generate a `codesec.yaml` file in the repo root for managing scan exceptions
- Structure should support per-finding exceptions with fields: finding ID, file path, reason, risk acceptance level, added-by, date
- When the plugin suggests false positives, offer to add them as exceptions in `codesec.yaml`
- The plugin should read `codesec.yaml` on subsequent scans to automatically filter known exceptions
- Users must explicitly accept each suggested exception before it is written

#### 4. `audit.md` Audit Trail
- Maintain an `audit.md` file alongside `codesec.yaml` documenting every exclusion decision
- Each entry should include: finding details, why it was excluded, who accepted it, timestamp
- Purpose: give security engineers and audit/compliance teams clear reasoning for every suppressed finding
- Updated incrementally each time a user accepts a suggested exception
- Should be human-readable and suitable for compliance reviews

### Runtime-to-Code Correlation via CSPM, Agent & Vulnerability Data

Leverage the existing Lacework CLI's ability to pull runtime cloud security data and correlate it with code-level scan findings for a more complete, context-aware security picture.

#### 5. Cloud Account Discovery & Correlation
- On first use, query the Lacework CLI for available cloud accounts (AWS, Azure, GCP) and present the user with a selectable list
- For each account, show a summary of what's running in runtime: resource types, regions, workload counts, agent coverage
- Allow the user to associate one or more cloud accounts with the current repo (persist this mapping in `codesec.yaml` or a dedicated config)
- This association enables all downstream runtime-to-code correlation

#### 6. CSPM + IaC Cross-Correlation
- Pull CSPM findings (misconfigurations, policy violations) from the associated cloud accounts via the CLI
- Cross-reference CSPM findings with IaC scan results to:
  - **Elevate IaC findings** that match active misconfigurations in production (the misconfigured resource is actually deployed)
  - **Downgrade IaC findings** for resources that don't exist in any associated runtime environment
  - **Surface CSPM-only findings** that have no corresponding IaC definition, indicating drift or manually created resources
- Produce a combined report showing the IaC-to-runtime alignment, giving developers and security teams a unified view

#### 7. Agent Data + SCA/SAST Reachability Analysis
- Pull agent data (running processes, loaded libraries, network connections) from associated accounts
- Correlate with SCA CVE findings and SAST weakness detections to assess reachability:
  - **Elevate CVEs** where the vulnerable package is confirmed loaded/running in production workloads
  - **Downgrade CVEs** where the vulnerable dependency exists in the manifest but is never loaded at runtime
  - **Enhance SAST findings** where a detected weakness (e.g. injection, auth bypass) aligns with an exposed runtime service
- Present reachability-adjusted severity alongside the original severity so users understand the reasoning

#### 8. Vulnerability Data + SCA Container/Image Analysis
- Pull container and host vulnerability data from the CLI (image scans, host agent findings)
- Cross-reference with SCA CVE findings from the repo to:
  - **Identify which repo dependencies are responsible** for container/image vulnerabilities — trace CVEs back to the `package.json`, `go.mod`, `requirements.txt`, etc. that introduced them
  - **Distinguish Dockerfile layer issues** (base image CVEs, OS-level packages) from first-party application dependency CVEs
  - **Prioritize fixes in the repo** for vulnerabilities that appear in both the code dependency tree and the deployed container images
- Help developers understand which CVEs they can fix by updating dependencies vs which require base image or Dockerfile changes

#### Implementation Notes
- All exception suggestions require explicit user acceptance — nothing is auto-suppressed
- `codesec.yaml` and `audit.md` should be committed to the repo so the full team has visibility
- The findings table, exception management, and audit logging could be exposed as new `/fortinet-triage` or similar slash commands
