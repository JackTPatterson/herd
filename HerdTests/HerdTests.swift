import XCTest

final class HerdrModelTests: XCTestCase {
    func testDecodesLiveSnapshotShape() throws {
        // Captured from `herdr api snapshot` (herdr 0.9.1).
        let json = """
        {"id":"x","result":{"snapshot":{"agents":[{"agent":"claude","agent_status":"working","pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1","focused":false,"revision":3}],
        "focused_pane_id":"w1:p1","focused_tab_id":"w1:t1","focused_workspace_id":"w1",
        "panes":[{"agent_status":"unknown","cwd":"/tmp/app","focused":true,"foreground_cwd":"/tmp/app/src","pane_id":"w1:p1","revision":0,"tab_id":"w1:t1","workspace_id":"w1"}],
        "protocol":22,"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"},
        {"agent_status":"working","focused":false,"label":"Explore: tests","number":2,"pane_count":1,"tab_id":"w1:t2","workspace_id":"w1"}],
        "version":"0.9.1","workspaces":[{"active_tab_id":"w1:t1","agent_status":"working","focused":true,"label":"app","number":1,"pane_count":2,"tab_count":2,"workspace_id":"w1","future_field":1}]},"type":"session_snapshot"}}
        """
        let result = try HerdrClient.parseResponse(Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: result["snapshot"]!)
        let snapshot = try JSONDecoder().decode(HerdrSnapshot.self, from: data)

        XCTAssertEqual(snapshot.workspaces.first?.label, "app")
        XCTAssertEqual(snapshot.tabs(inWorkspace: "w1").map(\.label), ["1", "Explore: tests"])
        XCTAssertEqual(snapshot.agents(inTab: "w1:t2").first?.agentStatus, .working)
        XCTAssertEqual(snapshot.directory(ofWorkspace: "w1"), "/tmp/app/src")
    }

