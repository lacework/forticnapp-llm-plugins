# Lacework Security Scanning

## /lacework:scan

Runs Lacework IaC and/or SCA scan on the current working file or directory.

Route based on file type:
- **IaC** → run `lacework iac scan --path <dir>`:
  - Terraform/HCL: `*.tf`, `*.tfvars`, `*.hcl`
  - Azure Bicep: `*.bicep`
  - CloudFormation: `*.template`, or `*.yaml`/`*.json` in `cloudformation/` paths
  - Kubernetes/Helm: YAML files in `k8s/`, `kubernetes/`, `helm/`, `charts/`, `manifests/`, `argocd/`, `flux/` paths
  - Pulumi: `Pulumi.yaml`, `Pulumi.*.yaml`
  - Serverless Framework: `serverless.yml`, `serverless.yaml`
  - Docker Compose: `docker-compose*.yml`, `compose.yml`
  - CDK: `cdk.json`
  - Ansible: files in `ansible/`, `playbooks/` paths
- **SCA** → run `lacework sca scan --path <dir>`:
  - Node/JS: `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `npm-shrinkwrap.json`
  - Python: `requirements*.txt`, `Pipfile`, `pyproject.toml`, `poetry.lock`, `setup.py`, `setup.cfg`
  - Go: `go.mod`, `go.sum`
  - Java/Kotlin: `pom.xml`, `build.gradle`, `build.gradle.kts`, `*.gradle`
  - Ruby: `Gemfile`, `Gemfile.lock`
  - Rust: `Cargo.toml`, `Cargo.lock`
  - PHP: `composer.json`, `composer.lock`
  - .NET: `*.csproj`, `*.vbproj`, `*.fsproj`, `packages.config`
  - Swift/iOS: `Package.swift`, `Package.resolved`, `Podfile`, `Podfile.lock`
  - Scala: `build.sbt`
  - Elixir: `mix.exs`, `mix.lock`
  - Dart/Flutter: `pubspec.yaml`, `pubspec.lock`
- If both types are present, run both scans in parallel.
- Print all findings grouped by severity (Critical → High → Medium → Low).

## /lacework:review

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
