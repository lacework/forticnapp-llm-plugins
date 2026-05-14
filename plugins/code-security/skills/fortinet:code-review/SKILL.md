---
name: fortinet:code-review
description: Run Fortinet Code Security IaC and SCA scans on the current directory
user-invocable: true
---

# Fortinet Code Security Review

Security scan of the current working directory.

## Scan Execution

Always run both scans in parallel:
- **IaC**: `lacework iac scan --upload=false --noninteractive --format json --save-result <tmpdir>/iac.json -d .`
- **SCA**: `lacework sca scan . --deployment=offprem --noninteractive --save-results=false -f lw-json -o <tmpdir>/sca.json`

## Filtering Findings

When processing scan results, **exclude** findings that:
- Have `pass == true` (the check passed)
- Have `isSuppressed == true` (an exception was added in `.lacework/codesec.yaml`)

Only count and display findings where `pass == false` AND `isSuppressed != true`.

Track the number of suppressed findings separately to show in the summary.

## Output Format (Follow Exactly)

### 1. Summary Table
```
| Severity | IaC | SCA | Total |
|----------|-----|-----|-------|
| Critical |  X  |  X  |   X   |
| High     |  X  |  X  |   X   |
| Medium   |  X  |  X  |   X   |
| Low      |  X  |  X  |   X   |
```

If any findings were suppressed by exceptions, add a line below the table:
```
_X findings suppressed by exceptions in `.lacework/codesec.yaml`_
```

### 2. Critical Findings (if any)
For each critical finding, show:
```
**[CRITICAL]** Policy/CVE-ID
- File: path/to/file:line
- Issue: One-line description from scan output
- Fix: Specific code change or command to remediate
- Exception ID: `<policyId>` (IaC) or `CVE:<cveId>` (SCA)
```

### 3. High Findings (if any)
Same format as critical.

### 4. Medium/Low Findings (if any)
Condensed table only:
```
| Severity | Source | File:Line | Policy/CVE | Description |
```

### 5. Recommendations
ONLY include if there are findings. List prioritized actions based on actual findings:
```
1. [Action] - because [reason from findings]
2. [Action] - because [reason from findings]
```

Do NOT include generic security advice. Only recommend actions directly tied to scan results.

### 5a. MCP Enrichment (if codesec MCP server is connected)

For each Critical/High finding that has a FortiCNAPP weakness ID (e.g. `INJ-CMD-001`, `INPUT-XSS-001`, `AUTH-CREDS-001`), call `mcp__codesec__get_weakness` with the ID to get:
- Full description and remediation recommendation
- CWE mappings
- Language-specific code examples (vulnerable vs secure patterns)

Use the MCP response to improve the **Fix** field in the finding output — reference the scanner's recommended remediation and code patterns instead of generic advice. If the MCP response includes `codeExamples` for the relevant language, include the secure pattern in the recommendation.

Note: The `// [!code ++]` annotations in code examples are rendering markers — strip them when presenting code to the user.

If the MCP server is not connected or the call fails, fall back to the scan output description as before.

### 6. Exception Management (only if there are findings)

For each finding, ask the user whether to **fix** or **add exception**.

Exception format: `<criteria>:<value>:<reason>`

**Criteria** (case-sensitive): `policy`, `CVE`, `CWE`, `path`, `file`, `fingerprint`, `finding`
**Reasons** (case-sensitive): `Accepted risk`, `Compensating Controls`, `False positive`, `Patch incoming`

Add to `default.iac.scan.exceptions` for IaC findings, `default.sca.scan.exceptions` for SCA findings in `.lacework/codesec.yaml`.

```yaml
# .lacework/codesec.yaml
default:
    iac:
        enabled: true
        scan:
            exceptions:
                - "policy:<policy-id>:<reason>"
                - "path:<glob-pattern>:<reason>"
                - "file:<file-path>:<reason>"
    sca:
        enabled: true
        scan:
            exceptions:
                - "CVE:<cve-id>:<reason>"
                - "path:<glob-pattern>:<reason>"
                - "CWE:<cwe-id>:<reason>"
```

**Important:** Only add exceptions the user explicitly approves. Do not auto-suppress findings.
