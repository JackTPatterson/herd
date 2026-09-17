import Foundation

/// The slash commands an agent offers: its built-ins plus the prompt files
/// the user and plugins provide. Herd lists them itself so `/` opens a native
/// menu instead of the agent's in-terminal one.
struct SlashCommand: Identifiable, Equatable {
    enum Origin: Equatable {
        case builtIn
        case user
        case project
        case plugin(String)

        var label: String {
            switch self {
            case .builtIn: ""
            case .user: "user"
            case .project: "project"
            case .plugin(let name): name
            }
        }
    }

    /// Without the leading slash.
    let name: String
    var summary: String = ""
    var origin: Origin = .builtIn
    /// Text inserted into the prompt, including the slash.
    var insertion: String { "/" + name }
    var id: String { "\(origin.label):\(name)" }
}

enum SlashCommands {
    /// Built-ins, which the CLIs don't expose for listing.
    static let claudeBuiltIns: [(String, String)] = [
        ("add-dir", "Add a working directory"),
        ("agents", "Manage agents and subagents"),
        ("clear", "Clear the conversation"),
        ("compact", "Summarize the conversation to free context"),
        ("config", "Open settings"),
        ("context", "Show what is using the context window"),
        ("cost", "Show token usage and cost"),
        ("doctor", "Check the installation's health"),
        ("exit", "Quit Claude Code"),
        ("export", "Export the conversation"),
        ("help", "List commands"),
        ("hooks", "Configure hooks"),
        ("init", "Create a CLAUDE.md for this project"),
        ("mcp", "Manage MCP servers"),
        ("memory", "Edit memory files"),
        ("model", "Change the model"),
        ("output-style", "Change the output style"),
        ("permissions", "Manage tool permissions"),
        ("plugin", "Manage plugins"),
        ("pr-comments", "Read pull request comments"),
        ("release-notes", "Show what changed"),
        ("resume", "Resume a past conversation"),
        ("review", "Review a pull request"),
        ("rewind", "Rewind the conversation or the code"),
        ("status", "Show account and system status"),
        ("statusline", "Set up the status line"),
        ("todos", "Show the todo list"),
        ("usage", "Show plan usage limits"),
        ("vim", "Toggle vim bindings"),
    ]

    static let codexBuiltIns: [(String, String)] = [
        ("approvals", "Change what Codex may do without asking"),
        ("compact", "Summarize the conversation to free context"),
        ("diff", "Show the working tree diff"),
        ("init", "Create an AGENTS.md for this project"),
        ("mention", "Mention a file"),
        ("model", "Change the model and reasoning effort"),
        ("new", "Start a new conversation"),
        ("quit", "Quit Codex"),
        ("review", "Review the current changes"),
        ("status", "Show session status"),
        ("undo", "Undo the last change"),
    ]

    /// Every command for an agent, newest sources last so user files can
    /// shadow a built-in of the same name.
    static func all(agent: String?, cwd: String?, home: String = NSHomeDirectory()) -> [SlashCommand] {
        let kind = AgentBrand.forAgent(agent)?.id ?? agent ?? ""
        guard let host = AgentHosts.host(kind, home: home) else { return [] }
        let builtIns = kind == "codex" ? codexBuiltIns : claudeBuiltIns
        var commands = builtIns.map { SlashCommand(name: $0.0, summary: $0.1, origin: .builtIn) }
        commands += prompts(in: host.promptsDirectory, origin: .user)
        if let cwd {
            let projectDirectory = kind == "codex" ? "\(cwd)/.codex/prompts" : "\(cwd)/.claude/commands"
            commands += prompts(in: projectDirectory, origin: .project)
        }
        commands += pluginCommands(host: host)
        var seen = Set<String>()
        // Later sources win; keep the first of each name after reversing.
        return commands.reversed()
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Markdown prompt files, named after the file (nested folders namespace
    /// their commands with `:` the way both CLIs do).
    static func prompts(in directory: String, origin: SlashCommand.Origin, prefix: String = "") -> [SlashCommand] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var commands: [SlashCommand] = []
        for name in names.sorted() {
            let path = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                commands += prompts(in: path, origin: origin, prefix: prefix + name + ":")
                continue
            }
            guard name.hasSuffix(".md") else { continue }
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            commands.append(SlashCommand(
                name: prefix + String(name.dropLast(3)),
                summary: AgentLibrary.describe(text).summary,
                origin: origin
            ))
        }
        return commands
    }

    /// Commands each installed plugin contributes, from its `commands/` folder.
    static func pluginCommands(host: AgentHost) -> [SlashCommand] {
        let cache = "\(host.home)/plugins/cache"
        let manager = FileManager.default
        guard let marketplaces = try? manager.contentsOfDirectory(atPath: cache) else { return [] }
        var commands: [SlashCommand] = []
        for marketplace in marketplaces {
            let marketplacePath = "\(cache)/\(marketplace)"
            for plugin in (try? manager.contentsOfDirectory(atPath: marketplacePath)) ?? [] {
                let pluginPath = "\(marketplacePath)/\(plugin)"
                // Plugins are cached per version: <plugin>/<version>/commands.
                let versions = (try? manager.contentsOfDirectory(atPath: pluginPath)) ?? []
                for version in versions {
                    let directory = "\(pluginPath)/\(version)/commands"
                    guard manager.fileExists(atPath: directory) else { continue }
                    commands += prompts(in: directory, origin: .plugin(plugin))
                }
            }
        }
        return commands
    }

    /// Filters and ranks for the typed text after the slash.
    static func matching(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return commands }
        return commands.compactMap { command -> (SlashCommand, Int)? in
            guard let match = FuzzyMatcher.match(needle, in: command.name) else {
                guard !command.summary.isEmpty, FuzzyMatcher.match(needle, in: command.summary) != nil else { return nil }
                return (command, -1000)
            }
            let exact = command.name.lowercased().hasPrefix(needle.lowercased()) ? 500 : 0
            return (command, match.score + exact)
        }
        .sorted { first, second in
            first.1 == second.1
                ? first.0.name.localizedCaseInsensitiveCompare(second.0.name) == .orderedAscending
                : first.1 > second.1
        }
        .map(\.0)
    }
}
