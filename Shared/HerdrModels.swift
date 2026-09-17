import Foundation

/// herdr's semantic agent state.
enum HerdrAgentStatus: String, Codable, Equatable {
    case idle, working, blocked, done, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleContainer().decode(String.self)
        self = HerdrAgentStatus(rawValue: raw) ?? .unknown
    }
}

private extension Decoder {
    func singleContainer() throws -> SingleValueDecodingContainer { try singleValueContainer() }
}

struct HerdrWorkspace: Codable, Equatable, Identifiable {
    let workspaceId: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let tabCount: Int
    let activeTabId: String
    let agentStatus: HerdrAgentStatus
    let worktree: HerdrWorktree?

    var id: String { workspaceId }

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id", number, label, focused
        case paneCount = "pane_count", tabCount = "tab_count"
        case activeTabId = "active_tab_id", agentStatus = "agent_status", worktree
    }
}

/// Worktree provenance herdr attaches to workspaces opened from a repo.
struct HerdrWorktree: Codable, Equatable {
    let repoRoot: String?
    let branch: String?
    let path: String?

    enum CodingKeys: String, CodingKey {
        case repoRoot = "repo_root", branch, path
    }
}

struct HerdrTab: Codable, Equatable, Identifiable {
    let tabId: String
    let workspaceId: String
    let number: Int
    let label: String
    let focused: Bool
    let paneCount: Int
    let agentStatus: HerdrAgentStatus

    var id: String { tabId }

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id", workspaceId = "workspace_id", number, label, focused
        case paneCount = "pane_count", agentStatus = "agent_status"
    }
}

struct HerdrPane: Codable, Equatable, Identifiable {
    let paneId: String
    let tabId: String
    let workspaceId: String
    let focused: Bool
    let cwd: String?
    let foregroundCwd: String?
    let agentStatus: HerdrAgentStatus
    let terminalTitle: String?

    var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id", tabId = "tab_id", workspaceId = "workspace_id", focused, cwd
        case foregroundCwd = "foreground_cwd", agentStatus = "agent_status"
        case terminalTitle = "terminal_title_stripped"
    }
}

struct HerdrAgent: Codable, Equatable, Identifiable {
    let paneId: String
    let tabId: String?
    let workspaceId: String?
    let agent: String?
    let name: String?
    let displayAgent: String?
    let agentStatus: HerdrAgentStatus

    var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id", tabId = "tab_id", workspaceId = "workspace_id"
        case agent, name, displayAgent = "display_agent", agentStatus = "agent_status"
    }
}

struct HerdrSnapshot: Codable, Equatable {
    let workspaces: [HerdrWorkspace]
    let tabs: [HerdrTab]
    let panes: [HerdrPane]
    let agents: [HerdrAgent]
    let focusedWorkspaceId: String?
    let focusedTabId: String?
    let focusedPaneId: String?

    static let empty = HerdrSnapshot(
        workspaces: [], tabs: [], panes: [], agents: [],
        focusedWorkspaceId: nil, focusedTabId: nil, focusedPaneId: nil
    )

    enum CodingKeys: String, CodingKey {
        case workspaces, tabs, panes, agents
        case focusedWorkspaceId = "focused_workspace_id"
        case focusedTabId = "focused_tab_id"
        case focusedPaneId = "focused_pane_id"
    }

    init(
        workspaces: [HerdrWorkspace], tabs: [HerdrTab], panes: [HerdrPane], agents: [HerdrAgent],
        focusedWorkspaceId: String?, focusedTabId: String?, focusedPaneId: String?
    ) {
        self.workspaces = workspaces
        self.tabs = tabs
        self.panes = panes
        self.agents = agents
        self.focusedWorkspaceId = focusedWorkspaceId
        self.focusedTabId = focusedTabId
        self.focusedPaneId = focusedPaneId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decodeIfPresent([HerdrWorkspace].self, forKey: .workspaces) ?? []
        tabs = try c.decodeIfPresent([HerdrTab].self, forKey: .tabs) ?? []
        panes = try c.decodeIfPresent([HerdrPane].self, forKey: .panes) ?? []
        agents = try c.decodeIfPresent([HerdrAgent].self, forKey: .agents) ?? []
        focusedWorkspaceId = try c.decodeIfPresent(String.self, forKey: .focusedWorkspaceId)
        focusedTabId = try c.decodeIfPresent(String.self, forKey: .focusedTabId)
        focusedPaneId = try c.decodeIfPresent(String.self, forKey: .focusedPaneId)
    }

    func tabs(inWorkspace workspaceId: String) -> [HerdrTab] {
        tabs.filter { $0.workspaceId == workspaceId }.sorted { $0.number < $1.number }
    }

    func agents(inTab tabId: String) -> [HerdrAgent] {
        agents.filter { $0.tabId == tabId }
    }

    func agents(inWorkspace workspaceId: String) -> [HerdrAgent] {
        agents.filter { $0.workspaceId == workspaceId }
    }

    /// The directory that best describes a workspace: its first pane's cwd.
    func directory(ofWorkspace workspaceId: String) -> String? {
        let ordered = panes.filter { $0.workspaceId == workspaceId }
        return (ordered.first(where: \.focused) ?? ordered.first).flatMap { $0.foregroundCwd ?? $0.cwd }
    }
}
