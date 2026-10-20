# Architecture review: deepening candidates

Date: 2026-10-20. Base: `10f1d24` (v1.3.2). Method: `/improve-codebase-architecture`, using the `/codebase-design` vocabulary (**module**, **interface**, **implementation**, **depth**, **seam**, **adapter**, **leverage**, **locality**).

This is analysis only. No Swift code was changed.

## Scope

The review covers the code that stays after Phase 0. It treats the following as already gone:

- Mixpanel and Sparkle (`Services/Update/*`)
- `HookInstaller` and `Resources/claude-island-state.py`
- `AgentFileWatcher`, `ToolEventProcessor` and `FileSyncScheduler`
- `TmuxSessionMatcher`, `ToolApprovalHandler` and the rest of `Services/Tmux/*`
- `TmuxTarget` and `YabaiController`

`HookSocketServer` is reviewed only to find the seam its replacement plugs into. No candidate deepens a module that is about to be deleted.

The planned work this review is measured against:

- **Phase 1:** the bridge, a mod that sends HTTP over `~/.vibenotch/bridge.sock`. It includes long-polls, a heartbeat every 10 s with a drop after 30 s, and approvals where the first answer wins.
- **Phase 2:**
  - plan usage meters and a context % on each session row;
  - the keyboard map;
  - the safe/danger classifier;
  - a focus-aware bounce.
- **Phase 3:** statusline skills/agents rows and a test-pane row.
- **Tests:** a Swift test target for pure logic, plus `claude plugin test` for the mod.

## Ranked candidates

