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

This repo uses two branches:

- **`main`** — release branch. Users install from here. Protected (requires PRs).
- **`dev`** — development branch (default). All feature/fix PRs target `dev`.

### How releases work

1. **Development:** PRs merge to `dev`. Tests run automatically on every PR. Version is bumped automatically on each merge based on [conventional commit](https://www.conventionalcommits.org/) prefixes:

   | Commit prefix | Version bump |
   |---|---|
   | `feat!:`, `fix!:` (breaking change) | Major (`1.0.0` → `2.0.0`) |
   | `feat:` | Minor (`1.0.0` → `1.1.0`) |
   | `fix:`, `chore:`, `refactor:`, etc. | Patch (`1.0.0` → `1.0.1`) |

2. **Release:** A repo owner creates a PR from `dev` → `main`. When merged, a GitHub Release is created automatically with a `.zip` artifact.

3. **Manual override:** Go to **Actions → Release → Run workflow** and enter a specific version for hotfixes.

Available versions are listed on the [Releases](../../releases) page.

## Adding a New Plugin

1. Create a directory under `plugins/<plugin-name>/`
2. Add `.claude-plugin/plugin.json` with name, version, description
3. Add hooks, skills, and scripts as needed
4. Register the plugin in `.claude-plugin/marketplace.json` with `"source": "./plugins/<plugin-name>"`
5. Submit a PR targeting `dev` (the default branch)
