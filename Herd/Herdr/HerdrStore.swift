import Foundation
import SwiftUI

/// Live mirror of Herd's herdr session: subscribes to herdr events and
/// re-fetches `session.snapshot` (coalesced) whenever anything changes.
@MainActor
final class HerdrStore: ObservableObject {
    @Published private(set) var snapshot: HerdrSnapshot = .empty
    @Published private(set) var groups: [ProjectGroup] = []
    /// Git branch per workspace id, read from `.git/HEAD` on each snapshot.
    @Published private(set) var branches: [String: String] = [:]
    @Published private(set) var isConnected = false
    @Published var lastError: String?

    let client: HerdrClient
    private let resolver = ProjectGrouping.CachedResolver()
    private var refreshScheduled = false
    private var eventThread: Thread?
    private var pollTimer: Timer?

    init(client: HerdrClient) {
        self.client = client
    }

    var focusedWorkspace: HerdrWorkspace? {
        snapshot.workspaces.first { $0.workspaceId == snapshot.focusedWorkspaceId }
            ?? snapshot.workspaces.first(where: \.focused)
    }

    var focusedWorkspaceTabs: [HerdrTab] {
        guard let id = focusedWorkspace?.workspaceId else { return [] }
        return snapshot.tabs(inWorkspace: id)
    }

    // MARK: - Lifecycle

    func start() {
        let client = self.client
        let thread = Thread { [weak self] in
            while self != nil {
                do {
                    try client.subscribe(connectionCreated: { _ in
                        Task { @MainActor [weak self] in
                            self?.isConnected = true
                            self?.scheduleRefresh()
                        }
                    }, onEvent: { _ in
                        Task { @MainActor [weak self] in self?.scheduleRefresh() }
                    })
                } catch {
                    Task { @MainActor [weak self] in self?.isConnected = false }
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.name = "herd.herdr-events"
        eventThread = thread
        thread.start()
        // Agent state changes are per-pane subscriptions in herdr; a light
        // periodic snapshot keeps state glyphs current.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    func refresh() {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try client.snapshot() }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.apply(snapshot)
                case .failure(let error):
                    self.lastError = String(describing: error)
                }
            }
        }
    }

    func apply(_ snapshot: HerdrSnapshot) {
        guard snapshot != self.snapshot || groups.isEmpty else { return }
        self.snapshot = snapshot
        groups = ProjectGrouping.groups(snapshot: snapshot, resolveRoot: resolver.root(for:))
        var branches: [String: String] = [:]
        for workspace in snapshot.workspaces {
            if let directory = snapshot.directory(ofWorkspace: workspace.workspaceId),
               let branch = GitBranch.current(in: directory) {
                branches[workspace.workspaceId] = branch
            }
        }
        if branches != self.branches { self.branches = branches }
    }

    // MARK: - Actions

