---
name: fortinet:settings
description: Configure Fortinet Code Security plugin settings (enable/disable scanning globally or per repo)
user-invocable: true
---

# Fortinet Code Security Settings

Manage plugin settings for the Fortinet Code Security plugin.

## Config File

Settings are stored in `~/.lacework/plugins/code-security.json`.

Structure (v2):
```json
{
  "hooks": {
    "mode": "pre-commit",
    "enabled": true,
    "overrides": [
      {
        "path": "/absolute/path/to/repo",
        "enabled": false
      }
    ]
  }
}
```

- `hooks.mode` — `"pre-commit"` (default, scans before git commit) or `"post-task"` (scans after every Claude Code task)
- `hooks.enabled` — global kill switch for all scanning
- `hooks.overrides` — per-repo overrides, matched by path prefix (longest match wins)

### Legacy format (v1)

Older configs may use `hooks.stop.enabled` and `hooks.stop.overrides`. If `hooks.mode` is absent, treat as `mode=post-task` and use `hooks.stop.*` fields. When writing any change, migrate to v2 format.

## Behavior

When the user asks to **disable** or **enable** scanning without specifying scope, ask:

> Would you like to disable/enable scanning **globally** (all repos) or **just for this repo** (`<current working directory>`)?

If the user specifies scope directly, act without asking.

### Actions

**Show settings:**
1. Read `~/.lacework/plugins/code-security.json`
2. Display: scanning mode, global enabled status, any overrides
3. Show the resolved state for the current working directory

**Switch scanning mode:**
1. Read the config file (create if missing)
2. If v1 format, migrate to v2 (move `stop.enabled` → `hooks.enabled`, `stop.overrides` → `hooks.overrides`)
3. Set `hooks.mode` to the new value
4. Write back the file
5. Confirm: "Scanning mode switched to [mode]. Scans will now run [before git commit / after every task]."

**Disable/enable globally:**
1. Read the config file (create if missing, migrate v1 if needed)
2. Set `hooks.enabled` to `false` or `true`
3. Write back the file
4. Confirm the change

**Disable/enable for a specific repo:**
1. Read the config file (create if missing, migrate v1 if needed)
2. Check if an override already exists for the repo path (normalize trailing slashes)
3. If exists: update the `enabled` value
4. If not: add a new entry to the `overrides` array
5. Write back the file
6. Confirm the change, showing the resolved state

**Creating the config file:**
If `~/.lacework/plugins/code-security.json` does not exist:
1. Create the directory: `mkdir -p ~/.lacework/plugins`
2. Write the default v2 config with the requested change applied

## Resolution Logic

When determining if scanning is enabled for a directory:
1. Check `hooks.enabled` — if `false`, scanning is disabled globally
2. Find all overrides where the directory path starts with the override's `path` (prefix match)
3. Pick the longest (most specific) matching path
4. If a match is found, use that override's `enabled` value
5. If no match, fall back to the global `hooks.enabled` value
6. If the config file doesn't exist, scanning is enabled by default

## Output

After any change, show:
```
Fortinet Code Security Settings updated:
- Scanning mode: pre-commit / post-task
- Scanning (global): enabled/disabled
- This repo (<path>): enabled/disabled (via override / via global default)
```

## Important

- Always use absolute paths for overrides (use the current working directory)
- Normalize paths: strip trailing slashes before comparing or storing
- Do not add duplicate overrides for the same path — update existing entries
- Preserve any other settings in the config file when writing changes
- When migrating v1 to v2, preserve all existing overrides
