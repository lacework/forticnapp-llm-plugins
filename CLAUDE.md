# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Claude Code plugin** that integrates Fortinet Code Security (IaC and SCA scanning) directly into the Claude Code workflow. The plugin automatically scans infrastructure-as-code and dependency manifests for security vulnerabilities after each task completes.

## Development Commands

### Run tests
```bash
bash tests/test-stop.sh            # Test stop hook logic
```

### Install plugin locally for development
```bash
claude plugin marketplace add $PWD
claude plugin install code-security@fortinet-plugins
```

### Run setup (after installing plugin)
```bash
export LW_ACCOUNT="your-account.lacework.net"
export LW_API_KEY="your-api-key"
export LW_API_SECRET="your-api-secret"
export LW_SUBACCOUNT="your-subaccount"  # optional, for multi-tenant accounts
# Then run /fortinet:cli-setup in Claude Code, or directly:
bash scripts/install-lw.sh
```

### Test hooks manually
```bash
# Stop hook (scan simulation)
echo '{"transcript":[{"tool_uses":[{"tool_name":"Write","tool_input":{"file_path":"tests/fixtures/vulnerable.tf"}}]}]}' | bash scripts/stop.sh
```

## Architecture

### Plugin Structure
```
.claude-plugin/plugin.json  # Plugin manifest (name: "code-security", version, hook registration)
hooks/
  hooks.json                # Hook registration (Stop hook only)
scripts/
  install-lw.sh             # Full setup: installs jq, Lacework CLI, configures credentials, installs components
  stop.sh                   # Runs on Stop: routes files to IaC/SCA scanners, aggregates findings
skills/
  fortinet:cli-setup/SKILL.md   # Defines /fortinet:cli-setup slash command for CLI installation & configuration
  fortinet:code-review/SKILL.md  # Defines /fortinet:code-review slash command
tests/
  fixtures/                 # Intentionally vulnerable files for testing scanners
```

### Hook Flow
1. **Setup** (`/fortinet:cli-setup` → `scripts/install-lw.sh`): User-initiated setup — installs jq, Lacework CLI, configures credentials, installs IaC/SCA components. Idempotent (skips already-installed steps).

2. **Stop** (`scripts/stop.sh`): Reads session JSON from stdin, extracts changed files from `Write`/`Edit`/`MultiEdit` tool uses, routes to scanners:
   - IaC files (`.tf`, `.bicep`, k8s paths, etc.) → `lacework iac scan`
   - SCA manifests (`package.json`, `go.mod`, etc.) → `lacework sca scan`
   - Both scan types run in parallel when applicable
   - Findings with `isSuppressed==true` (exceptions in `.lacework/codesec.yaml`) are excluded
   - Exit code 2 triggers Claude auto-remediation for critical/high findings

### Exception Format
Exceptions in `.lacework/codesec.yaml` use the format `<criteria>:<value>:<reason>`:
- **Criteria** (case-sensitive): `policy`, `CVE`, `CWE`, `path`, `file`, `fingerprint`, `finding`
- **Reasons** (case-sensitive): `Accepted risk`, `Compensating Controls`, `False positive`, `Patch incoming`
- Example: `policy:lacework-iac-aws-security-3:Accepted risk`

### Version Management
- Version stored in `.claude-plugin/plugin.json`
- GitHub Actions workflow (`release.yml`) auto-bumps version based on conventional commits

## Key Patterns

- **File routing**: `stop.sh` uses regex patterns (`IAC_PATTERN`, `SCA_PATTERN`) to classify changed files
- **Parallel execution**: Scans run as background processes, PIDs collected, waited on together
- **Scan loop prevention**: After scanning, a marker file (SHA-256 hash of transcript path + changed file paths) is created in `~/.lacework/scan-markers/`. If the stop hook fires again for the same changes in the same session, it exits immediately. This prevents infinite loops where: scan finds issues → exit 2 triggers auto-remediation → Claude edits files → stop hook fires again → repeat. The hash MUST include the transcript path (unique per session) so that editing the same files in a different session triggers a fresh scan.
- **Finding filtering**: Only findings with `pass==false` AND `isSuppressed!=true` are counted and reported. Suppressed findings have exceptions configured in `.lacework/codesec.yaml`.
- **Exit codes**: 0 = clean/medium-low findings, 2 = critical/high findings (triggers remediation)
- **Output routing**: Critical findings → stderr (visible to Claude), informational → stdout

## Releases

Automated via GitHub Actions on push to `main`:
- `feat!:` / `fix!:` → major bump
- `feat:` → minor bump
- `fix:` / `chore:` / etc. → patch bump

Manual release: Actions → Release → Run workflow with specific version.

