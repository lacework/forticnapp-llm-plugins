# FortiCNAPP LLM Plugins

A collection of Fortinet security plugins for Claude Code.

## Available Plugins

| Plugin | Description |
|--------|-------------|
| [code-security](plugins/code-security/) | Automated IaC and SCA scanning — scans infrastructure-as-code and dependency manifests for vulnerabilities after every task |

## Installation

```bash
# Clone the repository
git clone git@github.com:lacework/forticnapp-llm-plugins.git
cd forticnapp-llm-plugins

# Register the marketplace and install a plugin
claude plugin marketplace add $PWD
claude plugin install code-security@fortinet-plugins
```

Or install from a GitHub Release:

```bash
gh release download -R lacework/forticnapp-llm-plugins -A zip
unzip -o forticnapp-llm-plugins-*.zip
cd forticnapp-llm-plugins-*

claude plugin marketplace add $PWD
claude plugin install code-security@fortinet-plugins
```

See each plugin's README for setup and configuration details.

## Adding a New Plugin

1. Create a directory under `plugins/<plugin-name>/`
2. Add `.claude-plugin/plugin.json` with name, version, description
3. Add hooks, skills, and scripts as needed
4. Register the plugin in `.claude-plugin/marketplace.json` with `"source": "./plugins/<plugin-name>"`
