#!/bin/bash
# file-utils.sh — Shared file utilities for Fortinet Code Security hooks
#
# Sourced by stop.sh and pre-commit-scan.sh.
# Provides:
#   - expand_with_companions: companion file expansion for --modified-files SCA optimisation
#   - has_iac_files: check if a file list contains IaC-relevant files
#
# Usage:
#   source "$(dirname "$0")/file-utils.sh"
#   EXPANDED=$(expand_with_companions "$FILE_LIST" "$SCAN_PATH")
#   if has_iac_files "$FILE_LIST"; then ... fi

# has_iac_files <newline-separated-relative-paths>
# Returns 0 (true) if any file could plausibly be IaC (Terraform, CloudFormation,
# K8s, Dockerfile, etc.). Includes ambiguous extensions (.yaml, .yml, .json) to
# avoid missing CloudFormation/ARM/K8s changes at the cost of occasional false triggers.
has_iac_files() {
  local file_list="$1"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    local base
    base=$(basename "$rel")
    local lower_base
    lower_base=$(echo "$base" | tr '[:upper:]' '[:lower:]')

    case "$base" in
      *.tf|*.tf.json) return 0 ;;
      *.yaml|*.yml|*.json) return 0 ;;
    esac

    # Dockerfile patterns: Dockerfile, Dockerfile.*, *.dockerfile
    case "$lower_base" in
      dockerfile|dockerfile.*|*.dockerfile) return 0 ;;
    esac
  done <<< "$file_list"
  return 1
}

# expand_with_companions <newline-separated-relative-paths> <scan-path>
# For each file in the list, checks if it's a known manifest or lock file.
# If so, adds its companion(s) from the same directory (if they exist on disk).
# Outputs: deduplicated list (one file per line) with companions added.
expand_with_companions() {
  local file_list="$1"
  local scan_path="$2"
  local expanded="$file_list"

  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    local dir
    dir=$(dirname "$rel")
    [ "$dir" = "." ] && dir=""
    local base
    base=$(basename "$rel")
    local prefix=""
    [ -n "$dir" ] && prefix="${dir}/"

    case "$base" in
      # --- Manifest → Lock companions ---

      # Node.js
      package.json)
        [ -f "${scan_path}/${prefix}package-lock.json" ] && expanded="${expanded}
${prefix}package-lock.json"
        [ -f "${scan_path}/${prefix}yarn.lock" ] && expanded="${expanded}
${prefix}yarn.lock"
        [ -f "${scan_path}/${prefix}pnpm-lock.yaml" ] && expanded="${expanded}
${prefix}pnpm-lock.yaml"
        ;;
      # Go
      go.mod)
        [ -f "${scan_path}/${prefix}go.sum" ] && expanded="${expanded}
${prefix}go.sum"
        ;;
      # Java — Gradle
      build.gradle|build.gradle.kts)
        [ -f "${scan_path}/${prefix}.lockfile" ] && expanded="${expanded}
${prefix}.lockfile"
        ;;
      # Ruby
      Gemfile|*.gemspec)
        [ -f "${scan_path}/${prefix}Gemfile.lock" ] && expanded="${expanded}
${prefix}Gemfile.lock"
        ;;
      # Python
      Pipfile)
        [ -f "${scan_path}/${prefix}Pipfile.lock" ] && expanded="${expanded}
${prefix}Pipfile.lock"
        ;;
      pyproject.toml)
        [ -f "${scan_path}/${prefix}poetry.lock" ] && expanded="${expanded}
${prefix}poetry.lock"
        [ -f "${scan_path}/${prefix}uv.lock" ] && expanded="${expanded}
${prefix}uv.lock"
        ;;
      requirements.in)
        [ -f "${scan_path}/${prefix}requirements.txt" ] && expanded="${expanded}
${prefix}requirements.txt"
        ;;
      # Rust
      Cargo.toml)
        [ -f "${scan_path}/${prefix}Cargo.lock" ] && expanded="${expanded}
${prefix}Cargo.lock"
        ;;
      # PHP
      composer.json)
        [ -f "${scan_path}/${prefix}composer.lock" ] && expanded="${expanded}
${prefix}composer.lock"
        ;;
      # .NET
      *.csproj|packages.config)
        [ -f "${scan_path}/${prefix}packages.lock.json" ] && expanded="${expanded}
${prefix}packages.lock.json"
        [ -f "${scan_path}/${prefix}Directory.Packages.props" ] && expanded="${expanded}
${prefix}Directory.Packages.props"
        ;;
      # C/C++ — Conan
      conanfile.py)
        [ -f "${scan_path}/${prefix}conan.lock" ] && expanded="${expanded}
${prefix}conan.lock"
        ;;

      # --- Lock → Manifest companions (reverse direction) ---

      # Node.js
      package-lock.json|yarn.lock|pnpm-lock.yaml)
        [ -f "${scan_path}/${prefix}package.json" ] && expanded="${expanded}
${prefix}package.json"
        ;;
      # Go
      go.sum)
        [ -f "${scan_path}/${prefix}go.mod" ] && expanded="${expanded}
${prefix}go.mod"
        ;;
      # Java — Gradle (.lockfile is the actual filename)
      .lockfile)
        [ -f "${scan_path}/${prefix}build.gradle" ] && expanded="${expanded}
${prefix}build.gradle"
        [ -f "${scan_path}/${prefix}build.gradle.kts" ] && expanded="${expanded}
${prefix}build.gradle.kts"
        ;;
      # Ruby
      Gemfile.lock)
        [ -f "${scan_path}/${prefix}Gemfile" ] && expanded="${expanded}
${prefix}Gemfile"
        ;;
      # Python
      Pipfile.lock)
        [ -f "${scan_path}/${prefix}Pipfile" ] && expanded="${expanded}
${prefix}Pipfile"
        ;;
      poetry.lock|uv.lock)
        [ -f "${scan_path}/${prefix}pyproject.toml" ] && expanded="${expanded}
${prefix}pyproject.toml"
        ;;
      requirements.txt)
        [ -f "${scan_path}/${prefix}requirements.in" ] && expanded="${expanded}
${prefix}requirements.in"
        ;;
      # Rust
      Cargo.lock)
        [ -f "${scan_path}/${prefix}Cargo.toml" ] && expanded="${expanded}
${prefix}Cargo.toml"
        ;;
      # PHP
      composer.lock)
        [ -f "${scan_path}/${prefix}composer.json" ] && expanded="${expanded}
${prefix}composer.json"
        ;;
      # .NET
      packages.lock.json)
        # Could be multiple .csproj files — skip reverse for this one
        ;;
      .deps.json|Directory.Packages.props)
        # .NET auxiliary files — no single manifest to reverse-map
        ;;
      # C/C++ — Conan
      conan.lock)
        [ -f "${scan_path}/${prefix}conanfile.py" ] && expanded="${expanded}
${prefix}conanfile.py"
        ;;
    esac
  done <<< "$file_list"

  echo "$expanded" | sort -u
}