    func testDecodesCapturedFixture() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "snapshot", withExtension: "json"))
        let result = try HerdrClient.parseResponse(try Data(contentsOf: url).split(separator: 0x0A).first.map { Data($0) } ?? Data())
        let data = try JSONSerialization.data(withJSONObject: result["snapshot"]!)
        XCTAssertNoThrow(try JSONDecoder().decode(HerdrSnapshot.self, from: data))
    }

    func testUnknownAgentStatusDecodesAsUnknown() throws {
        let data = Data(#"["sleeping"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([HerdrAgentStatus].self, from: data), [.unknown])
    }

    func testServerErrorsThrow() {
        let line = Data(#"{"id":"1","error":{"code":"not_found","message":"pane not found"}}"#.utf8)
        XCTAssertThrowsError(try HerdrClient.parseResponse(line))
    }

    func testSessionSocketPath() {
        XCTAssertEqual(HerdrClient.socketPath(session: "herd", home: "/Users/me"), "/Users/me/.config/herdr/sessions/herd/herdr.sock")
        XCTAssertEqual(HerdrClient.socketPath(session: nil, home: "/Users/me"), "/Users/me/.config/herdr/herdr.sock")
    }
}

final class ProjectGroupingTests: XCTestCase {
    private func workspace(_ id: String, _ number: Int, _ label: String) -> HerdrWorkspace {
        HerdrWorkspace(
            workspaceId: id, number: number, label: label, focused: false, paneCount: 1, tabCount: 1,
            activeTabId: "\(id):t1", agentStatus: .idle, worktree: nil
        )
    }

    private func pane(_ workspaceId: String, cwd: String) -> HerdrPane {
        HerdrPane(
            paneId: "\(workspaceId):p1", tabId: "\(workspaceId):t1", workspaceId: workspaceId, focused: false,
            cwd: cwd, foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil
        )
    }

    func testGroupsByProjectRootInWorkspaceOrder() {
        let snapshot = HerdrSnapshot(
            workspaces: [workspace("w1", 1, "api"), workspace("w2", 2, "notes"), workspace("w3", 3, "api tests")],
            tabs: [], panes: [pane("w1", cwd: "/r/api/src"), pane("w2", cwd: "/tmp"), pane("w3", cwd: "/r/api")],
            agents: [], focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
        )
        let groups = ProjectGrouping.groups(snapshot: snapshot) { $0.hasPrefix("/r/api") ? "/r/api" : nil }
        XCTAssertEqual(groups.map(\.name), ["api", "Other"])
        XCTAssertEqual(groups.first?.workspaces.map(\.workspaceId), ["w1", "w3"])
    }

    func testProjectRootResolverParentFallback() {
        let root = ProjectRootResolver.projectRoot(
            forDirectory: "/Users/me/Developer/notes/drafts",
            projectParentDirectories: ["~/Developer"],
            homeDirectory: "/Users/me",
            gitEntryKind: { _ in nil },
            readFile: { _ in nil }
        )
        XCTAssertEqual(root, "/Users/me/Developer/notes")
    }

    func testGitBranchFromHead() {
        XCTAssertEqual(GitBranch.branch(fromHead: "ref: refs/heads/feat/tabs\n"), "feat/tabs")
        XCTAssertEqual(GitBranch.branch(fromHead: "0123456789abcdef"), "0123456")
        XCTAssertNil(GitBranch.branch(fromHead: ""))
    }
}

final class AgentBrandTests: XCTestCase {
    func testKnownVendors() {
        XCTAssertEqual(AgentBrand.forAgent("claude")?.hueHex, "#d97757")
        XCTAssertEqual(AgentBrand.forAgent("claude_code")?.displayName, "Claude Code")
        XCTAssertEqual(AgentBrand.forAgent("codex")?.hueHex, nil, "Codex signs in black")
        XCTAssertEqual(AgentBrand.forAgent("codex")?.logoAssetName, "agent-codex")
        XCTAssertEqual(AgentBrand.forAgent("antigravity")?.id, "agy")
    }

    func testUnknownVendorGetsOtherHue() {
        XCTAssertEqual(AgentBrand.forAgent("my-bot")?.hueHex, "#c78a1f")
        XCTAssertNil(AgentBrand.forAgent(nil))
        XCTAssertNil(AgentBrand.forAgent("  "))
    }
}

final class SubagentTabTests: XCTestCase {
    private let payload: [String: Any] = [
        "tool_name": "Agent",
        "tool_use_id": "toolu_1",
        "transcript_path": "/Users/me/.claude/projects/p/abc.jsonl",
        "cwd": "/Users/me/app",
        "tool_input": ["subagent_type": "Explore", "description": "Map the socket API", "prompt": "…"],
    ]

    func testBuildsNamedTabRunningViewer() throws {
        let request = try XCTUnwrap(SubagentHook.tabRequest(
            payload: payload,
            environment: ["HERDR_WORKSPACE_ID": "w2"],
            cliPath: "/Apps/Herd.app/Contents/MacOS/herd-cli",
            now: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertEqual(request["workspace_id"] as? String, "w2")
        XCTAssertEqual(request["tab_label"] as? String, "Explore: Map the socket API")
        XCTAssertEqual(request["focus"] as? Bool, false)
        let root = try XCTUnwrap(request["root"] as? [String: Any])
        let command = try XCTUnwrap(root["command"] as? [String])
        XCTAssertEqual(Array(command.prefix(2)), ["/Apps/Herd.app/Contents/MacOS/herd-cli", "agent-watch"])
        XCTAssertTrue(command.contains("/Users/me/.claude/projects/p/abc/subagents"))
        XCTAssertTrue(command.contains("toolu_1"))
        XCTAssertEqual(root["cwd"] as? String, "/Users/me/app")
    }

    func testIgnoresOtherToolsAndNonHerdrPanes() {
        var bash = payload
        bash["tool_name"] = "Bash"
        XCTAssertNil(SubagentHook.tabRequest(payload: bash, environment: ["HERDR_WORKSPACE_ID": "w1"], cliPath: "x"))
        XCTAssertNil(SubagentHook.tabRequest(payload: payload, environment: [:], cliPath: "x"))
    }

    func testLongLabelsTruncate() {
        let label = SubagentHook.tabLabel(agentType: "general-purpose", description: String(repeating: "x", count: 80))
        XCTAssertEqual(label.count, SubagentHook.maxLabelLength)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testHookInstallerIsIdempotentAndPreservesOtherHooks() throws {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "guard.sh"]]]]],
        ]
        let once = ClaudeHookInstaller.installing(into: existing, cliPath: "/A/herd-cli")
        let twice = ClaudeHookInstaller.installing(into: once, cliPath: "/B/herd-cli")
        let entries = try XCTUnwrap((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 2)
        let commands = entries.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        XCTAssertEqual(commands, ["guard.sh", "'/B/herd-cli' hook claude"])
        XCTAssertEqual(twice["model"] as? String, "opus")

        let removed = ClaudeHookInstaller.removing(from: twice)
        let remaining = (removed["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]
        XCTAssertEqual(remaining?.count, 1)
    }
}

final class SubagentTranscriptTests: XCTestCase {
    func testToolSummaryAndTruncation() {
        XCTAssertEqual(SubagentTranscriptRenderer.toolSummary(["command": "ls -la\nwc"]), "ls -la wc")
        XCTAssertEqual(SubagentTranscriptRenderer.truncate("abcdef", 4), "abc…")
    }

    func testLocatorMatchesToolUseId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herd-subagents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"toolUseId":"toolu_9","description":"d"}"#.utf8).write(to: dir.appendingPathComponent("agent-a1.meta.json"))
        try Data().write(to: dir.appendingPathComponent("agent-a1.jsonl"))

        let found = SubagentTranscriptLocator(directory: dir.path, toolUseId: "toolu_9", description: nil, since: 0).find()
        XCTAssertEqual(found?.lastPathComponent, "agent-a1.jsonl")
        XCTAssertNil(SubagentTranscriptLocator(directory: dir.path, toolUseId: "other", description: nil, since: 0).find())
    }

    func testFinishedCallbackFiresOnceOnTextEndTurn() {
        let renderer = SubagentTranscriptRenderer()
        var finishedCount = 0
        renderer.onFinished = { finishedCount += 1 }
        let thinking = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"…"}]}}"#
        let text = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"4"}]}}"#
        renderer.render(line: Data(thinking.utf8))
        XCTAssertEqual(finishedCount, 0)
        renderer.render(line: Data(text.utf8))
        XCTAssertEqual(finishedCount, 1)
    }
}

