---
name: lacework-review
description: Full security review of changed files before committing or opening a PR
---

# Lacework Security Review

Full security review before committing or opening a PR.

1. Identify all files changed since last git commit: `git diff --name-only HEAD`
2. Classify files by type (IaC vs SCA manifests vs source code)
3. Run appropriate scans in parallel using background processes
4. Produce a structured security report with:
   - **Critical findings** (must fix before proceeding)
   - **High findings** (should fix before merging)
   - **Medium/low findings** (consider fixing — informational)
   - Files scanned
   - Scan duration
   - Recommendations for remediation
