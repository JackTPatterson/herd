import AppKit
import Foundation

/// Journals every Claude/Codex (and integration-reported) agent session and,
/// when a shutdown or herdr restart kills them, offers to resume them in
/// their workspaces with `claude --resume <id>` / `codex resume <id>`.
@MainActor
final class AgentRecoveryController: ObservableObject {
    /// Sessions offered for recovery; the panel shows while non-empty.
    @Published private(set) var offered: [AgentSessionRecord] = []
    /// True when the panel was opened by hand (history), not after a restart.
    @Published private(set) var showingHistory = false

    private let client: HerdrClient
    private let url: URL
    private var journal: AgentSessionJournal
    /// `lastObserved` from the previous run, consumed by the first check.
    private var pendingCheck: Date?
    private var lastInference = Date.distantPast
    private var lastSave = Date.distantPast
    private var lastSnapshot: HerdrSnapshot = .empty
    /// herdr's native resume needs a few seconds to relaunch agents.
    static let gracePeriod: TimeInterval = 8
    static let inferenceInterval: TimeInterval = 10

    init(client: HerdrClient, url: URL = HerdrSession.supportDirectory.appendingPathComponent("agent-sessions.json")) {
        self.client = client
        self.url = url
        journal = AgentSessionJournal.load(from: url)
        pendingCheck = journal.records.isEmpty ? nil : journal.lastObserved
    }

    /// herdr went away and came back (crash, `server stop`, update handoff):
    /// check again against the last snapshot seen before the drop.
    func connectionLost() {
        guard pendingCheck == nil, !journal.records.isEmpty else { return }
        pendingCheck = journal.lastObserved
        save()
    }

    /// Terminal id → first-seen time, for off-main session inference.
    /// Nil when inference isn't due yet.
    func inferenceRequest(now: Date = Date()) -> [String: Date]? {
        guard now.timeIntervalSince(lastInference) >= Self.inferenceInterval else { return nil }
        lastInference = now
        return Dictionary(journal.records.map { ($0.terminalId, $0.firstSeen) }, uniquingKeysWith: { first, _ in first })
    }