final class FuzzyMatcherTests: XCTestCase {
    func testSubsequenceRequired() {
        XCTAssertNotNil(FuzzyMatcher.match("ntab", in: "New Tab"))
        XCTAssertNil(FuzzyMatcher.match("tabn", in: "New Tab"))
        XCTAssertEqual(FuzzyMatcher.match("", in: "anything")?.score, 0)
    }

    func testWordStartsAndPrefixesOutrankScatteredMatches() throws {
        let wordStarts = try XCTUnwrap(FuzzyMatcher.match("st", in: "Split Tab"))
        let scattered = try XCTUnwrap(FuzzyMatcher.match("st", in: "Last"))
        XCTAssertGreaterThan(wordStarts.score, scattered.score)
        let prefix = try XCTUnwrap(FuzzyMatcher.match("new", in: "New Workspace"))
        let inner = try XCTUnwrap(FuzzyMatcher.match("new", in: "Rename Workspace"))
        XCTAssertGreaterThan(prefix.score, inner.score)
    }

    func testIndicesPointAtMatchedCharacters() throws {
        let match = try XCTUnwrap(FuzzyMatcher.match("nt", in: "New Tab"))
        XCTAssertEqual(match.indices, [0, 4])
    }
}

final class PaletteRankingTests: XCTestCase {
    private let entries = [
        PaletteSearchable(id: "action.newTab", kind: .action, title: "New Tab", subtitle: "", keywords: ["create"]),
        PaletteSearchable(id: "action.closeTab", kind: .action, title: "Close Tab", subtitle: "", keywords: []),
        PaletteSearchable(id: "workspace.w1", kind: .workspace, title: "cmux", subtitle: "feat/tabs", keywords: []),
        PaletteSearchable(id: "tab.w1:t2", kind: .tab, title: "Explore: map api", subtitle: "cmux", keywords: []),
        PaletteSearchable(id: "agent.w1:p2", kind: .agent, title: "Claude Code", subtitle: "working", keywords: ["claude"]),
    ]

    func testPrefixFilters() {
        XCTAssertEqual(PaletteKind.parse(">new").filter, .action)
        XCTAssertEqual(PaletteKind.parse(">new").query, "new")
        let tabs = PaletteRanking.rank(entries, query: "#", filter: nil, recentIds: [])
        XCTAssertEqual(tabs.map(\.id), ["tab.w1:t2"])
    }

    func testQueryRanksBestMatchFirstAndMatchesSubtitles() {
        XCTAssertEqual(PaletteRanking.rank(entries, query: "new tab", filter: nil, recentIds: []).first?.id, "action.newTab")
        XCTAssertTrue(PaletteRanking.rank(entries, query: "feat", filter: nil, recentIds: []).map(\.id).contains("workspace.w1"))
    }

    func testZeroStateShowsRecentsFirstThenKindOrder() {
        let ranked = PaletteRanking.rank(entries, query: "", filter: nil, recentIds: ["action.closeTab"]).map(\.id)
        XCTAssertEqual(ranked.first, "action.closeTab")
        XCTAssertEqual(ranked[1], "workspace.w1")
        XCTAssertEqual(ranked.last, "action.newTab")
    }

    func testChipFilterAndRecencyRecording() {
        XCTAssertEqual(PaletteRanking.rank(entries, query: "", filter: .agent, recentIds: []).map(\.id), ["agent.w1:p2"])
        XCTAssertEqual(PaletteRanking.recording("b", in: ["a", "b", "c"]), ["b", "a", "c"])
    }
}