## Roadmap

### Current State (Implemented)

- Stop hook scans IaC + SCA in parallel on every code change, reports critical/high findings
- Exception management via `.lacework/codesec.yaml` with `criteria:value:reason` format
- `isSuppressed` filtering — excepted findings are excluded from counts and output
- Scan loop prevention via per-session marker files
- Skills: `/fortinet:cli-setup` (installation), `/fortinet:code-review` (on-demand scanning)
- Exception instructions embedded in hook output so Claude can guide users through adding exceptions

---

### Phase 1: Smart Triage — Context-Aware Finding Analysis

**Goal**: Eliminate false positives by leveraging Claude's ability to reason about code context. No other scanner can do this.

#### 1.1 Inline Triage Instructions in Stop Hook (Option A — implement first)

**What**: Expand the stop hook output instructions to tell Claude to analyze each finding against repo context BEFORE presenting to the user.

**Implementation**:
- In `scripts/stop.sh`, add triage instructions to the `MESSAGE` block (the stderr output Claude reads)
- Instructions tell Claude to check each finding against these signals:
  - Is the file in a test/fixture/docs/example directory?
  - Is the flagged value a placeholder? (e.g. `AKIAEXAMPLE`, `password123`, `0.0.0.0/0` in a test)
  - Does git history show this was intentionally introduced? (check commit message)
  - Is there a comment like `# intentionally insecure` or `# test fixture` nearby?
- Claude classifies each finding as: **Confirmed**, **Suspected FP** (with reason), or **Context-reduced** (lower effective severity)
- Claude presents a triaged table instead of the raw list

**Output format Claude should produce**:
```
## Fortinet Security Triage

Scanned 8 findings. After context analysis:

| # | Finding | Raw | Adjusted | Reason |
|---|---------|-----|----------|--------|
| 1 | S3 public access | High | Dismissed | tests/fixtures/vulnerable.tf — intentional test fixture |
| 2 | Ingress /0 port 22 | Critical | Critical | modules/networking/main.tf — production module |
| 3 | Hardcoded key | Critical | Dismissed | README.md — placeholder value AKIAEXAMPLE |

1 finding needs attention. 2 dismissed.
```

**Files to modify**: `scripts/stop.sh` (add triage instructions to MESSAGE block)

**Key constraint**: The stop hook shell script does NOT do the triage — it only provides raw findings + instructions. Claude does the reasoning. This keeps `stop.sh` simple and leverages Claude's unique capability.

#### 1.2 `/fortinet:triage` Skill

**What**: A dedicated skill for interactive triage of scan findings with decision recording.

**Implementation**:
- Create `skills/fortinet:triage/SKILL.md`
- The skill runs both scans (same as `/fortinet:code-review`), then walks through findings one by one
- For each finding, Claude:
  1. Reads the file and surrounding context
  2. Checks git blame for when/why it was introduced
  3. Classifies the finding with reasoning
  4. Asks the user: **Fix**, **Add exception**, or **Accept risk**
- User decisions are recorded to `codesec.yaml` and `audit.md`

**Triage classification logic** (instructions for Claude in the skill):
```
For each finding, check IN ORDER:
1. FILE LOCATION: Is it in tests/, fixtures/, examples/, docs/, or __tests__/?
   → If yes: Suspected FP, reason: "test/example directory"
2. VALUE ANALYSIS: Is the flagged value a known placeholder?
   (AKIAEXAMPLE, CHANGE_ME, password123, example.com, 127.0.0.1 in docs)
   → If yes: Suspected FP, reason: "placeholder value"
3. COMMENTS: Does the surrounding code have comments indicating intentional insecurity?
   (# test, # fixture, # intentionally, # nosec, # NOSONAR)
   → If yes: Suspected FP, reason: "explicitly marked as intentional"
4. GIT CONTEXT: Was this introduced in a test/fixture commit? (check commit message)
   → If yes: Context-reduced, reason: "introduced as test fixture"
5. DEPENDENCY CONTEXT (SCA only): Is the vulnerable package in devDependencies only?
   → If yes: Context-reduced severity, reason: "dev-only dependency"
6. DEFAULT: Confirmed at raw severity
```

#### 1.3 `audit.md` Audit Trail

**What**: Track every exception decision for compliance/audit purposes.

**Implementation**:
- When a user accepts an exception (via triage or stop hook), append to `audit.md` in the repo root
- Format per entry:
  ```markdown
  ### [2026-04-17] policy:lacework-iac-aws-security-3:Accepted risk
  - **Finding**: An ingress security group rule allows traffic from /0
  - **File**: tests/fixtures/vulnerable.tf:43
  - **Severity**: Critical → Dismissed
  - **Reason**: Intentionally vulnerable test fixture
  - **Accepted by**: developer (via Claude Code triage)
  ```