    private func perform(_ method: String, _ params: [String: Any]) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try client.call(method, params)
            } catch {
                DispatchQueue.main.async { self?.lastError = String(describing: error) }
            }
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
    }

    func focusWorkspace(_ id: String) { perform("workspace.focus", ["workspace_id": id]) }
    func focusTab(_ id: String) { perform("tab.focus", ["tab_id": id]) }
    func closeTab(_ id: String) { perform("tab.close", ["tab_id": id]) }
    func closeWorkspace(_ id: String) { perform("workspace.close", ["workspace_id": id]) }
    func renameTab(_ id: String, to label: String) { perform("tab.rename", ["tab_id": id, "label": label]) }

    func newTab() {
        var params: [String: Any] = ["focus": true]
        if let workspace = focusedWorkspace {
            params["workspace_id"] = workspace.workspaceId
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { params["cwd"] = cwd }
        }
        perform("tab.create", params)
    }

    func newWorkspace(cwd: String? = nil) {
        var params: [String: Any] = ["focus": true]
        if let cwd { params["cwd"] = cwd }
        perform("workspace.create", params)
    }

    /// Tab 1–9 of the focused workspace (9 = last).
    func selectTab(number: Int) {
        let tabs = focusedWorkspaceTabs
        guard !tabs.isEmpty else { return }
        let index = number >= 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        focusTab(tabs[index].tabId)
    }

    func selectAdjacentTab(offset: Int) {
        let tabs = focusedWorkspaceTabs
        guard let current = tabs.firstIndex(where: { $0.tabId == snapshot.focusedTabId }) ?? tabs.firstIndex(where: \.focused),
              !tabs.isEmpty else { return }
        focusTab(tabs[(current + offset + tabs.count) % tabs.count].tabId)
    }

    /// Next/previous workspace in sidebar (project-grouped) order.
    func selectAdjacentWorkspace(offset: Int) {
        let ordered = groups.flatMap(\.workspaces)
        guard !ordered.isEmpty else { return }
        let current = ordered.firstIndex { $0.workspaceId == focusedWorkspace?.workspaceId } ?? 0
        focusWorkspace(ordered[(current + offset + ordered.count) % ordered.count].workspaceId)
    }

    func closeFocusedTab() {
        guard let id = snapshot.focusedTabId ?? focusedWorkspaceTabs.first(where: \.focused)?.tabId else { return }
        closeTab(id)
    }

    func renameWorkspace(_ id: String, to label: String) {
        perform("workspace.rename", ["workspace_id": id, "label": label])
    }

    var focusedPaneId: String? {
        snapshot.focusedPaneId ?? snapshot.panes.first(where: \.focused)?.paneId
    }

    enum SplitDirection: String { case right, down }
    enum PaneDirection: String { case left, right, up, down }

    func splitPane(_ direction: SplitDirection) {
        var params: [String: Any] = ["direction": direction.rawValue, "focus": true]
        if let pane = focusedPaneId { params["target_pane_id"] = pane }
        if let workspace = focusedWorkspace,
           let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) {
            params["cwd"] = cwd
        }
        perform("pane.split", params)
    }

    func toggleZoom() {
        var params: [String: Any] = ["mode": "toggle"]
        if let pane = focusedPaneId { params["pane_id"] = pane }
        perform("pane.zoom", params)
    }

    func closeFocusedPane() {
        guard let pane = focusedPaneId else { return }
        perform("pane.close", ["pane_id": pane])
    }

    func focusPane(_ direction: PaneDirection) {
        perform("pane.focus_direction", ["direction": direction.rawValue])
    }

    func focusAgent(paneId: String) { perform("agent.focus", ["target": paneId]) }

    /// Focuses a tab in any workspace.
    func focusTabAnywhere(_ tab: HerdrTab) {
        let client = self.client
        let currentWorkspaceId = focusedWorkspace?.workspaceId
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                if tab.workspaceId != currentWorkspaceId {
                    try client.call("workspace.focus", ["workspace_id": tab.workspaceId])
                }
                try client.call("tab.focus", ["tab_id": tab.tabId])
            } catch {
                DispatchQueue.main.async { self?.lastError = String(describing: error) }
            }
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
    }

    func openProject(path: String) {
        let label = URL(fileURLWithPath: path).lastPathComponent
        if let existing = groups.first(where: { $0.id == path })?.workspaces.first {
            focusWorkspace(existing.workspaceId)
            return
        }
        perform("workspace.create", ["cwd": path, "label": label, "focus": true])
    }

    func createWorktree(branch: String) {
        var params: [String: Any] = ["branch": branch, "focus": true]
        if let workspace = focusedWorkspace { params["workspace_id"] = workspace.workspaceId }
        perform("worktree.create", params)
    }

    func reloadHerdrConfig() { perform("server.reload_config", [:]) }

    func moveFocusedTab(by offset: Int) {
        let tabs = focusedWorkspaceTabs
        guard let index = tabs.firstIndex(where: { $0.tabId == snapshot.focusedTabId }) else { return }
        let target = max(0, min(tabs.count - 1, index + offset))
        guard target != index else { return }
        perform("tab.move", ["tab_id": tabs[index].tabId, "insert_index": target])
    }

    // MARK: - Presentation helpers

    /// The most relevant agent in a set: blocked > working > done > idle.
    func primaryAgent(in agents: [HerdrAgent]) -> HerdrAgent? {
        let rank: [HerdrAgentStatus: Int] = [.blocked: 0, .working: 1, .done: 2, .idle: 3, .unknown: 4]
        return agents.min { (rank[$0.agentStatus] ?? 9) < (rank[$1.agentStatus] ?? 9) }
    }
}
