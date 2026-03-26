# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Claude Code plugin** that integrates Lacework Code Security (IaC and SCA scanning) directly into the Claude Code workflow. The plugin automatically scans infrastructure-as-code and dependency manifests for security vulnerabilities after each task completes.

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
claude plugin install .
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
.claude-plugin/plugin.json  # Plugin manifest (name, version, hook registration)
hooks/
  session-start.sh          # Runs on SessionStart: installs jq, Lacework CLI, configures credentials
  stop.sh                   # Runs on Stop: routes files to IaC/SCA scanners, aggregates findings
scripts/
  install-lw.sh             # Reusable Lacework CLI installer (can be sourced or run directly)
skills/lacework/SKILL.md    # Defines /lacework:scan and /lacework:review slash commands
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
