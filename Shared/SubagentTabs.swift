import Foundation

/// Opens a herdr tab for each Claude Code subagent (Agent/Task tool call),
/// named after the subagent and running `herd-cli agent-watch`.
enum SubagentHook {
    static let maxLabelLength = 48

    /// Builds the `layout.apply` params for a subagent tab, or nil when the
    /// payload is not a subagent launch inside a herdr pane.
    static func tabRequest(
        payload: [String: Any],
        environment: [String: String],
        cliPath: String,
        now: Date = Date()
    ) -> [String: Any]? {
        guard let toolName = payload["tool_name"] as? String,
              toolName == "Agent" || toolName == "Task",
              let workspaceId = environment["HERDR_WORKSPACE_ID"], !workspaceId.isEmpty,
              let transcriptPath = payload["transcript_path"] as? String,
              transcriptPath.hasSuffix(".jsonl") else { return nil }

        let input = payload["tool_input"] as? [String: Any]
        let description = (input?["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agentType = (input?["subagent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = tabLabel(agentType: agentType, description: description)

        var command = [
            cliPath, "agent-watch",
            "--dir", String(transcriptPath.dropLast(".jsonl".count)) + "/subagents",
            "--since", String(Int(now.timeIntervalSince1970) - 2),
            "--title", label,
        ]
        if let toolUseId = payload["tool_use_id"] as? String, !toolUseId.isEmpty {
            command += ["--tool-use-id", toolUseId]
        }
        if !description.isEmpty {
            command += ["--description", description]
        }

        var pane: [String: Any] = ["type": "pane", "label": label, "command": command]
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { pane["cwd"] = cwd }
        return [
            "workspace_id": workspaceId,
            "tab_label": label,
            "focus": false,
            "root": pane,
        ]
    }

    static func tabLabel(agentType: String, description: String) -> String {
        let parts = [agentType, description].filter { !$0.isEmpty }
        let label = parts.isEmpty ? "Subagent" : parts.joined(separator: ": ")
        return label.count > maxLabelLength ? String(label.prefix(maxLabelLength - 1)) + "…" : label
    }

    static func handleClaudePreToolUse(payload data: Data, environment: [String: String], cliPath: String) {
        guard environment["HERD_SUBAGENT_TABS"] != "0",
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let socketPath = environment["HERDR_SOCKET_PATH"], !socketPath.isEmpty,
              let request = tabRequest(payload: payload, environment: environment, cliPath: cliPath) else { return }
        _ = try? HerdrClient(socketPath: socketPath).call("layout.apply", request)
    }
}

/// The viewer process inside a subagent tab.
enum SubagentWatch {
    static func run(
        directory: String,
        toolUseId: String?,
        description: String?,
        since: TimeInterval,
        title: String,
        environment: [String: String]
    ) -> Never {
        let reporter = PaneAgentReporter(environment: environment)
        let renderer = SubagentTranscriptRenderer()
        renderer.printHeader(title: title)
        reporter.report(state: "working", message: title)
        renderer.onFinished = { reporter.report(state: "idle", message: "finished") }

        let locator = SubagentTranscriptLocator(
            directory: directory,
            toolUseId: toolUseId,
            description: description,
            since: since
        )
        for _ in 0..<(10 * 60 * 4) {
            if let transcript = locator.find() {
                renderer.follow(transcript)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print(renderer.dim("No subagent transcript appeared in \(directory)."))
        reporter.report(state: "idle", message: "no transcript")
        while true { Thread.sleep(forTimeInterval: 3600) }
    }
}

/// Reports a viewer pane's state to herdr so tabs and the sidebar show the
/// subagent as a working/idle Claude agent.
struct PaneAgentReporter {
    let client: HerdrClient?
    let paneId: String?

    init(environment: [String: String]) {
        paneId = environment["HERDR_PANE_ID"]
        client = environment["HERDR_SOCKET_PATH"].map(HerdrClient.init(socketPath:))
    }

    func report(state: String, message: String) {
        guard let client, let paneId else { return }
        _ = try? client.call("pane.report_agent", [
            "pane_id": paneId,
            "source": "herd:subagent",
            "agent": "claude",
            "state": state,
            "message": message,
        ])
    }
}

/// Adds/removes Herd's PreToolUse hook in `~/.claude/settings.json`.
enum ClaudeHookInstaller {
    static let matcher = "Agent|Task"

    /// Whether a hook command is one Herd installed (any herd-cli path).
    static func isHerdHookCommand(_ command: String) -> Bool {
        command.hasSuffix(" hook claude") && command.contains("herd-cli")
    }

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (settings["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String).map(isHerdHookCommand) ?? false }
        }
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    static func hookCommand(cliPath: String) -> String {
        "'\(cliPath.replacingOccurrences(of: "'", with: "'\"'\"'"))' hook claude"
    }

    /// Returns settings with Herd's hook present (replacing an older path).
    static func installing(into settings: [String: Any], cliPath: String) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": matcher,
            "hooks": [["type": "command", "command": hookCommand(cliPath: cliPath), "timeout": 5]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        return settings
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let preToolUse = hooks["PreToolUse"] as? [[String: Any]] else { return settings }
        let kept = preToolUse.compactMap { entry -> [String: Any]? in
            var entry = entry
            let inner = (entry["hooks"] as? [[String: Any]] ?? []).filter {
                !(($0["command"] as? String).map(isHerdHookCommand) ?? false)
            }
            guard !inner.isEmpty else { return nil }
            entry["hooks"] = inner
            return entry
        }
        if kept.isEmpty { hooks.removeValue(forKey: "PreToolUse") } else { hooks["PreToolUse"] = kept }
        settings["hooks"] = hooks
        return settings
    }

    @discardableResult
    static func install(cliPath: String) throws -> Bool {
        let current = try load()
        let updated = installing(into: current, cliPath: cliPath)
        guard !NSDictionary(dictionary: current).isEqual(to: updated) else { return false }
        try save(updated)
        return true
    }

    @discardableResult
    static func uninstall() throws -> Bool {
        let current = try load()
        let updated = removing(from: current)
        guard !NSDictionary(dictionary: current).isEqual(to: updated) else { return false }
        try save(updated)
        return true
    }

    private static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func save(_ settings: [String: Any]) throws {
        let url = settingsURL
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.herd-backup")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
