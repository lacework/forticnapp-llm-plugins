---
name: fortinet:settings
description: Configure Fortinet Code Security plugin settings (enable/disable scanning globally or per repo)
user-invocable: true
---

# Fortinet Code Security Settings

Manage plugin settings for the Fortinet Code Security plugin.

## Config File

Settings are stored in `~/.lacework/plugins/code-security.json`.

Structure:
```json
{
  "hooks": {
    "stop": {
      "enabled": true,
      "overrides": [
        {
          "path": "/absolute/path/to/repo",
          "enabled": false
        }
      ]
    }
  }
}
```

- `hooks.stop.enabled` — global default for the stop hook (auto-scanning after tasks)
- `hooks.stop.overrides` — per-repo overrides, matched by path prefix (longest match wins)

## Behavior

When the user asks to **disable** or **enable** scanning without specifying scope, ask:

> Would you like to disable/enable scanning **globally** (all repos) or **just for this repo** (`<current working directory>`)?

If the user specifies scope directly (e.g., "disable scanning for this repo", "disable scanning globally"), act without asking.

### Actions

**Show settings:**
1. Read `~/.lacework/plugins/code-security.json`
2. Display the current global setting and any overrides
3. Show the resolved state for the current working directory

**Disable/enable globally:**
1. Read the config file (create it if missing — see "Creating the config file" below)
2. Set `hooks.stop.enabled` to `false` or `true`
3. Write back the file
4. Confirm the change

**Disable/enable for a specific repo:**
1. Read the config file (create it if missing — see "Creating the config file" below)
2. Check if an override already exists for the repo path (normalize trailing slashes)
3. If exists: update the `enabled` value
4. If not: add a new entry to the `overrides` array
5. Write back the file
6. Confirm the change, showing the resolved state

**Creating the config file:**
If `~/.lacework/plugins/code-security.json` does not exist:
1. Create the directory: `mkdir -p ~/.lacework/plugins`
2. Write the default config with the requested change applied

## Resolution Logic

When determining if scanning is enabled for a directory:
1. Find all overrides where the directory path starts with the override's `path` (prefix match)
2. Pick the longest (most specific) matching path
3. If a match is found, use that override's `enabled` value
4. If no match, fall back to the global `hooks.stop.enabled` value
5. If the config file doesn't exist, scanning is enabled by default

## Output

After any change, show:
```
Fortinet Code Security Settings updated:
- Stop hook (global): enabled/disabled
- This repo (<path>): enabled/disabled (via override / via global default)
```

## Important

- Always use absolute paths for overrides (use the current working directory)
- Normalize paths: strip trailing slashes before comparing or storing
- Do not add duplicate overrides for the same path — update existing entries
- Preserve any other settings in the config file when writing changes
