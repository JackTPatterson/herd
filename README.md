# Herd

A native macOS app for [herdr](https://herdr.dev): herdr's persistent server
runs every terminal and agent, libghostty renders the herdr client, and Herd
draws Warp-style native chrome (project sidebar, top tabs, agent state and
vendor hues). Claude Code subagents open as named background tabs showing
their live transcript. Design and scope: [docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 14+, Xcode 26/27, `xcodegen` (`brew install xcodegen`)
- herdr 0.9+ (`brew install herdr`)
- `Vendor/GhosttyKit.xcframework`: a prebuilt libghostty. Currently a symlink to
  the cmux build cache (`~/.cache/cmux/ghosttykit/*/GhosttyKit.xcframework`).

## Build and run

```sh
xcodegen generate
xcodebuild -project Herd.xcodeproj -scheme Herd -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Herd.app
```

Tests: `xcodebuild -project Herd.xcodeproj -scheme HerdCore -derivedDataPath build/DerivedData test`

Herd runs its own herdr session (`herdr --session herd`) with a managed config
in `~/Library/Application Support/Herd/herdr-config.toml`, so a plain `herdr`
elsewhere is unaffected. Workspaces persist in that session across relaunches.

## Subagent tabs

Menu **Herd → Install Subagent Tabs Hook** (or
`Herd.app/Contents/MacOS/herd-cli install-subagent-hook [agent]`) adds a
`PreToolUse` hook for `Agent|Task` to each installed agent's own config —
`~/.claude/settings.json`, `~/.codex/hooks.json` — keeping a
`.herd-backup` beside it. Agents share the hook format, so supporting another
one is a row in `SubagentHookInstaller.specs`. The hook does nothing outside
Herd panes. Reinstall after moving Herd.app, since it stores the herd-cli path.

## Agents

Nothing in Herd is tied to one vendor. Agents keep their config in
`~/.<agent>`, with `skills/` and a prompts folder, so Herd discovers whichever
are installed (Claude Code, Codex, Qwen, Kiro, Copilot, …) and treats them
alike: the shared library installs into each, the slash menu reads each one's
own commands, recovery resumes each with its own resume command, and a
capability flag decides whether Herd drives its `mcp` and `plugin` CLIs.

## Command palette

⌘P (or ⌘⇧P, or click the title bar search) opens a Warp-style palette that
fuzzy-searches everything:

| Filter | Prefix | Contents |
| --- | --- | --- |
| Actions | `>` | every command (tabs, panes, workspaces, worktrees, sidebar, herdr config, Claude hook), with shortcuts |
| Workspaces | `%` | all workspaces with project, branch, and agent state |
| Tabs | `#` | tabs across all workspaces, including subagent tabs |
| Agents | `@` | running agents; jumps to their pane |
| Projects | `/` | folders under ~/Developer, ~/Projects, ~/code, ~/src; opens or focuses a workspace |
| Plugins | `!` | herdr plugin actions and panes, enable/disable, logs, unlink/uninstall, install from GitHub, link a local folder, marketplace |

↑↓ or ⌃N/⌃P to move, ↩ to run, ⇥ to cycle filters, esc to close. With an empty
query it shows your 3 most recent picks first. Rename Tab/Workspace and New
Worktree ask for text inline.

## Plugins

Herd runs herdr plugins (event hooks, startup commands, panes, link handlers)
unchanged, since herdr's server owns them. The palette's `!` filter adds what
herdr's hidden UI would otherwise provide: invoke plugin actions (with the
focused workspace/tab/pane as context), open plugin panes, enable/disable,
browse run logs, and install from GitHub after reviewing herdr's install preview in a
confirmation dialog. Plugins that only render into herdr's text sidebar
(e.g. herdr-radar) have no effect in Herd; Herd's native sidebar covers that.

## Session recovery

Herd journals every agent pane it sees (agent, session id, working folder,
workspace and tab labels) to `~/Library/Application Support/Herd/agent-sessions.json`.
Session ids come from herdr's own integration when one is installed
(Settings → Agents & Recovery), and otherwise from the agents' own files:
Claude's transcripts under `~/.claude/projects`, Codex's `session_meta`
rollouts under `~/.codex/sessions`.

When a shutdown, crash, or herdr restart kills sessions that were running the
last time Herd looked, a panel in the bottom right lists them and resumes the
ones you pick with `claude --resume <id>` / `codex resume <id>` in their own
workspaces, recreating a workspace that is gone. Each row can also copy its
resume command. The palette's **Recover Agent Sessions…** lists past sessions
at any time. Settings → Agents & Recovery turns the offer off.

## Marketplace

⌘⇧M (or the palette's **Marketplace…**) opens one window for every agent on
the machine:

| Section | Source | Installs into |
| --- | --- | --- |
| MCP Servers | `claude mcp list`, `codex mcp list` | `claude mcp add` / `codex mcp add`, from one definition |
| Plugins | `<cli> plugin list --json --available` across all configured marketplaces | `<cli> plugin install` |
| Skills | `~/.agents/skills/<name>/SKILL.md` | symlinked into each agent's `skills/` |
| Prompts | `~/.agents/prompts/<name>.md` | symlinked into `~/.claude/commands` and `~/.codex/prompts` |

A chip per agent shows where each item is installed; clicking it adds or
removes it there. Skills and prompts are vendor-neutral: they live once in the
shared library and are linked into each agent, so an edit reaches all of them.
Herd can adopt skills and prompts an agent already had, import a folder of
prompt files, and send a prompt straight to a running agent
(herdr's `agent.prompt`).

### Hot swap

New MCP servers and plugins only load when an agent starts, so after a change
the Marketplace offers **Reload Agents**: each running agent is relaunched in
its own tab with `--resume`, keeping the conversation. Agents whose session id
Herd doesn't know yet, or whose tab is split across panes, are skipped and
named. Also in the palette as **Reload Running Agents**.

## Slash menu

Typing `/` at an empty agent prompt opens Herd's own command menu instead of
the agent's in-terminal list: the agent's built-ins, your own and the
project's prompt files, and every installed plugin's commands, fuzzy
searchable. Herd replaces the prompt for these, so ↩ **runs** the command;
⌘↩ types it without running, and esc passes through what you typed.

Commands with arguments open a submenu filled from what the machine actually
has: `/mcp` lists your configured servers, `/model` your agent's models (and
each model's reasoning levels), `/resume` the sessions Herd can resume,
`/agents` and `/output-style` what's on disk. Prompt files in folders nest as
`/git` → `amend`, and a plugin with several commands gets its own submenu. →
opens one, ← goes back. A command that still wants free text is always typed,
never run blind.

Settings → Agents & Recovery turns the menu, or just the running, off.

## Tab names that follow the work

Agents and shells publish what they're doing as the terminal title, so Herd
renames a tab to match once the title holds still for a couple of seconds:
switch task inside a workspace and the tab stops reading as the task you
started with. A tab you rename yourself is never renamed again, and split
tabs are left alone. Settings → Agents & Recovery turns it off.

## Confirmations

Herd asks in its own dialog rather than a system alert, themed with the rest
of the window: quitting, closing idle workspaces, reloading agents, removing
a plugin, resetting settings, and the plugin install preview all use it.

## Clipboard

Copying looks identical whether or not it worked, so Herd confirms it in its
own toast with a line of what landed there. herdr publishes no clipboard
event, so Herd watches the pasteboard while it is the active app, which
catches every route: copy-on-select, ⌘C, herdr's copy mode, and plugins.
Settings → Terminal turns it off. (If your agent notifications are set to
"system", herdr may also post its own notification for copies made in its
copy mode; setting notifications to Herd or off leaves only this toast.)

## Toasts

Actions whose result isn't immediately visible or that take time show a
progress toast (after 200 ms) and a confirmation or failure toast: plugin
install (download → preview dialog → install), uninstall (with confirmation),
enable/disable, link/unlink, plugin action runs (tracked until the command
finishes), new worktree, herdr config reload, and the Claude hook. Instant,
visible actions (tabs, panes, workspaces, renames) stay silent unless they fail.

## Shortcuts

| Keys | Action |
| --- | --- |
| ⌘P | Command palette |
| ⌘O | Open folder as workspace |
| ⌘D / ⌘⇧D | Split pane right / down |
| ⌘⇧↩ | Toggle pane zoom |
| ⌘⌥←↑→↓ | Focus pane in direction |
| ⌘T / ⌘W | New / close tab |
| ⌘1…⌘9 | Tab 1–9 (9 = last) |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌃⌘↑ / ⌃⌘↓ | Previous / next workspace |
| ⌘N | New workspace |
| ⌘B | Toggle sidebar |

## Borrowed code and assets

- Ghostty macOS surface view — MIT (`Herd/Terminal/Ghostty/LICENSE-ghostty`)
- herdr-radar vendor hues, display names, logo and state SVGs — MIT (`docs/LICENSE-herdr-radar`)
- Warp Dark theme values and vertical-tab metrics (`warpdotdev/Warp`, MIT UI crates)
- Transcript renderer and project-root resolver from the author's cmux fork

## Debugging

`HERD_SNAPSHOT_DIR=/tmp/snap open -n --env HERD_SNAPSHOT_DIR=/tmp/snap Herd.app`
writes `window.png` and `terminal.txt` every second (no Screen Recording
permission needed).
