<div align="center">
  <img src="ClaudeIsland/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Logo" width="100" height="100">
  <h3 align="center">Vibe Notch</h3>
  <p align="center">Aban's build of the notch overlay for Claude Code sessions.</p>
</div>

## What it is

Vibe Notch is a macOS menu bar app that shows your Claude Code sessions in an overlay that grows out of the MacBook notch. It lists running sessions with their state, shows each session's chat history, and lets you allow or deny a tool call without switching windows.

This repo is a fork of [farouqaldori/vibe-notch](https://github.com/farouqaldori/vibe-notch). It is a personal build: nothing here is sent upstream, and useful upstream changes are pulled in by hand.

Compared with upstream, this fork:

- sends no telemetry (Mixpanel is gone);
- never updates itself (Sparkle is gone); you rebuild it from source;
- has no tmux or yabai support. Replying from the notch and jumping to a session's window come back in Phase 1, built on a Claude Code mod.

## Requirements

- macOS 15.6 or later
- Xcode 27.1
- The Claude Code CLI
- An Apple Development signing identity for team `L2Z9AQ34Q3`. To build under another team, change `DEVELOPMENT_TEAM` in the project and `TEAM_ID` in `scripts/install.sh`.

## Build and install

```bash
./scripts/install.sh
```

The script builds the Release configuration with Xcode (Swift packages resolve from GitHub on the first build), checks that the app is signed for team `L2Z9AQ34Q3`, quits any running copy, replaces `/Applications/Vibe Notch.app` and launches it. Build output goes to `build/`, which git ignores. There is no DMG and no notarizing.

## How it works today

On launch the app still runs upstream's hook installer. It copies `claude-island-state.py` into `~/.claude/hooks/` and adds hook entries for it to `~/.claude/settings.json`. Claude Code then runs that script on each hook event, and the script reports to the app over the Unix socket `/tmp/claude-island.sock`.

The installer rewrites `~/.claude/settings.json`, so back that file up before the first launch:

```bash
cp -p ~/.claude/settings.json ~/.claude/settings.json.before-vibe-notch
```

Phase 1 replaces the hook script with the `aban-notch` mod and removes what the installer added.

## Roadmap

The plan for this fork, phase by phase, is in [ROADMAP.md](ROADMAP.md).

## License

Apache 2.0, see [LICENSE.md](LICENSE.md).