final class HerdrPluginTests: XCTestCase {
    func testDecodesPluginListAndLogs() throws {
        // Shape captured from herdr 0.9.1 `plugin.list` / `plugin.log.list`.
        let plugins = """
        [{"plugin_id":"herd.sample","name":"Herd Sample","version":"0.1.0","enabled":true,"platforms":["macos"],
          "actions":[{"id":"stamp","title":"Write a timestamp file","contexts":["global"],"command":["/bin/sh"]}],
          "panes":[{"id":"clock","title":"Clock","placement":"overlay","command":["/bin/sh"]}],
          "source":{"kind":"local"}}]
        """
        let decoded = try JSONDecoder().decode([HerdrPlugin].self, from: Data(plugins.utf8))
        XCTAssertEqual(decoded.first?.actions.first?.id, "stamp")
        XCTAssertEqual(decoded.first?.panes.first?.placement, "overlay")
        XCTAssertEqual(decoded.first?.isGitHubInstall, false)

        let logs = """
        [{"log_id":"plugin-log-1","plugin_id":"herd.sample","action_id":"stamp","status":"succeeded",
          "started_unix_ms":1789663888058,"exit_code":0,"stdout":"","stderr":"","command":["/bin/sh"]}]
        """
        XCTAssertEqual(try JSONDecoder().decode([HerdrPluginLog].self, from: Data(logs.utf8)).first?.exitCode, 0)
    }

    func testPluginPrefix() {
        XCTAssertEqual(PaletteKind.parse("!stamp").filter, .plugin)
    }
}

final class WorkspaceActivityTests: XCTestCase {
    private func workspace(_ id: String, status: HerdrAgentStatus = .idle) -> HerdrWorkspace {
        HerdrWorkspace(workspaceId: id, number: 1, label: id, focused: false, paneCount: 1, tabCount: 1,
                       activeTabId: "\(id):t1", agentStatus: status, worktree: nil)
    }

    private func snapshot(_ workspaces: [HerdrWorkspace], agents: [HerdrAgent] = [], focused: String? = nil) -> HerdrSnapshot {
        HerdrSnapshot(workspaces: workspaces, tabs: [], panes: [], agents: agents,
                      focusedWorkspaceId: focused, focusedTabId: nil, focusedPaneId: nil)
    }

    private func agent(_ workspaceId: String, _ status: HerdrAgentStatus, seq: Int) -> HerdrAgent {
        HerdrAgent(paneId: "\(workspaceId):p1", tabId: "\(workspaceId):t1", workspaceId: workspaceId, agent: "claude",
                   name: nil, displayAgent: nil, agentStatus: status, stateChangeSeq: seq)
    }

    func testIdleAfterThresholdAndRecoveryStamp() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var activity = WorkspaceActivity()
        let snap = snapshot([workspace("w1"), workspace("w2")], focused: "w1")
        activity.observe(snap, viewedWorkspaceId: "w1", now: t0) { $0.workspaceId == "w2" ? t0.addingTimeInterval(-10_000) : nil }

