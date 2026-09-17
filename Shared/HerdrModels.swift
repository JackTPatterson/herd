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
    var terminalId: String? = nil

    var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id", tabId = "tab_id", workspaceId = "workspace_id", focused, cwd
        case foregroundCwd = "foreground_cwd", agentStatus = "agent_status"
        case terminalTitle = "terminal_title_stripped", terminalId = "terminal_id"
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
    var stateChangeSeq: Int? = nil
    var cwd: String? = nil
    var terminalId: String? = nil
    /// Native session reference reported by an official herdr integration.
    var agentSession: SessionReference? = nil

    struct SessionReference: Codable, Equatable {
        let source: String?
        let agent: String?
        let kind: String?
        let value: String?
    }

    var sessionReference: String? { agentSession?.value }

    var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id", tabId = "tab_id", workspaceId = "workspace_id"
        case agent, name, displayAgent = "display_agent", agentStatus = "agent_status"
        case stateChangeSeq = "state_change_seq", cwd, terminalId = "terminal_id", agentSession = "agent_session"
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

/// An installed or linked herdr plugin (`plugin.list`).
struct HerdrPlugin: Decodable, Equatable, Identifiable {
    struct Action: Decodable, Equatable {
        let id: String
        let title: String
        let description: String?
        let contexts: [String]?
    }

    struct Pane: Decodable, Equatable {
        let id: String
        let title: String
        let description: String?
        let placement: String?
    }

    struct Source: Decodable, Equatable {
        let kind: String?
        let owner: String?
        let repo: String?
    }

    let pluginId: String
    let name: String
    let version: String?
    let description: String?
    let enabled: Bool
    let actions: [Action]
    let panes: [Pane]
    let source: Source?

    var id: String { pluginId }
    var isGitHubInstall: Bool { source?.kind == "github" }

    enum CodingKeys: String, CodingKey {
        case pluginId = "plugin_id", name, version, description, enabled, actions, panes, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pluginId = try c.decode(String.self, forKey: .pluginId)
        name = (try? c.decode(String.self, forKey: .name)) ?? pluginId
        version = try? c.decode(String.self, forKey: .version)
        description = try? c.decode(String.self, forKey: .description)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        actions = (try? c.decode([Action].self, forKey: .actions)) ?? []
        panes = (try? c.decode([Pane].self, forKey: .panes)) ?? []
        source = try? c.decode(Source.self, forKey: .source)
    }
}

/// One plugin command run (`plugin.log.list`).
struct HerdrPluginLog: Decodable, Equatable, Identifiable {
    let logId: String
    let pluginId: String
    let actionId: String?
    let event: String?
    let status: String
    let startedUnixMs: UInt64
    let exitCode: Int?
    let stdout: String?
    let stderr: String?
    let error: String?

    var id: String { logId }

    enum CodingKeys: String, CodingKey {
        case logId = "log_id", pluginId = "plugin_id", actionId = "action_id", event, status
        case startedUnixMs = "started_unix_ms", exitCode = "exit_code", stdout, stderr, error
    }
}
