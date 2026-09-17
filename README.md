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

## Claude subagent tabs

Menu **Herd → Install Claude Subagent Tabs Hook** (or
`Herd.app/Contents/MacOS/herd-cli install-claude-hook`) adds a `PreToolUse`
hook for `Agent|Task` to `~/.claude/settings.json` (backup:
`settings.json.herd-backup`). It does nothing outside Herd panes. Reinstall
after moving Herd.app, since the hook stores the herd-cli path.

## Shortcuts

| Keys | Action |
| --- | --- |
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