    func observe(_ snapshot: HerdrSnapshot, inferred: [String: String], now: Date = Date()) {
        lastSnapshot = snapshot
        let before = journal.records
        // Record against the pre-restart journal only after the check has
        // captured which sessions were alive.
        if let lastObserved = pendingCheck {
            pendingCheck = nil
            let candidates = before.filter { $0.lastSeen >= lastObserved.addingTimeInterval(-2) }
            if !candidates.isEmpty, SettingsStore.shared.values.offerRecovery {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracePeriod) { [weak self] in
                    self?.offerLost(candidates, lastObserved: lastObserved)
                }
            }
        }
        journal.records = AgentRecovery.record(snapshot, into: before, now: now) { agent, _ in
            agent.sessionReference ?? agent.terminalId.flatMap { inferred[$0] }
        }
        journal.lastObserved = now
        let changed = journal.records.map(\.sessionId) != before.map(\.sessionId) || journal.records.count != before.count
        if changed || now.timeIntervalSince(lastSave) > 20 { save() }
    }

    private func offerLost(_ candidates: [AgentSessionRecord], lastObserved: Date) {
        let liveSessions = Set(journal.records.filter { $0.lastSeen >= journal.lastObserved.addingTimeInterval(-2) }.compactMap(\.sessionId))
        let lost = AgentRecovery.lostSessions(journal: candidates, lastObserved: lastObserved,
                                              current: lastSnapshot, liveSessionIds: liveSessions)
        guard !lost.isEmpty else { return }
        showingHistory = false
        offered = lost
    }

    /// Opens the panel with recent sessions that aren't running.
    func showHistory() {
        let history = AgentRecovery.history(journal: journal.records, current: lastSnapshot)
        guard !history.isEmpty else {
            ToastCenter.shared.info("No agent sessions to recover",
                                    detail: "Herd records Claude and Codex sessions while they run")
            return
        }
        showingHistory = true
        offered = Array(history.prefix(30))
    }

    func dismiss() {
        if !showingHistory { markHandled(offered) }
        offered = []
    }

    func copyCommand(_ record: AgentSessionRecord) {
        guard let command = record.resumeCommand else { return }
        let text = "cd \(shellPath(record.cwd)) && \(command)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastCenter.shared.info("Copied resume command", detail: text)
    }

    /// Resumes each session in a new tab of its workspace (recreated when gone).
    func resume(_ records: [AgentSessionRecord]) {
        let targets = records.filter { $0.resumeCommand != nil }
        guard !targets.isEmpty else { return }
        offered.removeAll { record in targets.contains { $0.id == record.id } }
        markHandled(targets)
        let noun = targets.count == 1 ? "\(Self.displayName(targets[0])) session" : "\(targets.count) agent sessions"
        let toast = ToastCenter.shared.progress("Resuming \(noun)…")
        let client = self.client
        let snapshot = lastSnapshot
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var createdWorkspaces: [String: String] = [:]
            for record in targets {
                do {
                    try Self.resume(record, client: client, snapshot: snapshot, shell: shell, created: &createdWorkspaces)
                } catch {
                    failures.append("\(record.tabLabel.isEmpty ? record.agent : record.tabLabel): \(error)")
                }
            }
            DispatchQueue.main.async {
                let resumed = targets.count - failures.count
                if failures.isEmpty {
                    ToastCenter.shared.succeed(toast, "Resumed \(noun)")
                } else {
                    ToastCenter.shared.fail(toast, "Resumed \(resumed) of \(targets.count) sessions",
                                            detail: failures.prefix(3).joined(separator: "\n"))
                }
            }
        }
    }

    private nonisolated static func resume(
        _ record: AgentSessionRecord,
        client: HerdrClient,
        snapshot: HerdrSnapshot,
        shell: String,
        created: inout [String: String]
    ) throws {
        guard record.resumeCommand != nil else { return }
        let key = record.workspaceLabel + "\u{0}" + record.cwd
        var tabId: String?
        var workspaceId = created[key]
            ?? snapshot.workspaces.first { $0.label == record.workspaceLabel && snapshot.directory(ofWorkspace: $0.workspaceId) == record.cwd }?.workspaceId
            ?? snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == record.cwd }?.workspaceId
        if workspaceId == nil {
            let label = record.workspaceLabel.isEmpty ? URL(fileURLWithPath: record.cwd).lastPathComponent : record.workspaceLabel
            let result = try client.call("workspace.create", ["cwd": record.cwd, "label": label, "focus": false])
            workspaceId = (result["workspace"] as? [String: Any])?["workspace_id"] as? String
            // Fill the new workspace's empty first tab instead of adding one.
            tabId = (result["tab"] as? [String: Any])?["tab_id"] as? String
            if let workspaceId { created[key] = workspaceId }
        }
        try client.call("layout.apply", AgentRecovery.resumeRequest(
            record, shell: shell, workspaceId: workspaceId, tabId: tabId
        ))
    }

    nonisolated static func displayName(_ record: AgentSessionRecord) -> String {
        AgentBrand.forAgent(record.agent)?.displayName ?? record.agent
    }

    private func markHandled(_ records: [AgentSessionRecord]) {
        let ids = Set(records.map(\.id))
        for index in journal.records.indices where ids.contains(journal.records[index].id) {
            journal.records[index].handled = true
        }
        save()
    }

    private func save() {
        lastSave = Date()
        let journal = self.journal, url = self.url
        DispatchQueue.global(qos: .utility).async { journal.save(to: url) }
    }

    private func shellPath(_ path: String) -> String {
        path.range(of: "^[A-Za-z0-9_./~-]+$", options: .regularExpression) != nil
            ? path : "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