- Both `codesec.yaml` and `audit.md` should be committed to the repo for team visibility
- The triage skill and stop hook instructions should tell Claude to update `audit.md` whenever an exception is added

#### 1.4 Findings Summary with Raw vs Cleaned Counts

**What**: Show transparency about filtering in the output.

**Implementation**:
- In `stop.sh`, count both total findings and suppressed findings from scan JSON
- Add suppressed count to the summary: `**Summary:** 1 Critical, 2 High (3 suppressed by exceptions)`
- In `/fortinet:code-review` and `/fortinet:triage`, show the full breakdown:
  ```
  | Severity | Raw | Suppressed | Suspected FP | Actionable |
  |----------|-----|------------|--------------|------------|
  | Critical |  3  |     1      |      1       |     1      |
  | High     |  5  |     2      |      1       |     2      |
  ```

---

### Phase 2: Runtime-to-Code Correlation

**Goal**: Connect Lacework's runtime security data to code-level findings for risk-based prioritization.

#### 2.1 `/fortinet:posture` Skill — Cloud Account Discovery

**What**: Query Lacework for connected cloud accounts and associate them with the current repo.

**Implementation**:
- Create `skills/fortinet:posture/SKILL.md`
- On first use, run `lacework cloud-account list --json` to enumerate accounts
- Present selectable list showing: account name, provider (AWS/Azure/GCP), status
- For each account, run `lacework compliance {aws,azure,google} get-report --json` to show summary
- Persist the repo-to-account mapping in `.lacework/codesec.yaml` under a new `cloudAccounts` key:
  ```yaml
  default:
      cloudAccounts:
          - provider: aws
            accountId: "123456789012"
            alias: "prod"
          - provider: aws
            accountId: "987654321098"
            alias: "dev"
  ```

**Lacework CLI commands needed**:
- `lacework cloud-account list --json` — enumerate accounts
- `lacework compliance aws list-accounts --json` — list AWS accounts
- `lacework compliance aws get-report <account_id> --json` — CSPM findings
- `lacework compliance aws search <resource_arn>` — search by resource ARN
- `lacework agent list --json` — agent coverage
- `lacework alert list --json` — active alerts

#### 2.2 CSPM + IaC Cross-Correlation

**What**: Cross-reference IaC scan findings with runtime CSPM data.

**Implementation** (logic for Claude in the `/fortinet:posture` skill):
- After IaC scan, for each finding:
  1. Extract the resource type and name (e.g. `aws_s3_bucket.prod_data`)
  2. Search CSPM findings from associated accounts for matching resource types
  3. Classify as:
     - **Deployed + Misconfigured**: IaC finding matches active CSPM violation → **ELEVATE** priority
     - **Not Deployed**: Resource exists in IaC but not in any associated account → **DOWNGRADE** priority
     - **Drift Detected**: CSPM finding exists but no matching IaC definition → **SURFACE** as new finding
- Output format:
  ```
  | IaC Finding | Deployed? | Runtime Status | Adjusted Priority |
  |-------------|-----------|----------------|-------------------|
  | S3 no encryption | YES (arn:aws:s3:::prod-data) | ACTIVE CSPM ALERT | ELEVATED |
  | SG open port 22 | NO | Not in any account | DOWNGRADED |
  ```

**Lacework CLI commands needed**:
- `lacework compliance aws get-report <account_id> --json` — pull CSPM findings
- `lacework compliance aws search <arn>` — search specific resources

#### 2.3 Agent Data + SCA Reachability Analysis

**What**: Use runtime agent data to determine if vulnerable dependencies are actually loaded in production.

**Implementation**:
- For SCA CVE findings, query agent data to check reachability:
  1. `lacework query list-sources` — find relevant datasources (machines, processes, packages)
  2. Run LQL queries to check if the vulnerable package is loaded in any monitored workload
  3. Classify as:
     - **Reachable**: Package confirmed running in production → **ELEVATE**
     - **Not Reachable**: Package in manifest but never loaded at runtime → **DOWNGRADE**
- Output format:
  ```
  | CVE | Package | In Prod? | Reachable? | Adjusted Severity |
  |-----|---------|----------|------------|-------------------|
  | CVE-2024-1234 | express@4.17.1 | YES | YES — listening :8080 | ELEVATED Critical |
  | CVE-2024-5678 | lodash@4.17.20 | YES | NO — not loaded | DOWNGRADED Low |
  ```

