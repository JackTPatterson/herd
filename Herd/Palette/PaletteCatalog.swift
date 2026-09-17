import AppKit
import SwiftUI

/// One palette row.
struct PaletteItem: Identifiable {
    enum Icon {
        case symbol(String)
        case agent(AgentBrand)
        case state(HerdrAgentStatus)
    }

    enum Effect {
        case run(() -> Void)
        /// Ask for text, then run with it (rename, new worktree, …).
        case prompt(title: String, placeholder: String, initial: String, submit: (String) -> Void)
    }

    let id: String
    let kind: PaletteKind
    let title: String
    var subtitle: String = ""
    var keywords: [String] = []
    var shortcut: String?
    var icon: Icon
    var effect: Effect

    var searchable: PaletteSearchable {
        PaletteSearchable(id: id, kind: kind, title: title, subtitle: subtitle, keywords: keywords)
    }
}

/// Builds every palette entry from live herdr state.
@MainActor
enum PaletteCatalog {
    static func items(store: HerdrStore, ui: UIState) -> [PaletteItem] {
        actions(store: store, ui: ui)
            + workspaces(store: store)
            + tabs(store: store)
            + agents(store: store)
            + projects(store: store)
    }

    // MARK: Actions

    static func actions(store: HerdrStore, ui: UIState) -> [PaletteItem] {
        let workspace = store.focusedWorkspace
        let tab = store.focusedWorkspaceTabs.first { $0.tabId == store.snapshot.focusedTabId }
        func action(
            _ id: String, _ title: String, _ symbol: String, shortcut: String? = nil,
            keywords: [String] = [], _ run: @escaping () -> Void
        ) -> PaletteItem {
            PaletteItem(id: "action.\(id)", kind: .action, title: title, keywords: keywords,
                        shortcut: shortcut, icon: .symbol(symbol), effect: .run(run))
        }

        var items: [PaletteItem] = [
            action("newTab", "New Tab", "plus.square", shortcut: "⌘T", keywords: ["create", "terminal"]) { store.newTab() },
            action("closeTab", "Close Tab", "xmark.square", shortcut: "⌘W") { store.closeFocusedTab() },
            action("nextTab", "Next Tab", "arrow.right.square", shortcut: "⌘⇧]") { store.selectAdjacentTab(offset: 1) },
            action("previousTab", "Previous Tab", "arrow.left.square", shortcut: "⌘⇧[") { store.selectAdjacentTab(offset: -1) },
            action("moveTabLeft", "Move Tab Left", "arrow.left.to.line", keywords: ["reorder"]) { store.moveFocusedTab(by: -1) },
            action("moveTabRight", "Move Tab Right", "arrow.right.to.line", keywords: ["reorder"]) { store.moveFocusedTab(by: 1) },
            action("newWorkspace", "New Workspace", "rectangle.stack.badge.plus", shortcut: "⌘N", keywords: ["space"]) { store.newWorkspace() },
            action("openFolder", "Open Folder as Workspace…", "folder.badge.plus", shortcut: "⌘O", keywords: ["project", "directory"]) { openFolder(store: store) },
            action("nextWorkspace", "Next Workspace", "chevron.down.square", shortcut: "⌃⌘↓") { store.selectAdjacentWorkspace(offset: 1) },
            action("previousWorkspace", "Previous Workspace", "chevron.up.square", shortcut: "⌃⌘↑") { store.selectAdjacentWorkspace(offset: -1) },
            action("splitRight", "Split Pane Right", "rectangle.split.2x1", shortcut: "⌘D", keywords: ["vertical"]) { store.splitPane(.right) },
            action("splitDown", "Split Pane Down", "rectangle.split.1x2", shortcut: "⌘⇧D", keywords: ["horizontal"]) { store.splitPane(.down) },
            action("zoomPane", "Toggle Pane Zoom", "arrow.up.left.and.arrow.down.right", shortcut: "⌘⇧↩", keywords: ["maximize"]) { store.toggleZoom() },
            action("closePane", "Close Pane", "xmark.rectangle") { store.closeFocusedPane() },
            action("focusLeft", "Focus Pane Left", "arrow.left", shortcut: "⌘⌥←") { store.focusPane(.left) },
            action("focusRight", "Focus Pane Right", "arrow.right", shortcut: "⌘⌥→") { store.focusPane(.right) },
            action("focusUp", "Focus Pane Up", "arrow.up", shortcut: "⌘⌥↑") { store.focusPane(.up) },
            action("focusDown", "Focus Pane Down", "arrow.down", shortcut: "⌘⌥↓") { store.focusPane(.down) },
            action("toggleSidebar", "Toggle Sidebar", "sidebar.left", shortcut: "⌘B") { ui.sidebarVisible.toggle() },
            action("reloadConfig", "Reload herdr Config", "arrow.clockwise", keywords: ["settings"]) { store.reloadHerdrConfig() },
            action("installHook", "Install Claude Subagent Tabs Hook", "sparkles", keywords: ["claude", "agent", "setup"]) { ClaudeHookMenu.install() },
            action("removeHook", "Remove Claude Subagent Tabs Hook", "sparkles", keywords: ["claude", "agent"]) { ClaudeHookMenu.uninstall() },
            action("revealConfig", "Reveal herdr Config in Finder", "doc.text.magnifyingglass") {
                if let path = HerdrSession.make()?.configPath {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            },
        ]

        if let tab {
            items.append(PaletteItem(
                id: "action.renameTab", kind: .action, title: "Rename Tab…", keywords: ["label"],
                icon: .symbol("pencil"),
                effect: .prompt(title: "Rename Tab", placeholder: "Tab name", initial: tab.label) { label in
                    store.renameTab(tab.tabId, to: label)
                }
            ))
        }
        if let workspace {
            items.append(PaletteItem(
                id: "action.renameWorkspace", kind: .action, title: "Rename Workspace…", keywords: ["label", "space"],
                icon: .symbol("pencil.line"),
                effect: .prompt(title: "Rename Workspace", placeholder: "Workspace name", initial: workspace.label) { label in
                    store.renameWorkspace(workspace.workspaceId, to: label)
                }
            ))
            items.append(PaletteItem(
                id: "action.newWorktree", kind: .action, title: "New Worktree…", keywords: ["git", "branch"],
                icon: .symbol("arrow.triangle.branch"),
                effect: .prompt(title: "New Worktree", placeholder: "Branch name", initial: "") { branch in
                    store.createWorktree(branch: branch)
                }
            ))
            items.append(action("closeWorkspace", "Close Workspace", "xmark.bin") {
                store.closeWorkspace(workspace.workspaceId)
            })
        }
        return items
    }

    // MARK: Navigation

    static func workspaces(store: HerdrStore) -> [PaletteItem] {
        store.groups.flatMap { group in
            group.workspaces.map { workspace in
                let agent = store.primaryAgent(in: store.snapshot.agents(inWorkspace: workspace.workspaceId))
                let branch = store.branches[workspace.workspaceId]
                let subtitle = [group.name, branch, agent.flatMap { a in
                    AgentBrand.forAgent(a.agent).map { "\($0.displayName) \(stateLabel(a.agentStatus))" }
                }].compactMap { $0 }.joined(separator: " · ")
                return PaletteItem(
                    id: "workspace.\(workspace.workspaceId)", kind: .workspace, title: workspace.label,
                    subtitle: subtitle,
                    keywords: [store.snapshot.directory(ofWorkspace: workspace.workspaceId) ?? ""],
                    icon: .state(agent?.agentStatus ?? workspace.agentStatus),
                    effect: .run { store.focusWorkspace(workspace.workspaceId) }
                )
            }
        }
    }

    static func tabs(store: HerdrStore) -> [PaletteItem] {
        let labels = Dictionary(uniqueKeysWithValues: store.snapshot.workspaces.map { ($0.workspaceId, $0.label) })
        return store.snapshot.tabs.sorted { ($0.workspaceId, $0.number) < ($1.workspaceId, $1.number) }.map { tab in
            let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tab.tabId))
            let brand = AgentBrand.forAgent(agent?.agent)
            return PaletteItem(
                id: "tab.\(tab.tabId)", kind: .tab,
                title: tab.label.isEmpty ? "Tab \(tab.number)" : tab.label,
                subtitle: [labels[tab.workspaceId], "tab \(tab.number)"].compactMap { $0 }.joined(separator: " · "),
                icon: brand.map { .agent($0) } ?? .symbol("terminal"),
                effect: .run { store.focusTabAnywhere(tab) }
            )
        }
    }

    static func agents(store: HerdrStore) -> [PaletteItem] {
        let workspaceLabels = Dictionary(uniqueKeysWithValues: store.snapshot.workspaces.map { ($0.workspaceId, $0.label) })
        let tabLabels = Dictionary(uniqueKeysWithValues: store.snapshot.tabs.map { ($0.tabId, $0.label) })
        return store.snapshot.agents.map { agent in
            let brand = AgentBrand.forAgent(agent.agent)
            let name = agent.displayAgent ?? agent.name ?? brand?.displayName ?? agent.agent ?? "Agent"
            return PaletteItem(
                id: "agent.\(agent.paneId)", kind: .agent, title: name,
                subtitle: [stateLabel(agent.agentStatus), agent.workspaceId.flatMap { workspaceLabels[$0] },
                           agent.tabId.flatMap { tabLabels[$0] }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                keywords: [agent.agent ?? ""],
                icon: brand.map { .agent($0) } ?? .state(agent.agentStatus),
                effect: .run { store.focusAgent(paneId: agent.paneId) }
            )
        }
    }

    static func projects(store: HerdrStore) -> [PaletteItem] {
        ProjectDirectories.list().map { path in
            let open = store.groups.contains { $0.id == path }
            return PaletteItem(
                id: "project.\(path)", kind: .project, title: URL(fileURLWithPath: path).lastPathComponent,
                subtitle: abbreviateHome(path) + (open ? " · open" : ""),
                icon: .symbol(open ? "folder.fill" : "folder"),
                effect: .run { store.openProject(path: path) }
            )
        }
    }

    static func openFolder(store: HerdrStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/Developer")
        if panel.runModal() == .OK, let url = panel.url {
            store.openProject(path: url.path)
        }
    }
}

/// Candidate project folders: children of the project parent directories,
/// most recently modified first.
enum ProjectDirectories {
    static func list(parents: [String] = ProjectGrouping.defaultParentDirectories) -> [String] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        var entries: [(path: String, modified: Date)] = []
        for parent in parents {
            let base = parent.hasPrefix("~") ? home + parent.dropFirst() : parent
            guard let names = try? fileManager.contentsOfDirectory(atPath: base) else { continue }
            for name in names where !name.hasPrefix(".") {
                let path = base + "/" + name
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      values.isDirectory == true else { continue }
                entries.append((path, values.contentModificationDate ?? .distantPast))
            }
        }
        return entries.sorted { $0.modified > $1.modified }.map(\.path)
    }
}
