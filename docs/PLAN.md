# Herd — native macOS app for herdr

Herd is a native window around [herdr](https://herdr.dev). herdr's server owns
every terminal and agent; Herd embeds libghostty to render the herdr client and
replaces herdr's text sidebar and tab row with native, Warp-styled chrome driven
by herdr's socket API.

## Architecture

```
┌ Herd.app ──────────────────────────────────────────────────────────────┐
│ Title bar: traffic lights · sidebar toggle · search (⌘K)               │
├───────────────┬────────────────────────────────────────────────────────┤
│ Sidebar       │ Tab bar (herdr tabs of the focused workspace)          │
│ projects      ├────────────────────────────────────────────────────────┤
│  └ workspaces │ libghostty surface running                             │
│     agent     │   herdr --session herd                                 │
│     state/hue │   (HERDR_CONFIG_PATH → Herd's config: herdr sidebar    │
│               │    hidden, own tab row hidden when possible)           │
└───────────────┴────────────────────────────────────────────────────────┘
        ▲ session.snapshot + events.subscribe      │ workspace.focus / tab.focus / tab.create
        └──────────── ~/.config/herdr/sessions/herd/herdr.sock ◀──────────┘
```

- **Session:** Herd runs its own named herdr session (`herd`) so a plain
  `herdr` in another terminal is untouched.
- **State:** a store subscribes to herdr events and re-fetches
  `session.snapshot` (debounced) on any change.
- **Projects:** workspaces are grouped by git repository root (worktrees join
  their main repo) of the workspace's cwd.
- **Agents:** herdr's agent records (`agent`, state `working|blocked|idle|done`)
  drive a status glyph and a soft per-agent hue (Warp tab colors at 15%).
- **Subagents:** a Claude Code `PreToolUse` hook (`herd-cli hook claude`) opens
  a herdr tab named after the subagent in the same workspace, running
  `herd-cli agent-watch` (live transcript view) and reporting working/done to
  herdr so the tab shows real state.

## v1 scope (definition of done)

1. App builds with xcodegen + xcodebuild; launches a window.
2. libghostty terminal renders the herdr client; keyboard, IME text, mouse,
   scroll, resize, focus, and clipboard work.
3. Native sidebar: projects → workspaces, focused highlight, agent state glyph
   and hue, click focuses the workspace in herdr; live updates.
4. Native top tab bar for the focused workspace's tabs; click focuses, `+`
   creates, close button closes; subagent tabs show their names and state.
5. Warp dark styling: #050505 terminal, #171717 chrome, 1px #262626 borders,
   4pt radii, 248pt sidebar, accent #19AAD8, uppercase group headers.
6. Shortcuts: ⌘T new tab, ⌘W close tab, ⌘1–9 tab, ⌃⌘↑/↓ workspace,
   ⌘B toggle sidebar, ⌘N new workspace.
7. Subagent tabs: hook installer + agent-watch viewer, verified end to end.
8. Unit tests for socket parsing, project grouping, agent hues, transcript
   rendering.

Out of v1: command palette/search, settings UI, multiple windows, SSH machines,
packaging/signing/notarization.
