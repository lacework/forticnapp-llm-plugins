# Fortinet Code Security Plugin - Installation Troubleshooting

## Problem

Attempting to install the plugin from a local zip file failed:

```
claude plugin install ./fortinet-code-security-plugin.zip
```

**Error:**
```
✘ Failed to install plugin "./fortinet-code-security-plugin.zip": Plugin "./fortinet-code-security-plugin.zip" not found in any configured marketplace
```

## Root Causes

### 1. `claude plugin install` only works with marketplaces

The `install` command does not support local file paths or zip files. It only resolves plugin names against registered marketplaces (remote GitHub repos or local directories registered via `claude plugin marketplace add`).

### 2. Invalid `"env"` key in `plugin.json`

The `.claude-plugin/plugin.json` contained an `"env"` block that is not part of the plugin manifest schema:

```json
"env": {
  "LW_ACCOUNT": "lacework.lacework.net",
  "LW_API_KEY": "${LW_API_KEY}",
  "LW_API_SECRET": "${LW_API_SECRET}"
}
```

Running `claude plugin validate` confirmed:
```
✘ Found 1 error:
  ❯ root: Unrecognized key: "env"
```

## Changes Made

### 1. Removed `"env"` from `.claude-plugin/plugin.json`

**Before:**
```json
{
  "name": "fortinet-code-security-plugin",
  "version": "1.2.1",
  "description": "Lacework IaC and SCA scanning for Claude Code",
  "env": {
    "LW_ACCOUNT": "lacework.lacework.net",
    "LW_API_KEY": "${LW_API_KEY}",
    "LW_API_SECRET": "${LW_API_SECRET}"
  },
  "hooks": { ... }
}
```

**After:**
```json
{
  "name": "fortinet-code-security-plugin",
  "version": "1.2.1",
  "description": "Lacework IaC and SCA scanning for Claude Code",
  "hooks": { ... }
}
```

Validation now passes:
```
✔ Validation passed with warnings
```

### 2. Created local marketplace wrapper

A marketplace manifest was created at `plugin_test/.claude-plugin/marketplace.json` to allow local installation. This file is **not** needed in the upstream repo — it was only used for local testing.

## Installation Steps (after fix)

```bash
# Register the parent directory as a local marketplace
claude plugin marketplace add /path/to/plugin_test

# Install the plugin
claude plugin install fortinet-code-security-plugin

# Verify
claude plugin list
```

### 3. Fixed incorrect CLI flags in SKILL.md and stop.sh

The plugin referenced `--path` for the `lacework iac scan` and `lacework sca scan` commands, but the correct flag is `-d`/`--directory`.

**Files changed:**
- `skills/lacework/SKILL.md` — `--path <dir>` → `-d <dir>` (IaC and SCA command examples)
- `hooks/stop.sh` — `--path "$SCAN_PATH"` → `-d "$SCAN_PATH"` (both iac and sca scan invocations)

---

## Scan Test Results

Ran `lacework iac scan -d ./aws_tf_test` against TerraGoat-style intentionally vulnerable Terraform. The scan found **141 findings** (11 Critical, 22 High, ~15 Medium, ~5 Low).

> **Note:** Docker was not running during the test, so Checkov-based checks were skipped. Running with Docker would likely surface additional findings.

### Lacework vs Claude Code Native Review — Comparison

Both approaches were run against the same `aws_tf_test/` Terraform files.

#### Findings both detected

| Category | Details |
|----------|---------|
| Overly permissive IAM | Wildcard actions in `iam.tf`, `db-app.tf` |
| Elasticsearch open policy | `es:*` to all principals in `es.tf` |
| SSH/HTTP open to world | Security group `0.0.0.0/0` on ports 22/80 in `ec2.tf` |
| Public subnets | `map_public_ip_on_launch = true` in `ec2.tf`, `eks.tf` |
| RDS publicly accessible | `db-app.tf` |
| S3 missing encryption | Multiple buckets in `s3.tf` |
| S3 missing versioning/logging | `data`, `financials` buckets in `s3.tf` |
| EBS/snapshot unencrypted | `ec2.tf` |
| RDS/Neptune storage unencrypted | `db-app.tf`, `neptune.tf` |
| KMS key rotation disabled | `kms.tf` |
| RDS no backups | `db-app.tf`, `rds.tf` |
| EKS public endpoint | `eks.tf` |
| ECR mutable tags | `ecr.tf` |
| Neptune no IAM auth | `neptune.tf` |
| ELB HTTP only / no TLS | `elb.tf` |

#### Lacework caught, Claude missed

| Finding | File | Severity |
|---------|------|----------|
| RDS clusters missing deletion protection | `rds.tf` (all 9 clusters) | Critical |
| Elasticsearch not enforcing HTTPS | `es.tf` | Critical |
| RDS missing Performance Insights encryption | `db-app.tf` | Medium |
| S3 buckets allowing public write access | `s3.tf`, `ec2.tf` (flowbucket) | Medium |
| ELB cross-zone load balancing | `elb.tf` | Medium |
| VPC flow logging gaps | `ec2.tf` (EKS VPC) | Low |

#### Claude caught, Lacework missed

| Finding | File | Why it matters |
|---------|------|----------------|
| Hardcoded AWS access keys in provider | `providers.tf:10-11` | Credential exposure |
| Hardcoded AWS keys in EC2 user_data | `ec2.tf:15-16` | Credential exposure |
| Hardcoded AWS keys in Lambda env vars | `lambda.tf:45-46` | Credential exposure |
| Hardcoded DB password as variable default | `consts.tf:42` | Credential exposure |
| Deprecated Lambda runtime (`nodejs12.x`) | `lambda.tf:41` | EOL / no security patches |
| Outdated Elasticsearch version (2.3) | `es.tf:3` | Known vulnerabilities |
| RDS no multi-AZ | `db-app.tf:17` | Availability risk |
| RDS monitoring disabled | `db-app.tf:21` | Observability gap |

#### Key takeaways

1. **Lacework excels at policy-based IaC checks** — deletion protection, encryption, network exposure, public access. It found 141 structured findings including several Claude missed around deletion protection and public write access.
2. **Lacework missed all hardcoded secrets** (4 instances of plaintext AWS credentials + a default password). Checkov-based checks (requires Docker) may have caught these.
3. **Claude's review was stronger on contextual/qualitative issues** — secret detection, deprecated runtimes, outdated software versions, availability and observability concerns.
4. **They are complementary** — Lacework provides breadth and policy compliance coverage, Claude adds depth on secrets, version hygiene, and architectural concerns. Running both gives the best coverage.

---

## Open Items

- [ ] Environment variables (`LW_ACCOUNT`, `LW_API_KEY`, `LW_API_SECRET`) are no longer declared in the plugin manifest. Documented in the README as one of three credential paths — the script now also reads an existing `~/.lacework.toml` or falls back to interactive `lacework configure`.
- [ ] Consider adding `"author"` field to `plugin.json` to resolve the validation warning.
- [ ] Review whether the `"hooks"` block in `plugin.json` is working as expected after installation.
- [ ] Once testing is complete, create a PR against `https://github.com/lacework-dev/fortinet-code-security-plugin` with the `plugin.json` fix.
