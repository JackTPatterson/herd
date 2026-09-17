import Foundation

/// An agent CLI Herd can configure. Skills, prompts, and MCP servers are kept
/// once in Herd's shared library and installed into each host, so nothing is
/// Claude- or Codex-only.
struct AgentHost: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Root of the host's own config (`~/.claude`, `~/.codex`).
    let home: String
    /// `<home>/skills/<slug>/SKILL.md`, the layout both hosts already use.
    let skillsDirectory: String
    /// Markdown prompt files the host exposes as slash commands.
    let promptsDirectory: String
    /// CLI executable name, for plugin and MCP commands.
    let cli: String
    /// Whether `<cli> plugin` exists.
    let supportsPlugins: Bool

    func skillPath(_ slug: String) -> String { "\(skillsDirectory)/\(slug)" }
    func promptPath(_ slug: String) -> String { "\(promptsDirectory)/\(slug).md" }
}

enum AgentHosts {
    static func all(home: String = NSHomeDirectory()) -> [AgentHost] {
        [
            AgentHost(id: "claude", displayName: "Claude Code", home: "\(home)/.claude",
                      skillsDirectory: "\(home)/.claude/skills", promptsDirectory: "\(home)/.claude/commands",
                      cli: "claude", supportsPlugins: true),
            AgentHost(id: "codex", displayName: "Codex", home: "\(home)/.codex",
                      skillsDirectory: "\(home)/.codex/skills", promptsDirectory: "\(home)/.codex/prompts",
                      cli: "codex", supportsPlugins: true),
        ]
    }

    /// Hosts that are actually set up on this machine.
    static func installed(home: String = NSHomeDirectory()) -> [AgentHost] {
        all(home: home).filter { FileManager.default.fileExists(atPath: $0.home) }
    }

    static func host(_ id: String, home: String = NSHomeDirectory()) -> AgentHost? {
        all(home: home).first { $0.id == id }
    }
}