        let later = t0.addingTimeInterval(3 * 3600)
        let split = activity.partition(snap.workspaces, snapshot: snap, pinned: [], idleAfter: 2 * 3600, now: later)
        XCTAssertEqual(split.active.map(\.workspaceId), ["w1"], "focused stays active")
        XCTAssertEqual(split.idle.map(\.workspaceId), ["w2"])
    }

    func testAgentChangesRefreshAndBusyAgentsNeverIdle() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var activity = WorkspaceActivity()
        let ws = [workspace("w1")]
        activity.observe(snapshot(ws, agents: [agent("w1", .idle, seq: 1)]), viewedWorkspaceId: nil, now: t0)
        let t1 = t0.addingTimeInterval(5 * 3600)
        let changed = snapshot(ws, agents: [agent("w1", .done, seq: 2)])
        activity.observe(changed, viewedWorkspaceId: nil, now: t1)
        XCTAssertEqual(activity.lastActive("w1"), t1)

        let working = snapshot(ws, agents: [agent("w1", .working, seq: 3)])
        XCTAssertFalse(activity.isIdle(ws[0], snapshot: working, pinned: [], idleAfter: 60, now: t1.addingTimeInterval(9999)))
        XCTAssertFalse(activity.isIdle(ws[0], snapshot: changed, pinned: ["w1"], idleAfter: 60, now: t1.addingTimeInterval(9999)))
        XCTAssertTrue(activity.isIdle(ws[0], snapshot: changed, pinned: [], idleAfter: 60, now: t1.addingTimeInterval(9999)))
    }

    func testClosedWorkspacesArePrunedAndAgeLabels() {
        var activity = WorkspaceActivity(stamps: ["gone": Date()])
        activity.observe(snapshot([workspace("w1")]), viewedWorkspaceId: nil)
        XCTAssertNil(activity.lastActive("gone"))
        let now = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertEqual(WorkspaceActivity.ageLabel(since: now.addingTimeInterval(-90 * 60), now: now), "1h")
        XCTAssertEqual(WorkspaceActivity.ageLabel(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }

    func testClaudeTranscriptRecovery() {
        XCTAssertEqual(ClaudeTranscriptActivity.projectDirectory(forCwd: "/Users/me/Developer/lab-vault", home: "/Users/me"),
                       "/Users/me/.claude/projects/-Users-me-Developer-lab-vault")
        let lines = """
        {"type":"user","timestamp":"2026-09-17T14:57:01.566Z"}
        {"type":"last-prompt"}
        """
        let date = ClaudeTranscriptActivity.lastTimestamp(inJSONLines: lines)
        XCTAssertEqual(date.map { Int($0.timeIntervalSince1970) }, 1789657021)
    }
}

final class AgentRecoveryTests: XCTestCase {
    private func snapshot(agents: [HerdrAgent], terminals: [String]) -> HerdrSnapshot {
        let panes = terminals.enumerated().map { index, terminal in
            HerdrPane(paneId: "w1:p\(index)", tabId: "w1:t1", workspaceId: "w1", focused: false, cwd: "/repo",
                      foregroundCwd: nil, agentStatus: .idle, terminalTitle: nil, terminalId: terminal)
        }
        return HerdrSnapshot(
            workspaces: [HerdrWorkspace(workspaceId: "w1", number: 1, label: "repo", focused: true, paneCount: 1,
                                        tabCount: 1, activeTabId: "w1:t1", agentStatus: .idle, worktree: nil)],
            tabs: [HerdrTab(tabId: "w1:t1", workspaceId: "w1", number: 1, label: "claude", focused: true, paneCount: 1, agentStatus: .idle)],
            panes: panes, agents: agents, focusedWorkspaceId: "w1", focusedTabId: "w1:t1", focusedPaneId: nil
        )
    }

    private func agent(_ kind: String, terminal: String, session: String? = nil) -> HerdrAgent {
        HerdrAgent(paneId: "w1:p0", tabId: "w1:t1", workspaceId: "w1", agent: kind, name: nil, displayAgent: nil,
                   agentStatus: .idle, cwd: "/repo", terminalId: terminal,
                   agentSession: session.map { HerdrAgent.SessionReference(source: nil, agent: kind, kind: "id", value: $0) })
    }

    func testSessionsRunningAtLastObservationAreLostAfterRestart() {
        let seenAt = Date(timeIntervalSince1970: 1_000)
        let before = snapshot(agents: [agent("claude", terminal: "term_a"), agent("codex", terminal: "term_b")],
                              terminals: ["term_a", "term_b"])
        var journal = AgentRecovery.record(before, into: [], now: seenAt) { agent, _ in agent.agent == "claude" ? "sess-1" : "cdx-2" }
        XCTAssertEqual(journal.first { $0.agent == "codex" }?.resumeCommand, "codex resume cdx-2")
        XCTAssertEqual(journal.first { $0.agent == "claude" }?.workspaceLabel, "repo")

        // Codex exited earlier while Herd watched: not offered.
        journal = AgentRecovery.record(snapshot(agents: [agent("claude", terminal: "term_a")], terminals: ["term_a", "term_b"]),
                                       into: journal, now: seenAt.addingTimeInterval(60)) { _, _ in nil }
        let after = snapshot(agents: [], terminals: ["term_new"])
        let lost = AgentRecovery.lostSessions(journal: journal, lastObserved: seenAt.addingTimeInterval(60), current: after)
        XCTAssertEqual(lost.map(\.agent), ["claude"])
        XCTAssertEqual(lost.first?.resumeCommand, "claude --resume sess-1")
        XCTAssertEqual(Set(AgentRecovery.history(journal: journal, current: after).map(\.agent)), ["claude", "codex"])
    }

    func testNativelyResumedAndHandledSessionsAreNotLost() {
        let now = Date()
        var journal = AgentRecovery.record(snapshot(agents: [agent("claude", terminal: "term_a")], terminals: ["term_a"]),
                                           into: [], now: now) { _, _ in "sess-1" }
        let resumed = snapshot(agents: [agent("claude", terminal: "term_z", session: "sess-1")], terminals: ["term_z"])
        XCTAssertTrue(AgentRecovery.lostSessions(journal: journal, lastObserved: now, current: resumed).isEmpty)

        journal[0].handled = true
        XCTAssertTrue(AgentRecovery.lostSessions(journal: journal, lastObserved: now,
                                                 current: snapshot(agents: [], terminals: ["x"])).isEmpty)
    }

    func testCodexSessionMetaParsingAndJournalRoundTrip() throws {
        let line = #"{"type":"session_meta","payload":{"id":"019e3e63-ed09","cwd":"/Users/me/app","timestamp":"x"}}"#
        XCTAssertEqual(AgentSessionFiles.parseCodexSessionMeta(firstLine: line)?.id, "019e3e63-ed09")
        XCTAssertNil(AgentSessionFiles.parseCodexSessionMeta(firstLine: #"{"type":"message"}"#))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/journal.json")
        let record = AgentSessionRecord(agent: "claude", sessionId: "it's", cwd: "/r", workspaceLabel: "r", tabLabel: "t",
                                        terminalId: "term", firstSeen: Date(timeIntervalSince1970: 5), lastSeen: Date(timeIntervalSince1970: 9))
        AgentSessionJournal(lastObserved: Date(timeIntervalSince1970: 9), records: [record]).save(to: url)
        XCTAssertEqual(AgentSessionJournal.load(from: url).records, [record])
        XCTAssertEqual(record.resumeCommand, "claude --resume 'it'\"'\"'s'")
    }

    func testResumeRequestRunsTheCommandInALoginShell() {
        let record = AgentSessionRecord(agent: "codex", sessionId: "abc", cwd: "/work/app", workspaceLabel: "app",
                                        tabLabel: "review", terminalId: "t", firstSeen: Date(), lastSeen: Date())
        let request = AgentRecovery.resumeRequest(record, shell: "/bin/zsh", workspaceId: "w2", tabId: nil)
        XCTAssertEqual(request["workspace_id"] as? String, "w2")
        XCTAssertEqual(request["tab_label"] as? String, "review")
        XCTAssertEqual(request["focus"] as? Bool, false)
        let pane = request["root"] as? [String: Any]
        XCTAssertEqual(pane?["cwd"] as? String, "/work/app")
        XCTAssertEqual(pane?["command"] as? [String], ["/bin/zsh", "-lic", "codex resume abc; exec /bin/zsh -l"])

        // A new workspace's empty first tab is filled instead of adding one.
        let intoTab = AgentRecovery.resumeRequest(record, shell: "/bin/zsh", workspaceId: "w3", tabId: "w3:t1")
        XCTAssertEqual(intoTab["tab_id"] as? String, "w3:t1")
        XCTAssertNil(intoTab["tab_label"])
    }

    func testClaudeSessionInferenceSkipsClaimedAndStaleTranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let dir = ClaudeTranscriptActivity.projectDirectory(forCwd: "/work/app", home: home)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let started = Date()
        for (name, age) in [("old", -3600.0), ("a", -5.0), ("b", -1.0)] {
            FileManager.default.createFile(atPath: "\(dir)/\(name).jsonl", contents: Data("{}\n".utf8),
                                           attributes: [.modificationDate: started.addingTimeInterval(age)])
        }
        XCTAssertEqual(AgentSessionFiles.claudeSession(cwd: "/work/app", since: started, home: home), "b")
        XCTAssertEqual(AgentSessionFiles.claudeSession(cwd: "/work/app", since: started, excluding: ["b"], home: home), "a")
        XCTAssertNil(AgentSessionFiles.claudeSession(cwd: "/work/app", since: started, excluding: ["a", "b"], home: home))
    }
}

final class MarketplaceCatalogTests: XCTestCase {
    func testPluginListMergesInstalledAndAvailableAcrossHosts() throws {
        let claude = Data("""
        {"installed":[{"id":"apple-mail@apple-mail-mcp","version":"3.1.2","enabled":true,
          "installPath":"/x","installedAt":"2026-09-15T22:39:34.898Z"},
         {"id":"old@mp","version":"1.0","enabled":false,"installPath":"/y","installedAt":"2026-01-01T00:00:00Z"}],
         "available":[{"pluginId":"apple-mail@apple-mail-mcp","name":"apple-mail","description":"Mail",
           "marketplaceName":"apple-mail-mcp","version":"3.1.2","installCount":10},
          {"pluginId":"fresh@mp","name":"fresh","description":"New","marketplaceName":"mp","installCount":99}]}
        """.utf8)
        let codex = Data("""
        {"installed":[{"pluginId":"fresh@mp","name":"fresh","marketplaceName":"mp","version":"2.0","installed":true,"enabled":true}]}
        """.utf8)
        let merged = MarketplaceCatalog.merge([
            MarketplaceCatalog.plugins(json: claude, hostId: "claude"),
            MarketplaceCatalog.plugins(json: codex, hostId: "codex"),
        ])
        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.identifier, $0) })
        XCTAssertEqual(byId["apple-mail@apple-mail-mcp"]?.installedIn, ["claude"])
        XCTAssertEqual(byId["apple-mail@apple-mail-mcp"]?.summary, "Mail")
        XCTAssertEqual(byId["fresh@mp"]?.installedIn, ["codex"])
        XCTAssertEqual(byId["fresh@mp"]?.installCount, 99)
        XCTAssertEqual(byId["old@mp"]?.enabledIn, [])
        // Installed first, then most installed.
        let order = MarketplaceCatalog.sorted(merged).map(\.identifier)
        XCTAssertEqual(order.last, "old@mp")
        XCTAssertTrue(order.firstIndex(of: "fresh@mp")! < order.firstIndex(of: "old@mp")!)
    }

    func testMCPParsersReadBothCLIs() {
        let claude = MarketplaceCatalog.claudeMCP("""
        Checking MCP server health…

        pencil: /Applications/Pencil.app/mcp-server --app desktop - ✔ Connected
        design-compare: node /x/index.mjs - ✘ Failed to connect — CONNECTION_CLOSED: Connection closed
        mobbin: https://api.mobbin.com/mcp (HTTP) - ✔ Connected
        """)
        XCTAssertEqual(claude.map(\.name), ["pencil", "design-compare", "mobbin"])
        XCTAssertEqual(claude[0].detail, "/Applications/Pencil.app/mcp-server --app desktop")
        XCTAssertEqual(claude[2].status["claude"], "✔ Connected")

        let codex = MarketplaceCatalog.codexMCP("""
        Name     Command  Args           Env  Cwd  Status    Auth
        blender  uvx      blender-mcp    -    -    enabled   Unsupported
        paused   uvx      other-mcp      -    -    disabled  Unsupported

        Name       Url                               Bearer Token Env Var  Status   Auth
        firecrawl  https://mcp.firecrawl.dev/v2/mcp  -                     enabled  Unsupported
        """)
        XCTAssertEqual(codex.map(\.name), ["blender", "paused", "firecrawl"])
        XCTAssertEqual(codex[0].detail, "uvx blender-mcp")
        XCTAssertEqual(codex[1].enabledIn, [])
        XCTAssertEqual(codex[2].detail, "https://mcp.firecrawl.dev/v2/mcp")
    }

    func testMarketplaceListParsing() {
        let list = MarketplaceCatalog.marketplaces("""
        Configured marketplaces:

          ❯ claude-plugins-official
            Source: GitHub (anthropics/claude-plugins-official)

          ❯ apple-mail-mcp
            Source: GitHub (patrickfreyer/apple-mail-mcp)
        """)
        XCTAssertEqual(list.map(\.name), ["claude-plugins-official", "apple-mail-mcp"])
        XCTAssertEqual(list[0].source, "GitHub (anthropics/claude-plugins-official)")
    }
}

