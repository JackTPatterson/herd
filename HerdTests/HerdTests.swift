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
