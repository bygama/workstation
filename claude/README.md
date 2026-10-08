# Claude Code

This folder owns the user-level Claude Code configuration that should survive a Windows
reinstall. It contains current desired state, not an inventory of old plugins, skills, or
experiments.

## Apply it

```powershell
pwsh claude\install.ps1
pwsh claude\install.ps1 -WhatIfOnly
pwsh claude\install.ps1 -Secrets
```

The normal run requires the native Claude Code CLI, registers the declared marketplaces,
installs or enables every desired plugin, installs the global instructions, reconciles the
repo-owned global rules directory, junction-links the declared skill source repos, and
merges `settings.json` into `~/.claude/settings.json`. `-Secrets` additionally syncs the
MCP servers declared in `mcp.template.json` through Claude's user-scope MCP CLI.

Before replacing a live file, the shared installer stores its original path under one
run-specific directory in `~/.workstation-backup/`. The settings result is checked with
`claude doctor`; a non-zero result makes the step fail.

## Files and ownership

| File | Responsibility |
| --- | --- |
| `CLAUDE.md` | Short global user instructions |
| `settings.json` | Repo-owned settings, permissions, and desired plugins |
| `hooks.json` | Repo-managed hook entries, MERGED into live hooks (Orca-injected hooks survive). Repo entries are recognized by the `.ps1` script they call and replaced in place, so command/timeout edits propagate. Paths use `${CLAUDE_HOME}` — resolved to the absolute `~/.claude` at install time, because the hook runner's shell expands no variables |
| `hooks/` | Hook scripts applied to `~/.claude/hooks/` — CANONICAL here since MAT-110; the standard's generic wiring doctrine lives at `Agent-Engineering/reference/global-layer.md` |
| `marketplaces.json` | Marketplace names and reproducible GitHub sources |
| `rules/common/` | Complete set of repo-owned global rules; currently empty |
| `mcp.template.json` | Managed MCP definitions and names of external MCP integrations |
| `plugins.md` | Current plugin and MCP architecture |
| `skills.md` | Current policy for user-directory and plugin skills |

Repo settings override the same keys in the live file. Other valid live keys are preserved.
Legacy hook structures that cause Claude to reject the entire file are discarded, while the
complete original file remains in the run backup.

## Skills and statusline

User skills are junction links into the skill source repos —
`repos\pegasuz\agent-engineering\skills\` and `repos\mine\skills\skills\` — the installer
creates one link per skill directory found there, so a skill added to either repo appears
on the next run with no copy step. The statusline is the `hud` repo (`repos\mine\hud`),
declared in `settings.json` as desired state. `skills` and `hud` are cloned by `dev/repos`;
AE lives in the Pegasuz organisation and is cloned by the Pegasuz workspace
(`pegasuzhq/workspace` cloned as `repos\pegasuz`, then its `./bootstrap.sh --group core`).
All three must be in place before this step can succeed on a clean machine.

`claude/CLAUDE.md` is CANONICAL here (MAT-110; `Agent-Engineering/global/` no
longer exists). Edit it here, then re-run the installer to apply it to
`~/.claude/CLAUDE.md` — in-place, preserving the dual-account hardlink.

<details>
<summary>Old pattern: OMC (removed 2026-07-30)</summary>

oh-my-claudecode previously owned hooks, 19 agents, ~37 skills, a generated block between
`OMC:START`/`OMC:END` markers in the live CLAUDE.md, and the statusline. It was removed
after a 19-agent audit (2026-07-30); its
`omc setup --force-hooks` quirk only matters if it is ever reinstalled.
</details>

## Secrets and MCP

Copy `secrets/.env.example` to `secrets/.env`, fill every required value, then run with
`-Secrets`. The installer validates all placeholders before changing anything and uses:

```powershell
claude mcp add-json --scope user
```

Current Claude Code stores those servers in `~/.claude.json`; the repo never writes the old
`~/.claude/mcp-configs/mcp-servers.json` location. If that obsolete file exists after a
successful migration, it is backed up and removed.

`pencil` is listed as externally managed because the Pen desktop app (`pen.dev`, formerly
Pencil) registers its own local server under that name. MCPs supplied by enabled Claude
plugins are also kept out of the user-scope list to avoid shadowing plugin-owned
definitions.

GitHub uses its current hosted HTTP MCP endpoint. Its credential remains local in
`secrets/.env` and in Claude's user-scope configuration; the repository contains a
placeholder only.

The three local reference servers run through `cmd /c npx`, the Windows launch form
documented by the MCP project. Memory stores its graph at
`~/.claude/mcp-memory.jsonl` instead of inside npx's package cache, so updating the package
does not discard it. That JSONL file is local data, not a secret and not versioned here.

## What stays manual

| What | How |
| --- | --- |
| Claude login | Run `claude` and complete OAuth in the browser |
| MCP credentials | Create `secrets/.env` from the example, then use `-Secrets` |
| Pen MCP | Install and start the Pen desktop app; it owns the connection |