final class AgentLibraryTests: XCTestCase {
    private var home = ""
    private var hosts: [AgentHost] = []

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        hosts = AgentHosts.all(home: home)
        for host in hosts {
            try FileManager.default.createDirectory(atPath: host.skillsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: host.promptsDirectory, withIntermediateDirectories: true)
        }
        setenv("HERD_LIBRARY_DIR", home + "/.agents", 1)
    }

    override func tearDown() {
        unsetenv("HERD_LIBRARY_DIR")
        try? FileManager.default.removeItem(atPath: home)
    }

    func testSavedItemInstallsIntoEveryHostAndReadsItsFrontmatter() throws {
        let text = "---\nname: review-diff\ndescription: \"Review the working diff\"\n---\n\nReview it.\n"
        let prompt = try AgentLibrary.save(kind: .prompt, slug: "review-diff", text: text, hosts: hosts, home: home)
        XCTAssertEqual(prompt.name, "review-diff")
        XCTAssertEqual(prompt.summary, "Review the working diff")
        XCTAssertTrue(prompt.installedIn.isEmpty)

        for host in hosts { try AgentLibrary.install(prompt, into: host) }
        let listed = AgentLibrary.items(.prompt, hosts: hosts, home: home)
        XCTAssertEqual(listed.map(\.slug), ["review-diff"])
        XCTAssertEqual(listed[0].installedIn, ["claude", "codex"])
        // The link resolves to the one library copy, so an edit reaches both.
        let viaClaude = try String(contentsOfFile: hosts[0].promptPath("review-diff"), encoding: .utf8)
        XCTAssertEqual(viaClaude, text)

        try AgentLibrary.uninstall(prompt, from: hosts[1])
        XCTAssertEqual(AgentLibrary.items(.prompt, hosts: hosts, home: home)[0].installedIn, ["claude"])
    }

    func testFrontmatterBlockScalarsAndHeadingFallback() {
        let block = AgentLibrary.describe("""
        ---
        name: firecrawl
        description: |
          Scrape and crawl the web.
          Use when a page must be read.
        ---

        # Firecrawl
        """)
        XCTAssertEqual(block.name, "firecrawl")
        XCTAssertEqual(block.summary, "Scrape and crawl the web. Use when a page must be read.")

        // No frontmatter: the heading names it and the first line describes it.
        let plain = AgentLibrary.describe("# Review Diff\n\nReview the working tree diff.\n")
        XCTAssertEqual(plain.name, "Review Diff")
        XCTAssertEqual(plain.summary, "Review the working tree diff.")

        // A `description:` later in the body never overrides the frontmatter.
        let body = AgentLibrary.describe("---\ndescription: The real summary\n---\n\nenv description: something else\n")
        XCTAssertEqual(body.summary, "The real summary")
    }

    func testPromptBodyDropsFrontmatter() {
        let text = "---\ndescription: Review the diff\n---\n\nReview the current diff.\n"
        XCTAssertEqual(AgentLibrary.promptBody(text), "Review the current diff.")
        XCTAssertEqual(AgentLibrary.promptBody("Just the prompt.\n"), "Just the prompt.")
        XCTAssertEqual(AgentLibrary.promptBody("---\nname: x\n---\n"), "")
    }

    func testAdoptMovesAHostsOwnSkillIntoTheLibraryAndLinksItBack() throws {
        let host = hosts[0]
        let skill = host.skillPath("graphify")
        try FileManager.default.createDirectory(atPath: skill, withIntermediateDirectories: true)
        try "---\nname: graphify\ndescription: Knowledge graphs\n---\n".write(toFile: skill + "/SKILL.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentLibrary.unmanaged(.skill, in: host), ["graphify"])

        let adopted = try AgentLibrary.adopt(kind: .skill, slug: "graphify", from: host, hosts: hosts, home: home)
        XCTAssertEqual(adopted.summary, "Knowledge graphs")
        XCTAssertEqual(adopted.installedIn, ["claude"])
        XCTAssertTrue(AgentLibrary.unmanaged(.skill, in: host).isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: skill), adopted.path)

        // A real file in the way is never clobbered.
        let other = hosts[1]
        try FileManager.default.createDirectory(atPath: other.skillPath("graphify"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try AgentLibrary.install(adopted, into: other))
    }
}

