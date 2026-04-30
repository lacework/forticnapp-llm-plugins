# FortiCNAPP LLM Plugins

A collection of Fortinet security plugins for Claude Code.

## Available Plugins

| Plugin | Description |
|--------|-------------|
| [code-security](plugins/code-security/) | Automated IaC and SCA scanning — scans infrastructure-as-code and dependency manifests for vulnerabilities after every task |

## Installation

In Claude Code, register the marketplace and install a plugin:

```
/plugin marketplace add lacework/forticnapp-llm-plugins
/plugin install code-security@fortinet-plugins
```

See each plugin's README for setup and configuration details.

## Releases

Releases are managed automatically via GitHub Actions:

- **Auto-release**: Every push to `main` triggers a version bump and release. The bump type is determined from [conventional commit](https://www.conventionalcommits.org/) prefixes:

  | Commit prefix | Version bump |
  |---|---|
  | `feat!:`, `fix!:` (breaking change) | Major (`1.0.0` → `2.0.0`) |
  | `feat:` | Minor (`1.0.0` → `1.1.0`) |
  | `fix:`, `chore:`, `refactor:`, etc. | Patch (`1.0.0` → `1.0.1`) |

- **Manual release**: Go to **Actions → Release → Run workflow** and enter a specific version (e.g. `2.1.0`) to cut a release at an exact version. Use this to skip ahead, backport, or hotfix.

Each release publishes a `.zip` artifact and updates the install command in the release notes. Available versions are listed on the [Releases](../../releases) page.

## Adding a New Plugin

1. Create a directory under `plugins/<plugin-name>/`
2. Add `.claude-plugin/plugin.json` with name, version, description
3. Add hooks, skills, and scripts as needed
4. Register the plugin in `.claude-plugin/marketplace.json` with `"source": "./plugins/<plugin-name>"`