**Lacework CLI commands needed**:
- `lacework query list-sources` — available datasources
- `lacework query preview-source <source>` — schema of a datasource
- `lacework query run <query_id> --json` — execute LQL query
- `lacework vulnerability host list-cves --json` — host CVEs
- `lacework vulnerability container show-assessment --json` — container CVEs

#### 2.4 Container/Image Vulnerability Correlation

**What**: Trace container CVEs back to repo dependency files.

**Implementation**:
- Pull container vulnerability data: `lacework vulnerability container list-assessments --json`
- For each container CVE, check if the vulnerable package exists in repo dependency manifests
- Classify as:
  - **App dependency**: CVE comes from `package.json`, `go.mod`, etc. → developer can fix by updating
  - **Base image**: CVE comes from OS packages in base Docker image → needs Dockerfile/base image change
  - **Both**: Appears in both → fix app dependency first (faster)

**Lacework CLI commands needed**:
- `lacework vulnerability container list-assessments --json`
- `lacework vulnerability container show-assessment <id> --json`
- `lacework vulnerability host list-cves --json`

---

### Phase 3: AI Provenance via Entire.io (Optional Enhancement)

**Goal**: Track which AI sessions introduced security findings using Entire.io's checkpoint system.

**What is Entire.io**: Platform by ex-GitHub CEO that pairs every git commit with the AI agent session that produced it. Open-source CLI captures full agent conversations tied to commits via "Checkpoint IDs".

#### 3.1 Entire.io Integration

**Implementation**:
- When a finding is detected, check git blame for the introducing commit
- If the commit has an Entire checkpoint ID (12-char ID in commit message), link to it
- Add to finding output:
  ```
  **[Critical] Ingress SG allows /0 traffic**
  - Introduced: commit a1b2c3d (2 days ago)
  - AI Session: checkpoint-xyz789 (Entire.io)
  - Original intent: "User asked to create dev environment with SSH access"
  → The AI generated 0.0.0.0/0 for convenience; restrict to specific IP range
  ```
- This provides full provenance: what was the developer trying to do, why did the AI generate vulnerable code, and what should have been done instead

**Prerequisites**:
- Entire.io CLI installed (`entireio/cli` on GitHub)
- Checkpoints being captured in the repo's git history

---

### Build Order & Dependencies

```
Phase 1 (no external dependencies — implement now):
  1.1 Inline triage instructions in stop hook ← START HERE
   ↓
  1.4 Raw vs cleaned counts in summary
   ↓
  1.2 /fortinet:triage skill (interactive triage)
   ↓
  1.3 audit.md audit trail

Phase 2 (requires Lacework CLI + cloud accounts):
  2.1 /fortinet:posture skill + cloud account discovery ← START HERE
   ↓
  2.2 CSPM + IaC cross-correlation
   ↓
  2.3 Agent + SCA reachability
   ↓
  2.4 Container vulnerability correlation

Phase 3 (optional, requires Entire.io):
  3.1 Entire.io checkpoint integration
```

### Architecture: How Triage Flows Through the System

```
Code Change → Stop Hook (stop.sh)
                ↓
         Raw scan (lacework iac scan + lacework sca scan)
                ↓
         Filter: pass==false AND isSuppressed!=true
                ↓
         Raw findings + triage instructions → stderr (exit 2)
                ↓
         Claude reads findings + instructions
                ↓
    ┌── Claude Triage (Phase 1) ──────────┐
    │  1. Read each file + context         │
    │  2. Check: test dir? placeholder?    │
    │  3. Check: git blame, comments       │
    │  4. Classify: Confirmed / FP / Reduced│
    │  5. Present triaged table to user    │
    └──────────────────────────────────────┘
                ↓
         User decides per finding: Fix / Exception / Accept
                ↓
    ┌── Record Decision ──────────────────┐
    │  • Exception → .lacework/codesec.yaml│
    │  • Audit entry → audit.md            │
    │  • Fix → Claude modifies the code    │
    └──────────────────────────────────────┘
                ↓ (if /fortinet:posture used)
    ┌── Runtime Correlation (Phase 2) ────┐
    │  • CSPM: is resource deployed?       │
    │  • Agent: is package loaded?         │
    │  • Container: which layer has CVE?   │
    │  • Elevate / Downgrade accordingly   │
    └──────────────────────────────────────┘
```

### Implementation Notes
- All exception suggestions require explicit user acceptance — nothing is auto-suppressed
- `codesec.yaml` and `audit.md` should be committed to the repo so the full team has visibility
- The stop hook shell script stays simple (raw scan + output) — Claude does all reasoning
- Phase 1 has zero external dependencies; start here for immediate value
- Phase 2 leverages Lacework CLI commands that already exist; no new APIs needed
- Phase 3 is additive and optional; can be layered on independently