final class SlashCommandTests: XCTestCase {
    private var home = ""

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let host = AgentHosts.host("claude", home: home)!
        try FileManager.default.createDirectory(atPath: host.promptsDirectory + "/git", withIntermediateDirectories: true)
        try "---\ndescription: Review the diff\n---\nReview it.".write(toFile: host.promptPath("review-diff"), atomically: true, encoding: .utf8)
        try "# Amend\n\nAmend the last commit.".write(toFile: host.promptsDirectory + "/git/amend.md", atomically: true, encoding: .utf8)
        // A plugin's commands live under its cached version folder.
        let pluginCommands = "\(host.home)/plugins/cache/official/formatter/1.2.0/commands"
        try FileManager.default.createDirectory(atPath: pluginCommands, withIntermediateDirectories: true)
        try "---\ndescription: Format the repo\n---\n".write(toFile: pluginCommands + "/format.md", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testCommandsCombineBuiltInsUserFilesAndPlugins() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: project + "/.claude/commands", withIntermediateDirectories: true)
        try "---\ndescription: Ship it\n---\n".write(toFile: project + "/.claude/commands/ship.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: project) }

        let commands = SlashCommands.all(agent: "claude", cwd: project, home: home)
        let byName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        XCTAssertEqual(byName["compact"]?.origin, .builtIn)
        XCTAssertEqual(byName["review-diff"]?.origin, .user)
        XCTAssertEqual(byName["review-diff"]?.summary, "Review the diff")
        XCTAssertEqual(byName["git:amend"]?.summary, "Amend the last commit.")
        XCTAssertEqual(byName["ship"]?.origin, .project)
        XCTAssertEqual(byName["format"]?.origin, .plugin("formatter"))
        XCTAssertEqual(byName["review-diff"]?.insertion, "/review-diff")

        // Codex gets its own built-ins, not Claude's.
        let codex = SlashCommands.all(agent: "codex", cwd: nil, home: home).map(\.name)
        XCTAssertTrue(codex.contains("approvals"))
        XCTAssertFalse(codex.contains("vim"))
    }

    func testMatchingPrefersPrefixMatchesAndSearchesSummaries() {
        let commands = SlashCommands.all(agent: "claude", cwd: nil, home: home)
        XCTAssertEqual(SlashCommands.matching("comp", in: commands).first?.name, "compact")
        XCTAssertEqual(SlashCommands.matching("rev", in: commands).first?.name, "review")
        // Only the summary mentions vim bindings' "toggle".
        XCTAssertTrue(SlashCommands.matching("toggle", in: commands).contains { $0.name == "vim" })
        XCTAssertTrue(SlashCommands.matching("zzz", in: commands).isEmpty)
        XCTAssertEqual(SlashCommands.matching("", in: commands).count, commands.count)
    }
}
