---
name: fortinet-review
description: Run Fortinet Code Security IaC and SCA scans on the current directory
user-invocable: true
---

# Fortinet Code Security Review

Security scan of the current working directory.

## Scan Execution

Always run both scans in parallel:
- **IaC**: `lacework iac scan --upload=false --noninteractive`
- **SCA**: `lacework sca scan . --deployment=offprem --noninteractive --save-results=false`

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

### 2. Critical Findings (if any)
For each critical finding, show:
```
**[CRITICAL]** Policy/CVE-ID
- File: path/to/file:line
- Issue: One-line description from scan output
- Fix: Specific code change or command to remediate
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
