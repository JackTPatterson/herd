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
    /// Plugins installed in Herd's herdr session; refreshed when the palette opens.
    @Published private(set) var plugins: [HerdrPlugin] = []
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

    /// Toast copy for a lasting action: shown while running and when done.
    struct ToastText {
        let progress: String
        let success: String
        let failure: String
    }

    private var toasts: ToastCenter { .shared }

    private func perform(
        _ method: String,
        _ params: [String: Any],
        toast text: ToastText? = nil,
        failure failureTitle: String? = nil,
        then: (@MainActor ([String: Any]) -> Void)? = nil
    ) {
        let client = self.client
        let handle = text.map { toasts.progress($0.progress) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try client.call(method, params) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .success(let result):
                    if let text { self.toasts.succeed(handle, text.success) }
                    then?(result)
                case .failure(let error):
                    let message = Self.describe(error)
                    if let text {
                        self.toasts.fail(handle, text.failure, detail: message)
                    } else if let failureTitle {
                        self.toasts.fail(nil, failureTitle, detail: message)
                    } else {
                        self.lastError = message
                    }
                }
                self.scheduleRefresh()
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if case HerdrSocketError.server(_, let message) = error, !message.isEmpty { return message }
        return String(describing: error)
    }

    private func tabLabel(_ id: String) -> String {
        snapshot.tabs.first { $0.tabId == id }.map { tab in
            tab.label.isEmpty || Int(tab.label) != nil ? "tab \(tab.label.isEmpty ? String(tab.number) : tab.label)" : tab.label
        } ?? "tab"
    }

    private func workspaceLabel(_ id: String) -> String {
        snapshot.workspaces.first { $0.workspaceId == id }?.label ?? "workspace"
    }

    func focusWorkspace(_ id: String) { perform("workspace.focus", ["workspace_id": id]) }
    func focusTab(_ id: String) { perform("tab.focus", ["tab_id": id]) }

    func closeTab(_ id: String) {
        let label = tabLabel(id)
        perform("tab.close", ["tab_id": id], failure: "Couldn't close \(label)")
    }

    func closeWorkspace(_ id: String) {
        let label = workspaceLabel(id)
        perform("workspace.close", ["workspace_id": id], failure: "Couldn't close workspace \(label)")
    }

    func renameTab(_ id: String, to label: String) {
        perform("tab.rename", ["tab_id": id, "label": label], failure: "Couldn't rename tab")
    }

    func newTab() {
        var params: [String: Any] = ["focus": true]
        if let workspace = focusedWorkspace {
            params["workspace_id"] = workspace.workspaceId
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { params["cwd"] = cwd }
        }
        perform("tab.create", params, failure: "Couldn't open a tab")
    }

    func newWorkspace(cwd: String? = nil) {
        var params: [String: Any] = ["focus": true]
        if let cwd { params["cwd"] = cwd }
        perform("workspace.create", params, failure: "Couldn't create a workspace")
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
        perform("workspace.rename", ["workspace_id": id, "label": label], failure: "Couldn't rename workspace")
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
        perform("pane.split", params, failure: "Couldn't split pane")
    }

    func toggleZoom() {
        var params: [String: Any] = ["mode": "toggle"]
        if let pane = focusedPaneId { params["pane_id"] = pane }
        perform("pane.zoom", params)
    }

    func closeFocusedPane() {
        guard let pane = focusedPaneId else { return }
        perform("pane.close", ["pane_id": pane], failure: "Couldn't close pane")
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
        perform("workspace.create", ["cwd": path, "label": label, "focus": true], failure: "Couldn't open \(label)")
    }

    func createWorktree(branch: String) {
        var params: [String: Any] = ["branch": branch, "focus": true]
        if let workspace = focusedWorkspace { params["workspace_id"] = workspace.workspaceId }
        perform("worktree.create", params, toast: ToastText(
            progress: "Creating worktree \(branch)…", success: "Created worktree \(branch)",
            failure: "Couldn't create worktree \(branch)"
        ))
    }

    func reloadHerdrConfig() {
        perform("server.reload_config", [:], toast: ToastText(
            progress: "Reloading herdr config…", success: "Reloaded herdr config", failure: "Couldn't reload herdr config"
        ))
    }

    func moveFocusedTab(by offset: Int) {
        let tabs = focusedWorkspaceTabs
        guard let index = tabs.firstIndex(where: { $0.tabId == snapshot.focusedTabId }) else { return }
        let target = max(0, min(tabs.count - 1, index + offset))
        guard target != index else { return }
        let label = tabLabel(tabs[index].tabId)
        perform("tab.move", ["tab_id": tabs[index].tabId, "insert_index": target], failure: "Couldn't move \(label)")
    }

    // MARK: - Plugins

    func refreshPlugins() {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plugins: [HerdrPlugin]
            do {
                let result = try client.call("plugin.list")
                let data = try JSONSerialization.data(withJSONObject: result["plugins"] ?? [])
                plugins = try JSONDecoder().decode([HerdrPlugin].self, from: data)
            } catch {
                DispatchQueue.main.async { self?.lastError = String(describing: error) }
                return
            }
            DispatchQueue.main.async {
                if self?.plugins != plugins { self?.plugins = plugins }
            }
        }
    }

    /// Context herdr passes to plugin commands, matching what herdr's own UI sends.
    var pluginInvocationContext: [String: Any] {
        var context: [String: Any] = ["invocation_source": "herd-palette"]
        if let workspace = focusedWorkspace {
            context["workspace_id"] = workspace.workspaceId
            context["workspace_label"] = workspace.label
            if let cwd = snapshot.directory(ofWorkspace: workspace.workspaceId) { context["workspace_cwd"] = cwd }
        }
        if let tab = focusedWorkspaceTabs.first(where: { $0.tabId == snapshot.focusedTabId }) {
            context["tab_id"] = tab.tabId
            context["tab_label"] = tab.label
        }
        if let paneId = focusedPaneId {
            context["focused_pane_id"] = paneId
            if let pane = snapshot.panes.first(where: { $0.paneId == paneId }) {
                if let cwd = pane.foregroundCwd ?? pane.cwd { context["focused_pane_cwd"] = cwd }
                context["focused_pane_status"] = pane.agentStatus.rawValue
            }
            if let agent = snapshot.agents.first(where: { $0.paneId == paneId })?.agent {
                context["focused_pane_agent"] = agent
            }
        }
        return context
    }

    /// Invokes a plugin action and follows its run in `plugin.log.list` so the
    /// toast reports when the command actually finishes, not just when herdr
    /// accepted it.
    func invokePluginAction(pluginId: String, actionId: String, title: String) {
        let client = self.client
        let handle = toasts.progress("Running \(title)…")
        let started = UInt64(Date().timeIntervalSince1970 * 1000) - 1000
        let params: [String: Any] = ["plugin_id": pluginId, "action_id": actionId, "context": pluginInvocationContext]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try client.call("plugin.action.invoke", params)
            } catch {
                DispatchQueue.main.async { self?.toasts.fail(handle, "Couldn't run \(title)", detail: Self.describe(error)) }
                return
            }
            var log: HerdrPluginLog?
            for _ in 0..<240 {
                let logs = (try? client.call("plugin.log.list", ["plugin_id": pluginId, "limit": 10]))
                    .flatMap { try? JSONSerialization.data(withJSONObject: $0["logs"] ?? []) }
                    .flatMap { try? JSONDecoder().decode([HerdrPluginLog].self, from: $0) } ?? []
                log = logs.filter { $0.actionId == actionId && $0.startedUnixMs >= started }
                    .max { $0.startedUnixMs < $1.startedUnixMs }
                if let log, log.status != "running" { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch log?.status {
                case "succeeded":
                    self.toasts.succeed(handle, "\(title) finished",
                                        detail: log?.stdout.map { PluginCLI.lastLines($0, count: 2) })
                case "failed":
                    let detail = [log?.error, log?.stderr, log?.exitCode.map { "exit \($0)" }]
                        .compactMap { $0 }.first { !$0.isEmpty }
                    self.toasts.fail(handle, "\(title) failed", detail: detail.map { PluginCLI.lastLines($0) })
                default:
                    self.toasts.succeed(handle, "Started \(title)", detail: "Still running — see the plugin's logs")
                }
                self.scheduleRefresh()
            }
        }
    }

    func openPluginPane(pluginId: String, paneId: String, placement: String?, title: String) {
        var params: [String: Any] = ["plugin_id": pluginId, "entrypoint": paneId, "focus": true]
        // Overlay and popup panes always attach to the active pane; herdr
        // rejects an explicit target for them.
        if let pane = focusedPaneId, placement == "split" || placement == "tab" || placement == "zoomed" {
            params["target_pane_id"] = pane
        }
        perform("plugin.pane.open", params, failure: "Couldn't open \(title)")
    }

    private func pluginName(_ pluginId: String) -> String {
        plugins.first { $0.pluginId == pluginId }?.name ?? pluginId
    }

    func setPluginEnabled(_ pluginId: String, _ enabled: Bool) {
        let name = pluginName(pluginId)
        perform(enabled ? "plugin.enable" : "plugin.disable", ["plugin_id": pluginId], toast: ToastText(
            progress: "\(enabled ? "Enabling" : "Disabling") \(name)…",
            success: "\(enabled ? "Enabled" : "Disabled") \(name)",
            failure: "Couldn't \(enabled ? "enable" : "disable") \(name)"
        )) { [weak self] _ in self?.refreshPlugins() }
    }

    func unlinkPlugin(_ pluginId: String) {
        let name = pluginName(pluginId)
        perform("plugin.unlink", ["plugin_id": pluginId], toast: ToastText(
            progress: "Unlinking \(name)…", success: "Unlinked \(name)", failure: "Couldn't unlink \(name)"
        )) { [weak self] _ in self?.refreshPlugins() }
    }

    func linkPlugin(path: String) {
        let folder = URL(fileURLWithPath: path).lastPathComponent
        perform("plugin.link", ["path": path], toast: ToastText(
            progress: "Linking \(folder)…", success: "Linked plugin \(folder)", failure: "Couldn't link \(folder)"
        )) { [weak self] _ in self?.refreshPlugins() }
    }

    /// Downloads the plugin, shows herdr's install preview for confirmation,
    /// then installs it — with a toast for each stage.
    func installPlugin(repo: String, herdrPath: String, confirm: @escaping (String) -> Bool) {
        let handle = toasts.progress("Downloading \(repo)…", detail: "Fetching the install preview")
        PluginCLI.preview(repo: repo, herdrPath: herdrPath) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.toasts.fail(handle, "Couldn't download \(repo)", detail: String(describing: error))
            case .success(let preview):
                let name = PluginCLI.previewField("name", in: preview) ?? repo
                let version = PluginCLI.previewField("version", in: preview)
                self.toasts.dismiss(handleId: handle)
                guard confirm(preview) else {
                    self.toasts.info("Install cancelled", detail: name)
                    return
                }
                let installing = self.toasts.progress("Installing \(name)…", detail: "Running the plugin's build steps")
                PluginCLI.install(repo: repo, herdrPath: herdrPath) { outcome in
                    if outcome.exitCode == 0 {
                        self.toasts.succeed(installing, "Installed \(name)\(version.map { " \($0)" } ?? "")")
                    } else {
                        self.toasts.fail(installing, "Couldn't install \(name)", detail: PluginCLI.lastLines(outcome.output))
                    }
                    self.refreshPlugins()
                }
            }
        }
    }

    func uninstallPlugin(_ pluginId: String, herdrPath: String) {
        let name = pluginName(pluginId)
        let handle = toasts.progress("Removing \(name)…")
        PluginCLI.uninstall(pluginId: pluginId, herdrPath: herdrPath) { [weak self] outcome in
            guard let self else { return }
            if outcome.exitCode == 0 {
                self.toasts.succeed(handle, "Removed \(name)")
            } else {
                self.toasts.fail(handle, "Couldn't remove \(name)", detail: PluginCLI.lastLines(outcome.output))
            }
            self.refreshPlugins()
        }
    }

    func pluginLogs(pluginId: String?, completion: @escaping ([HerdrPluginLog]) -> Void) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            var params: [String: Any] = ["limit": 50]
            if let pluginId { params["plugin_id"] = pluginId }
            let logs = (try? client.call("plugin.log.list", params))
                .flatMap { try? JSONSerialization.data(withJSONObject: $0["logs"] ?? []) }
                .flatMap { try? JSONDecoder().decode([HerdrPluginLog].self, from: $0) } ?? []
            DispatchQueue.main.async { completion(logs) }
        }
    }

    // MARK: - Presentation helpers

    /// The most relevant agent in a set: blocked > working > done > idle.
    func primaryAgent(in agents: [HerdrAgent]) -> HerdrAgent? {
        let rank: [HerdrAgentStatus: Int] = [.blocked: 0, .working: 1, .done: 2, .idle: 3, .unknown: 4]
        return agents.min { (rank[$0.agentStatus] ?? 9) < (rank[$1.agentStatus] ?? 9) }
    }
}
