# Roadmap

This fork of [farouqaldori/vibe-notch](https://github.com/farouqaldori/vibe-notch) is Aban's own build of the notch app: it is not sent upstream, and useful upstream changes are pulled in by hand. The design below was settled in a grilling session on Oct 20 and 21, 2026; this file holds it. Rule: one phase finished before the next starts.

## Ground rules

- **Branches and PRs:** one branch and one PR per phase, into this fork's `main`. Always pass `--repo AbanAlfaify/vibe-notch` to `gh pr create`: in a fork, `gh` targets the upstream repo by default.
- **Sessions covered:** terminal `claude` sessions and the Desktop Code tab, both through the bridge mod.
- **Trust:** no telemetry, no auto-update, no network calls beyond the local socket, never the Keychain.
- **Tests:** a Swift test target for pure logic, written test first; the mod's tests run with `claude plugin test`; the notch UI is checked by hand in the running app.
- **This Mac:** no tmux, no yabai; sessions run in Terminal.app, Cursor and the Desktop Code tab; Xcode 27.1; signing identity "Apple Development: Aban Alfaify", team `L2Z9AQ34Q3`.

## Phase 0: fork cleanup

1. **Mixpanel out:** the `mixpanel-swift` package, the token, distinct ID and super properties in `AppDelegate.swift`, the `Session Started` event in `SessionStore.swift`, the Claude version scan that only fed Mixpanel, and the README's analytics section.
2. **Sparkle out:** the package, `SUFeedURL`, `SUPublicEDKey` and `SUEnableAutomaticChecks` in `Info.plist`, the updater and its hourly timer in `AppDelegate.swift`, `Services/Update/NotchUserDriver.swift`, the menu's `UpdateRow`, `scripts/create-release.sh` and `scripts/generate-keys.sh`.
3. **Identity:** bundle ID `com.abanalfaify.vibenotch` (both build configurations, and the single-instance fallback in `AppDelegate.swift`); `DEVELOPMENT_TEAM = L2Z9AQ34Q3`; the leftover "Claude Island.app" names in the product reference and the scheme's `BuildableName` become "Vibe Notch.app". The name stays Vibe Notch.
4. **Menu:** the "Star on GitHub" row goes.
5. **Build and install:** `scripts/install.sh` builds Release with Xcode, signs for team `L2Z9AQ34Q3`, quits a running copy, replaces `/Applications/Vibe Notch.app` and launches it. It replaces `scripts/build.sh`. No DMG, no notarizing.
6. **Dead code out:** `AgentFileWatcher`, `ToolEventProcessor`, `FileSyncScheduler`, `TmuxSessionMatcher`, `respondToPermissionBySession` and its failure callback, and the unused `notchPop`/`notchUnpop`.
7. **tmux and yabai out:** everything under `Services/Tmux/`, `YabaiController`, the yabai paths in `WindowFinder` and `WindowFocuser`, `TmuxTarget`, `isInTmux`, the tmux branch of `TerminalVisibilityDetector`, the eye (focus) button, and the chat input bar. Reply and jump come back in Phase 1, built on the mod.
8. **README:** rewritten for the fork: what it is, how to build and install, and a pointer here.

Phase 0 still ships upstream's hook installer, which rewrites `~/.claude/settings.json` on launch. Back that file up before the first launch; Phase 1 removes the installer and cleans up after it.

**Done when:** `scripts/install.sh` builds, installs and launches the app; sessions still show through upstream's hooks as before; `grep -ri 'mixpanel\|sparkle\|tmux\|yabai'` over `ClaudeIsland/` finds nothing; the PR is open against this fork.

## Phase 1: the aban-notch bridge

A Claude Code mod named `aban-notch` replaces upstream's hook script. The app stops touching `~/.claude` entirely.

### The mod

- **Where:** `mod/aban-notch/` (`.claude-plugin/plugin.json`, `hooks/hooks.json`, `hooks/register.tsx`, `types/index.d.ts`, `tests/`). `.claude-plugin/marketplace.json` at the repo root, marketplace name `vibe-notch`. The `aban-mods` marketplace gets an entry pinned by commit (HTTPS `git-subdir` with `sha`), like the community mods there.
- **What it uses:** `$.http.fetch` and `$.clock` only. No `$.process`, no helper binaries, no Python.
- **Off macOS:** when `$.env.get('OS') === 'Windows_NT'` every hook returns `next(e)` and nothing is sent. Anywhere else, a missing socket makes every send a silent no-op.

### Transport

- HTTP over the Unix socket `~/.vibenotch/bridge.sock` (folder `0700`, socket `0600`), the path built from `$.env.get('HOME')` and kept under 100 bytes.
- **Mod to app:** JSON posts, each carrying `protocol: 1` and the `sessionId`:
  - `POST /session` announces a session on `session.start`, and again on `classic.SessionStart` (a `/clear` continues under a new ID with no `session.start`): `cwd`, `surface`, `transcriptPath`, title, model, the launching app's bundle ID from `__CFBundleIdentifier` and `TERM_PROGRAM`.
  - `POST /heartbeat` every 10 s with the session's state. The app drops a session after 30 s of silence, and at once on `session.end`. Idle sessions stay listed, and the list rebuilds within 10 s of an app restart.
  - `POST /event` for prompt submits, tool start and end, turn complete, compaction, subagent start and stop, notifications.
  - `POST /permission` is held open until the person answers; the response body is the decision.
- **App to mod:** the mod keeps `GET /commands` open per session (a long-poll, renewed on every answer or timeout). Today it carries reply text, which the mod sends with `$.prompt.submit({ text, asUser: true })`; it runs once the session is idle.
- **App side:** a `BridgeServer` replaces `HookSocketServer`. It is owned by `AppDelegate`, not a SwiftUI view: today `NotchView` owns `ClaudeSessionMonitor` as a `@StateObject`, so a screen change restarts monitoring. `AnyCodable` moves out of `HookSocketServer.swift` before that file goes.

### Approvals

- **Spike first:** does `classic.PermissionRequest` race Claude's own dialog, both shown and the first answer winning?
  - **Yes:** the mod hooks it, posts to the notch and awaits. When the person answers in Claude first, the hook's `next.signal` aborts and the notch clears the prompt.
  - **No:** the mod hooks `tool.check`, calls `next(e)`, and sends only an `ask` verdict to the notch. The notch has it alone for 15 s, then the hook returns `ask` and Claude's dialog appears too. "Answer in Claude" returns `ask` at once.
- The notch only sees prompts Claude would have shown: anything auto mode or allow rules settle never reaches it. With the app not running, the hook passes straight through.
- **Allow, deny, deny with a note:** the note goes back to Claude as the denial message.
- **Always allow:** applies Claude's own suggested rule (`permission_suggestions` to `updatedPermissions`). Only on the `classic.PermissionRequest` path; dropped otherwise.
- **Questions and plan approvals** (AskUserQuestion, ExitPlanMode): shown with a Jump button and answered in Claude. A mod can only tighten those.
- **Fix:** `SessionPhase.canTransition` refuses `waitingForInput` to `waitingForApproval` (`SessionPhase.swift:116-122`), so an approval arriving while a session waits for input is lost.

### App changes

- Delete `HookInstaller.swift`, `claude-island-state.py` and `HookSocketServer.swift`.
- One-time migration on first launch: remove upstream's `claude-island-state.py` entries from `~/.claude/settings.json` (backed up first) and the script from `~/.claude/hooks`. After that the app never writes there.
- The menu's Hooks toggle becomes a "Mod connected" row; with no session announced, the notch shows the install line instead of an empty list.
- The Claude folder picker goes: chat history reads the `transcriptPath` each session announces.
- **Reply box:** back in chat view for every session, through `GET /commands`.
- **Jump:** activates the session's app by the announced bundle ID (Terminal, Cursor or Claude). Not the exact tab.
- **Sound:** for terminal sessions only. Desktop sessions are shown silently, since the Desktop app already notifies.

**Done when:** a terminal session and a Desktop Code tab session both show in the notch; an approval answered in the notch reaches Claude, and one answered in Claude clears the notch; a reply from the notch runs as a turn; the app restarts and the list rebuilds; `claude plugin validate` and `claude plugin test` pass; the Swift tests pass; the PR is open.

## Phase 2: Claude Pulse features

- **Usage:** the mod forwards `session.measure` pushes (`context`, `rateLimits`, `cost`) plus a first `$.session.usage()`. The header shows the `five_hour` and `seven_day` meters with reset times; with no session running, the last known values and their age. Each session row shows its context fill, replacing upstream's token count (which sums every assistant line and leaves out cache tokens).
- **Keyboard:** a global key monitor, asking for Accessibility on first use. Double-tap Control opens the notch from anywhere (hardcoded). While open: 1 to 9 select a session, Enter approves, Shift+Enter batch approves, D denies, Shift+D denies with a note, A always allows (if Phase 1 kept it), Esc closes without denying.
- **Batch approval:** approves every pending prompt that the classifier calls safe, across all sessions; the rest stay waiting.
- **Classifier** (pure Swift, test first):
  - **Safe:** Read, Grep, Glob, WebFetch, WebSearch; Edit and Write inside the session's folder; Bash that matches nothing on the danger list.
  - **Danger list:** `rm -r`, `git push --force` or `-f`, `git reset --hard`, `git clean -f`, `git checkout -- .`, `git restore .`, `DROP`, `TRUNCATE`, `sudo`, recursive `chmod` or `chown`, `dd`, `mkfs`, `curl ... | sh`, `gh pr merge`, `gh repo delete`, `npm publish`, `eas submit`.
  - **Always manual:** the danger list, MCP tools, and writes outside the folder.
- **Focus aware:** when a session needs the person and its app is already in front, the notch bounces instead of expanding. App level, not tab level.
- **Hover:** the notch closes when the mouse leaves, unless it was clicked open or an approval is showing. A menu toggle, on by default.
- **Accessibility:** no bounce or spring with Reduce Motion on; VoiceOver labels on rows, meters and approval buttons.

## Phase 3: aban-mods in the notch

- The mod reads aban-statusline's `skill` and `agents` and test-pane's `views`, at start and through `state.set` hooks, and forwards them. Agent names come from `$.agent.list()`; the band only keeps a count.
- The notch shows the active Matt skill, the running agents (count and names), and test-pane's latest lines as text. A row is hidden when its mod is not installed.
- Usage and context meters are Phase 2's, so they do not repeat here; boss-fight and the wayfinder maps stay in Claude.

## Not doing

tmux and yabai, Claude Pulse's tmux pane routing, per-tab focus, Pulse's ambient animations, answering questions or plan approvals from the notch, Keychain reads, DMG or notarized releases, PRs upstream, YouTrack tickets.

## Architecture review

A separate session ran `/mattpocock-skills:improve-codebase-architecture`; its report lands as `docs/architecture-review.md` on branch `claude/arch-review-8900c3`. The findings it reported so far are folded in above: `AnyCodable` living in `HookSocketServer.swift`, `ToolApprovalHandler.sendMessage` being live (it backs the tmux reply box), the monitor's lifetime tied to `NotchView`, and the lost `waitingForInput` to `waitingForApproval` transition.