| # | Candidate | Strength | Dependency category | Planned work it unblocks |
|---|---|---|---|---|
| 1 | [Session reducer: a pure core inside `SessionStore`](#1-session-reducer-a-pure-core-inside-sessionstore) | Strong | in-process | P1 heartbeat and first-answer-wins, P2 batch approve and classifier |
| 2 | [Session bridge port: the seam for the `HookSocketServer` replacement](#2-session-bridge-port-the-seam-for-the-hooksocketserver-replacement) | Strong | ports & adapters | All of P1. P2 reply text |
| 3 | [Transcript fold and tail](#3-transcript-fold-and-tail) | Strong | in-process + local-substitutable | P2 context %. "Chat history stays" without three copies |
| 4 | [Notch controller: commands, selection, key bindings, risk](#4-notch-controller-commands-selection-key-bindings-risk) | Strong | in-process + one port | P2 keyboard map and Shift+Enter batch approve |
| 5 | [Attention policy behind a focus probe](#5-attention-policy-behind-a-focus-probe) | Worth exploring | ports & adapters | P2 focus-aware bounce |
| 6 | [Row and header projection](#6-row-and-header-projection) | Worth exploring | in-process | P2 meters and context %, P3 rows |
| 7 | [Measured panel layout](#7-measured-panel-layout) | Worth exploring | in-process | P2/P3 rows without editing height constants |
| 8 | [Status feeds over the bridge](#8-status-feeds-over-the-bridge) | Speculative | n/a | P3 |

**Top recommendation: #1, then #2 inside the Phase 1 PR.**

- The reducer gives the bridge a typed place to land. That makes the server swap an adapter change rather than a `SessionStore` rewrite.
- It fixes a lost-update bug that exists today.
- It is the only way Phase 2's batch approve can see the inputs of the second and later pending approvals.

---

## 1. Session reducer: a pure core inside `SessionStore`

**Files:**
- `Services/State/SessionStore.swift`
- `Models/SessionEvent.swift`
- `Models/SessionPhase.swift`
- `Models/SessionState.swift`
- `Services/Session/ClaudeSessionMonitor.swift` (lines 39-75 hold lifecycle rules)

**Problem.** `process(_:)` is advertised as the single mutation point, but the implementation mixes the state machine with I/O. It calls `ConversationParser.shared`, sleeps in debounce `Task`s, runs `kill(pid, 0)`, runs `ps` through `ProcessTreeBuilder`, and reads `Date()`. Those awaits happen in the middle of a mutation. Specific problems:

- **Lost updates (existing bug):**
  - `processFileUpdate` takes a copy at `SessionStore.swift:555` (`guard var session = sessions[...]`).
  - It then awaits another actor at `:558` and at `:684` (`populateSubagentToolsFromAgentFiles(… session: &session …)`).
  - At `:691` it writes the stale copy back.
  - Swift actors are reentrant, so a hook processed during those awaits is overwritten. An example is a `PermissionRequest` moving the phase to `waitingForApproval`.
  - `emitToolCompletionEvents` (`:774`) also re-enters `process` recursively.
- **Approval queue with no inputs:**
  - "Advance to the next pending approval" is copy-pasted four times (`:382-417`, `:453-468`, `:484-518`, `:520-550`).
  - Each copy rebuilds the next `PermissionContext` from `chatItems` with `toolInput: nil` (`:394`, `:458`, `:496`, `:532`).
  - So the second and later pending approvals have lost their input.
- **Dead events:** 5 of the 15 `SessionEvent` cases are dead. The four `subagent*` cases have no sender, and `agentFileUpdated` is a no-op (`:114`).
  - `permissionSocketFailed` is effectively dead too, because only the never-called `respondToPermissionBySession` triggers it.
- **Two phase mappings that disagree:**
  - The two mappings are `HookEvent.sessionPhase` (`HookSocketServer.swift:53-77`) and `HookEvent.determinePhase()` (`SessionEvent.swift:131-163`).
  - They map `idle_prompt` and `ended` differently. Hook names are compared as strings in three files.
- **Lifecycle rules in the wrong module.** Cancel pending approvals on `Stop`, cancel one on `PostToolUse`, and start the interrupt watcher on `processing`. These rules live in `ClaudeSessionMonitor`'s callback (`:45-66`) and not in the state machine.

**Solution.** Split `SessionStore` into two modules:

- **A pure, synchronous reducer.** It takes the session set and one event and returns effects. It has no awaits, no clock reads and no singletons.
- **A thin actor.** It holds the state, runs the effects through ports (#2 and #3), and feeds their results back in as events.

Pending approvals become an ordered queue, with inputs, on each session. The `waitingForApproval` phase is derived from that queue being non-empty.

**Proposed interface** (first sketch, to pressure-test in grilling):

```swift
struct Sessions: Equatable, Sendable {
    private(set) var byId: [SessionID: SessionState]
    var ordered: [SessionState] { get }

    /// The only mutation. Synchronous: no I/O, no Date(), no singletons.
    /// Returns the effects the runner must perform.
    mutating func apply(_ event: SessionEvent, at now: Date) -> [SessionEffect]
}

enum SessionEvent: Equatable, Sendable {
    case bridge(BridgeEvent)                              // typed, from #2
    case transcriptAdvanced(SessionID, TranscriptDelta)   // from #3
    case approvalAnswered(ApprovalID, ApprovalDecision)   // the user acted in the notch
    case archived(SessionID)
    case tick                                             // heartbeat expiry: drop after 30 s of silence
}

enum SessionEffect: Equatable, Sendable {
    case refreshTranscript(SessionID)                     // the runner debounces
    case answerApproval(ApprovalID, ApprovalDecision)     // the runner calls SessionBridge.answer
    case sessionDropped(SessionID)
}

struct PendingApproval: Identifiable, Equatable, Sendable {
    let id: ApprovalID
    let toolUseId: String?
    let tool: String
    let input: JSONValue        // keeps its input, unlike today's follow-up contexts
    let receivedAt: Date
}

// On SessionState:
//   var approvals: [PendingApproval]   // FIFO; the phase is .waitingForApproval iff non-empty
//   var lastHeartbeat: Date
```

The interface hides the following:

- the phase transition table;
- placeholder tool items from `toolStarting`;
- subagent tracking;
- `/clear` handling;
- advancing the approval queue, written once;
- the 30 s expiry;
- deduplication of tool ids.

**Dependency category:** in-process. The ports belong to the runner, not to the reducer.

**Tests through the interface:**

```swift
var s = Sessions()
s.apply(.bridge(.approvalRequested(sid, a1)), at: t0)
s.apply(.bridge(.approvalRequested(sid, a2)), at: t0)
let fx = s.apply(.approvalAnswered(a1.id, .allow), at: t1)
#expect(s.byId[sid]?.approvals == [a2])                 // a2.input intact
#expect(fx == [.answerApproval(a1.id, .allow)])

s.apply(.bridge(.heartbeat(sid)), at: t0)
#expect(s.apply(.tick, at: t0 + 31) == [.sessionDropped(sid)])
```

**How it helps the planned work:**
- **Phase 0:** the Mixpanel, `isInTmux` and `ps` lines disappear instead of being worked around, and the five dead events are deleted.
- **Phase 1:**
  - Heartbeat expiry becomes one reducer rule. It replaces the PID poll at `SessionStore.swift:1072-1114`, which cannot see Desktop Code tab sessions anyway.
  - "First answer wins" becomes one rule: an `approvalSettled` event removes the queue entry, whoever answered.
- **Phase 2:** Enter, D, Shift+D and Shift+Enter act on `approvals`, and the classifier reads `PendingApproval.input`.
- **Bug class gone:** no reentrant lost updates, because the reducer never suspends.

---

## 2. Session bridge port: the seam for the `HookSocketServer` replacement

**Files:**
- `Services/Hooks/HookSocketServer.swift` (replaced)
- `Services/Session/ClaudeSessionMonitor.swift`
- `Models/SessionEvent.swift` (`HookEvent` extension)
- `AnyCodable` (`HookSocketServer.swift:560-615`)
- `UI/Views/ChatView.swift:357-516` (message sending, which was tmux)
- `UI/Views/NotchView.swift:20`
- `App/AppDelegate.swift`

**Where the replacement plugs in today.** The seam is the `HookSocketServer.start(onEvent:onPermissionFailure:)` / `respondToPermission(toolUseId:decision:reason:)` pair. Its only caller is `ClaudeSessionMonitor` (`:39-122`).

**Problem.** The interface leaks wire details to its caller:

- **Stringly typed:** decisions are strings, and `HookEvent` is a bag of optional strings compared with `event == "PreToolUse"` in three files.
- **Cancellation rules sit with the caller.** `ClaudeSessionMonitor` has to know to call `cancelPendingPermissions` on `Stop` and `cancelPendingPermission` on `PostToolUse`.
- **Guessed correlation:**
  - Claude Code's PermissionRequest carries no `tool_use_id`.
  - The server guesses one from a FIFO keyed on `sessionId:tool:sortedJSON(input)` (`:293-342`).
  - Held file descriptors have no timeout or disconnect detection.
- **Started from a view.** The pipeline is created by a SwiftUI `@StateObject` (`NotchView.swift:20`). Recreating the window on a screen change builds a new monitor and calls `start` again.
- **Message sending is tmux-only.** `ChatView`'s message sending uses `ToolApprovalHandler` and tmux (`ChatView.swift:465-516`). This means `ToolApprovalHandler` is *not* dead code as the plan assumed; it is the send path, and Phase 1 replaces it.

**Solution.** Define the seam as a port with three parts:

- a typed event stream in;
- two outbound calls: answer an approval, and submit reply text;
- wire decoding as a pure function.

It has two adapters: the HTTP-over-Unix-socket server in production, and an in-memory bridge for tests and SwiftUI previews. Assemble the pipeline once in `AppDelegate` and inject it into views.

**Proposed interface:**

```swift
protocol SessionBridge: Sendable {
    /// Every decoded message from every mod instance, in arrival order.
    var events: AsyncStream<BridgeEvent> { get }

    /// Completes the long-poll the mod holds for this approval.
    /// No-op if it already settled (Claude's own dialog answered first): first answer wins.
    func answer(_ id: ApprovalID, _ decision: ApprovalDecision) async

    /// Delivers reply text through the session's prompt long-poll ($.prompt.submit).
    func submitPrompt(_ text: String, to session: SessionID) async throws(BridgeError)
}

enum BridgeEvent: Equatable, Sendable {
    case sessionStarted(SessionInfo)     // id, cwd, pid, transcriptURL, surface: .terminal | .desktop
    case heartbeat(SessionID)
    case promptSubmitted(SessionID)
    case toolStarting(SessionID, ToolUse)
    case toolFinished(SessionID, toolUseId: String, outcome: ToolOutcome)
    case approvalRequested(SessionID, PendingApproval)
    case approvalSettled(ApprovalID, ApprovalDecision, by: ApprovalSource)  // .notch | .claudeDialog | .disconnected
    case stopped(SessionID), compacting(SessionID), idlePrompt(SessionID)
    case subagent(SessionID, SubagentSignal)
    case sessionEnded(SessionID)
}

enum BridgeWire {   // pure, no sockets
    static func decode(_ body: Data, route: String) throws(BridgeDecodeError) -> BridgeEvent
    static func encode(_ decision: ApprovalDecision) -> Data
}

enum ApprovalDecision: Equatable, Sendable { case allow, deny(note: String?) }
enum JSONValue: Equatable, Sendable, Codable { /* replaces AnyCodable */ }
```

The adapter hides the following:

- HTTP framing on the Unix socket;
- the long-poll registry, from approval id to held connection;
- closing held connections when an approval settles elsewhere;
- reporting disconnects as `approvalSettled(…, by: .disconnected)`;
- versioning;
- the JSON shape.

`JSONValue` being `Equatable` deletes the identity-only `PermissionContext ==` workaround (`SessionPhase.swift:56-63`).

**Dependency category:** ports & adapters. The mod is code the user owns, on the other side of a socket.

- **Production adapter:** `UnixSocketBridgeServer`.
- **Test adapter:** `InMemoryBridge`.

Two adapters make this a real seam.

**Tests:**
- `BridgeWire.decode` on JSON fixtures for every route:
  - PermissionRequest decodes to `.approvalRequested` with the input intact;
  - an unknown event gives a typed error, not a dropped message.
- `encode(.deny(note:))` matches the reply shape the mod expects.
- **Contract test:** keep the fixtures in one repo folder, for example `fixtures/bridge/*.json`, and run them in both the Swift tests and `claude plugin test`. The wire contract then has two readers that must agree.

**How it helps the planned work:**
- **Phase 1:**
  - It *is* Phase 1's seam. The server is written behind it, and the store never sees HTTP.
  - Correlating approvals to tool uses moves into the mod, which sees PreToolUse and PermissionRequest itself. The app only sees `ApprovalID`.
  - Claude Code's hook input carries `transcript_path`, which the Python script dropped. If the mod forwards it as `SessionInfo.transcriptURL`, the five copies of session-path derivation in the app can go (see #3). This matters for Desktop Code tab sessions.
- **Phase 2:** reply text replaces the tmux send path, so `ChatView`'s input bar (gated on `isInTmux && tty != nil`, `ChatView.swift:357`) gets a working channel again.
- **Optional migration path inside the Phase 1 PR:** land #1 and this port first with a `LegacyHookSocketBridge` adapter around today's server, without changing behaviour. Then swap in the new adapter.

---

## 3. Transcript fold and tail

**Files:**
- `Services/Session/ConversationParser.swift`
- `Services/Chat/ChatHistoryManager.swift`
- `Services/Session/JSONLInterruptWatcher.swift`
- `Services/State/SessionStore.swift:554-1045`
- `Models/SessionEvent.swift`: `fileUpdated`, `loadHistory`, `historyLoaded`, `clearDetected`, `interruptDetected`, `toolCompleted`, `FileUpdatePayload` and `ToolCompletionResult`
- `UI/Views/ChatView.swift:37-120`

**Problem.** What one JSONL line means is split across three modules:

- a stateful actor whose getters only work after a parse (`completedToolIds`, `toolResults` and `structuredResults`, `ConversationParser.swift:480-492`);
- three near-copy merge loops in `SessionStore` (`:596-636`, `:637-680`, `:978-995`);
- a separate watcher with its own file cursor.

Chat history is held in three places: `SessionState.chatItems`, `ChatHistoryManager.histories`, and `ChatView`'s `@State`. "Has the JSONL been read?" is guessed by flags that recent commits (`7bb535c`, `4a22466`) keep patching. `ChatView.swift:37-41` still uses the old "non-empty means loaded" rule and returns early at `:96`.

**Bugs this review verified:**
- **Full-history replay:** when the file hasn't grown, `parseNewLines` returns *all* messages as new (`ConversationParser.swift:390-391`). Every 3 s recheck and every hook re-merges the whole history.
- **Lost torn lines:** the offset jumps to the file size even when the last line is only half written (`:475`). That line fails to decode and is gone for good.
- **Wrong usage figure:** usage is summed over every assistant line (`:145-160`), and Claude Code repeats usage on each content-block line. `totalTokens` is input plus output and ignores cache. That is the "buggy token count".

**Duplication:**
- Session-path derivation exists in five copies.
- The command-message filter exists in four copies.
- Tool-input flattening exists in five copies.
- The result-text priority (stdout, then stderr, then content) exists in two copies.

**Solution.** Replace this with two modules:

- **One pure fold.** It turns lines into chat items, conversation info, context usage, and a delta (cleared, interrupted, completed tools).
- **One tail adapter.** Its cursor buffers partial lines and resets when the file is truncated.

`SessionStore` keeps a `(Transcript, TranscriptCursor)` pair per session, and `refreshTranscript` is the only load path. The following all disappear:

- `ChatHistoryManager`, `InterruptWatcherManager` and `JSONLInterruptWatcher`;
- six event cases;
- `needsClearReconciliation`;
- the "loaded" flags. Loaded becomes `cursor != .start`.

**Proposed interface:**

```swift
struct Transcript: Equatable, Sendable {
    static let empty: Transcript
    private(set) var items: [ChatHistoryItem]     // merged, stable ids, deduped
    private(set) var info: ConversationInfo       // title, last message
    private(set) var context: ContextUsage?       // latest main-chain assistant usage
    var visibleItems: [ChatHistoryItem] { get }   // subagent inner tools filtered out

    /// Pure fold. Subagent files fold with the same type.
    mutating func apply<Lines: Sequence>(_ lines: Lines) -> TranscriptDelta where Lines.Element == Substring
}

struct TranscriptDelta: Equatable, Sendable {
    var cleared: Bool
    var interrupted: Bool
    var completedToolIds: Set<String>
}

struct ContextUsage: Equatable, Sendable {
    let usedTokens: Int      // input + cache_read + cache_creation of the last non-sidechain assistant line
    let windowTokens: Int    // from message.model (not extracted today)
    var fraction: Double { Double(usedTokens) / Double(windowTokens) }
}

struct TranscriptTail: Sendable {         // local-substitutable adapter
    init(root: URL)                       // injected, not the ClaudePaths global
    func read(_ url: URL, from cursor: TranscriptCursor) throws -> (lines: [Substring], next: TranscriptCursor)
}

struct TranscriptCursor: Equatable, Sendable {
    static let start: TranscriptCursor
    var offset: UInt64
    var partial: Data     // an unterminated last line, kept for the next read
}
```

The fold hides:

- JSON decoding;
- the meta and command filter;
- interrupt markers;
- the `/clear` reset;
- joining each `tool_use` to its `tool_result`;
- the 14 structured result decoders (they stay; they earn their keep);
- the result-text priority;
- the item id scheme;
- usage.

**Dependency category:**
- **`Transcript`:** in-process.
- **`TranscriptTail`:** local-substitutable. Tests point it at a temp directory.

**Tests through the interface.** Real JSONL fixtures in, items and deltas out:
- a `tool_use` whose `tool_result` arrives in the next chunk;
- `/clear` in the middle of the file;
- an interrupt;
- an image block;
- an MCP result;
- three lines repeating the same usage, which must give the last value, not the sum;
- for the tail: half a line gives 0 lines, appending the rest gives 1, and truncating resets the cursor.

**How it helps the planned work:**
- **Phase 2:** the context % comes from `session.transcript.context`, with no new plumbing through `ConversationInfo`.
- **Chat history stays:** it is held in one copy, not three.
- **Phase 1:** with `transcriptURL` from the bridge, path guessing stops being a correctness risk for Desktop sessions.
- **Performance:** the replay and the three passes over the full file per update go away.

---

## 4. Notch controller: commands, selection, key bindings, risk

**Files:**
- `Core/NotchViewModel.swift`
- `Events/EventMonitors.swift` and `Events/EventMonitor.swift`
- `UI/Views/ClaudeInstancesView.swift:43-117`
- `UI/Views/ChatView.swift` (approval bar)
- `Services/Session/ClaudeSessionMonitor.swift:87-122`
- `UI/Window/NotchWindowController.swift:75-78`

**Problem.** Nothing exists where an intent like "approve the selected session" can enter:

- **`NotchViewModel` is shallow.** Its navigation methods are setters with a guard. Its one real behaviour is hover and click-outside handling, hard-wired to `EventMonitors.shared`, `NSEvent.mouseLocation` and `CGEvent`.
- **Row order is private to a view** (`ClaudeInstancesView.swift:43-66`).
- **Selection does not exist.**
- **Actions are closures built in view bodies.**
- **Approve and deny take a session id** and act on whatever is "active".
- **There is no key handling anywhere.**
- **`pendingInstances` mixes approvals with ready-for-input,** because `needsAttention` covers both (`SessionPhase.swift:154-160`).

**Solution.** One MainActor controller owns:

- the route;
- the visible rows (from #6);
- the selection;
- execution of `NotchCommand`s against the session pipeline.

Mouse and keyboard send the same commands. Key mapping and double-tap detection are pure values. The safe/danger classifier is a pure leaf that the controller consults for Shift+Enter.

**Proposed interface:**

```swift
enum NotchCommand: Equatable {
    case toggleOpen, close, select(index: Int), openChat
    case approve, approveSafeBatch, deny(note: String?)
}

@MainActor final class NotchController: ObservableObject {
    @Published private(set) var state: NotchState   // status, route, rows, selectedId
    init(sessions: some Publisher<[SessionState], Never>, actions: SessionActions)
    func send(_ command: NotchCommand)
}

protocol SessionActions {   // the port to the pipeline (#1/#2)
    func answer(_ id: ApprovalID, _ decision: ApprovalDecision)
    func submit(_ text: String, to session: SessionID)
}

enum KeyBindings {          // pure
    static func command(for key: KeyPress, in context: InputContext) -> NotchCommand?
}

struct DoubleTapDetector {  // pure: a Control down/up pair twice inside the interval
    mutating func register(_ flags: ModifierFlags, at time: TimeInterval) -> Bool
}

enum ToolRisk {             // pure leaf: the safe/danger classifier
    static func classify(tool: String, input: JSONValue) -> Risk   // .safe | .danger
}
```

**Dependency category:** in-process. `SessionActions` is the one port. In production the store and bridge implement it; in tests a recorder does.

**Tests:**
- Three rows, then `send(.select(2))`, then `send(.approve)`: the recorder gets row 2's first approval.
- Shift+Return in the list context maps to `.approveSafeBatch`, and the recorder gets exactly the approvals `ToolRisk` calls safe.
- A digit while the text field is focused maps to `nil`.
- `ToolRisk` is a table test of tool and input pairs:
  - `Read` is safe;
  - `Bash rm -rf` is danger;
  - an MCP write is danger.

**How it helps the planned work:** it is where Phase 2's entire key map lands:
- double-tap Control;
- 1-9;
- Enter, Shift+Enter, D, Shift+D;
- Esc.

**Constraints to settle in grilling:**
- Local key monitors only receive keys while the panel is key, and the panel is deliberately not made key on notification opens (`NotchWindowController.swift:75-78`). Those opens are exactly when Enter and D matter.
- A global `flagsChanged` monitor for double-tap Control needs Input Monitoring permission.

---

## 5. Attention policy behind a focus probe

**Files:**
- `UI/Views/NotchView.swift:381-509`
- `Utilities/TerminalVisibilityDetector.swift`
- `Core/NotchActivityCoordinator.swift`
- `Services/Shared/ProcessTreeBuilder.swift`
- `Services/Shared/TerminalAppRegistry.swift`

**Problem.** The decisions to auto-open, bounce, play a sound and show the checkmark are `@State` inside the `NotchView` struct, with three different focus rules:

| Decision | Focus rule |
|---|---|
| Auto-open (`:425-436`) | any terminal on the current Space |
| Sound (`:495-509`) | this session is focused |
| Bounce (`:475-487`) | none |

The focus check is an async static function that calls `NSWorkspace`, `ps` and (today) tmux. `NotchActivityCoordinator` is a one-case pass-through, and its `activityDuration` is always 0.

**Solution.** A pure policy turns two snapshots of the session list plus a focus snapshot into attention cues. A `FocusProbe` port produces the focus snapshot. `NotchActivityCoordinator` is deleted.

**Proposed interface:**

```swift
struct FocusSnapshot: Equatable { var frontmostAppPid: Int?; var focusedSessions: Set<SessionID> }

protocol FocusProbe { func snapshot(for sessions: [SessionInfo]) async -> FocusSnapshot }

enum AttentionCue: Equatable { case autoOpen, bounce, playSound, showReadyCheck(until: Date) }

enum AttentionPolicy {   // pure
    static func cues(previous: [SessionState], current: [SessionState],
                     focus: FocusSnapshot, notch: NotchStatus, now: Date) -> [AttentionCue]
}
```

**Dependency category:** ports & adapters.
- **Production probe:** wraps `NSWorkspace` and `ProcessTreeBuilder`.
- **Test probe:** a fixed snapshot.

**Tests:**
- `processing` to `waitingForInput` with the session focused gives `[]`.
- The same transition unfocused gives `[.bounce, .playSound]`.
- An approval arriving while the notch is closed gives `[.autoOpen]`.

**How it helps the planned work.** The Phase 2 focus-aware bounce becomes a single rule change in one module. **Open question:** for Desktop Code tab sessions, "focused" can't be read from a terminal PID. Either the mod reports focus or the probe decides per surface. That is why this card is rated "worth exploring" rather than "strong".

---

## 6. Row and header projection

**Files:**
- `UI/Views/ClaudeInstancesView.swift:43-66` and `:121-356` (`InstanceRow`)
- `UI/Views/NotchView.swift:246-346` (opened header)
- `Services/Session/ConversationParser.swift:13-33` (`UsageInfo.formattedTotal`)
- `Models/SessionState.swift:117-190`

**Problem.** What a row shows, and in what order, is computed inside view bodies. `InstanceRow` is one body with five closures. Every new row element would mean editing that body:

- the context % (it replaces `:180-185`);
- agents;
- tests.

Usage formatting lives in the parser file. The 1-9 order (#4) and the on-screen order must agree, and today only the view knows the order.

**Solution.** A pure projection turns session states into row models, and plan usage into a header model. A new row element is one enum case plus one renderer.

**Proposed interface:**

```swift
struct SessionRow: Identifiable, Equatable {
    let id: SessionID
    let shortcut: Int?            // 1-9, matches the visible order
    let title: String
    let status: RowStatus
    let subtitle: String?
    let badges: [RowBadge]
    let approval: ApprovalSummary?
}

enum RowBadge: Equatable { case context(ContextUsage), agents(running: Int), tests(TestSummary) }

struct UsageMeter: Equatable { let fraction: Double; let resetsAt: Date?; let label: String }
struct HeaderModel: Equatable { let fiveHour: UsageMeter?; let weekly: UsageMeter? }

enum NotchProjection {   // pure
    static func rows(_ sessions: [SessionState], now: Date) -> [SessionRow]
    static func header(_ usage: PlanUsage?, now: Date) -> HeaderModel
}
```

**Dependency category:** in-process.

**Tests:**
- Fixture sessions produce the expected order, with shortcuts only on the first nine rows.
- A context badge of 0.42 comes from a transcript fixture.
- `UsageMeter.label` gives something like "42% · resets in 3h". This is the planned "usage formatting" test.

**How it helps the planned work:**
- **Phase 2:** the meters and the context % are each a field.
- **Phase 3:** agents and tests are two `RowBadge` cases.
- **One order:** `NotchController.state.rows` (#4) is this projection, so the keyboard and the screen share one order.

---

## 7. Measured panel layout

**Files:**
- `Core/NotchViewModel.swift:66-91`
- `Core/ScreenSelector.swift:100-104`, `Core/SoundSelector.swift:22-37`, `Core/ClaudeDirSelector.swift`, `UI/Components/SoundPickerRow.swift:82`
- `Core/NotchGeometry.swift:28-43`
- `UI/Window/NotchViewController.swift:52-75`
- `UI/Views/NotchView.swift:59-168`
- `UI/Window/NotchWindowController.swift:24`

**Problem.** The opened size is a hand-kept table:

| Panel | Size |
|---|---|
| Instances | 480 × 320 |
| Chat | `min(screenW*0.5, 600)` × 580 |
| Menu | 540 + one term per expanding picker |

Every expanding picker needs a singleton whose only job is to export its height. `ClaudeDirSelector` is exactly that, and the picker views repeat the same row-height arithmetic.

The commits show the pattern:
- `72b41b1` bumped 420 to 540.
- `27a7ac5` added the `ClaudeDirSelector` singleton.
- `effabeb` hid the resulting overflow behind a `ScrollView`.

One panel rectangle is computed three ways, each with its own fudge:

| Use | Location | Fudge |
|---|---|---|
| Hit-test | `NotchGeometry.swift:30-31` | `-6/-30`, "tuned to match visual output" |
| Click-through | `NotchViewController.swift:55` | `+52` |
| Render | `NotchView.swift` | padding of 19 and 12 |

The window's fixed height of 750 (`NotchWindowController.swift:24`) can be exceeded by the menu with every picker expanded.

**Solution.** Content reports its own height through a `PreferenceKey`. One pure module turns the route, the measured height, the notch and the screen into the single rect used for render, hit-test and click-through, clamped to the window. The selector height singletons go away.

**Proposed interface:**

```swift
enum PanelLayout {   // pure
    static func openedRect(route: Route, contentHeight: CGFloat, notch: CGRect, screen: CGRect) -> CGRect
    static func closedHitRect(notch: CGRect) -> CGRect
}
```

**Dependency category:** in-process.

**Tests:**
- For every route, the opened rect stays within the window height.
- The render rect equals the hit-test rect.
- The menu with every picker expanded is clamped and scrolls.

**How it helps the planned work.** The Phase 2 meters and Phase 3 rows add height without anyone editing a constant somewhere else. **Risk:** measured sizing combined with spring animations can jitter in an `NSWindow`-hosted SwiftUI view. Prototype it before committing to it.

---

## 8. Status feeds over the bridge

**Problem (not yet real):** Phase 3 adds two external sources: the aban-statusline skills/agents state and test-pane's latest view. Plan usage for the meters may be a third. Each is "outside state that turns into a small piece of notch state".

**Recommendation:** don't add a seam yet.

- **If the mod can see a source:** deliver it as new `BridgeEvent` cases (`.planUsage`, `.agents`, `.testRun`). That needs no new seam: #2's two adapters already cover it.
- **If a source must be file-watched in the app:** feed `NotchProjection` (#6) from an `AsyncStream<Value>` per source.
- **Trigger for a shared protocol:** only if a second file-watched source shows up.

---

## Where the Swift test target attaches

- **The build setting.** The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. That is why the model files are full of `nonisolated`, and why any pure type in the app target needs that noise before an actor or a test can call it.
- **Recommendation: a local Swift package.** Name it something like `VibeNotchCore`, with no AppKit or SwiftUI import. It holds the pure modules:
  - `Sessions` (#1);
  - `BridgeWire` and `JSONValue` (#2);
  - `Transcript` and `ContextUsage` (#3);
  - `ToolRisk`, `KeyBindings` and `DoubleTapDetector` (#4);
  - `AttentionPolicy` (#5);
  - `NotchProjection` (#6);
  - `PanelLayout` (#7).
- **What the package gives:**
  - It is nonisolated by default.
  - It uses Swift Testing, and `swift test` runs it in seconds without a host app.
  - The app target depends on it.
  - The package seam also keeps those modules pure: they can't reach `NSWorkspace` by accident.
- **The planned tests and where they land:**

| Planned test | Lands in |
|---|---|
| Safe/danger classifier | `ToolRisk.classify` (#4) |
| Bridge-message decoding | `BridgeWire.decode` (#2), plus fixtures shared with `claude plugin test` |
| Usage formatting | `NotchProjection.header` / `UsageMeter.label` (#6) |
| Highest value, not yet planned | reducer event sequences (#1) and transcript fixtures (#3) |

## Phase 0 facts found along the way

These are not deepening candidates, but they change what Phase 0 can delete.

- **`ToolApprovalHandler` is not dead.** `ChatView.swift:486` uses it to send messages through tmux. It goes with tmux. The chat input bar is disabled until the bridge's `submitPrompt` exists.
- **`AnyCodable` lives inside `HookSocketServer.swift:560-615`.** `PermissionContext` uses it (`SessionPhase.swift:15`), so move it, or replace it with `JSONValue`, before that file is deleted.
- **`SessionState.pid` is still needed**, by:
  - `stableId`, used for SwiftUI identity;
  - the liveness sweep;
  - the focus check for the notification sound.

  The mod should send Claude's PID, and liveness moves to the heartbeat.
- **Fields and files with no remaining use:**
  - `SessionState.tty` and `SessionState.isInTmux`.
  - `WindowFinder`, `WindowFocuser` and `SessionPhaseHelpers.swift`.
  - In `ClaudePaths`: `hooksDir`, `settingsFile`, `hookScriptShellPath` and `shellQuote`.
- **`ProcessTreeBuilder` declares `struct ProcessInfo`,** which shadows Foundation's. That is why `AppDelegate:51` and `ClaudePaths:86` write `Foundation.ProcessInfo`. Rename it while you're there.
- **Already dead in `ConversationParser`:**
  - `resetState`, `checkAndConsumeClearDetected` and `parseSubagentToolsSync`;
  - `IncrementalParseResult.allMessages`;
  - `ToolTracker.lastSyncOffset`.
- **Already dead elsewhere:**
  - `ChatHistoryManager.syncFromFile` and `clearHistory`;
  - `ClaudeSessionMonitor.loadHistory`;
  - in `NotchViewModel`: `notchPop`/`notchUnpop`, `spacing`, `animation`, `windowHeight` and `screenRect`.

## Suggested order

1. **Phase 0:** delete as planned, plus the facts above. Move `AnyCodable` first.
2. **Phase 1:** #1, the reducer, then #2, the bridge port, in that order inside the PR, optionally via the legacy adapter. Then #3, the transcript fold, because the bridge's `transcriptURL` makes it cleaner.
3. **Phase 2:** #6, the projection, then #4, the controller, then #5, the attention policy. Do #7, the layout, when the header meters first need height.
4. **Phase 3:** #8 decides itself once you know what the mod can see.
