import AppKit
import Foundation

/// Backs the Marketplace: browses and installs MCP servers, plugins, skills
/// and prompts across every agent host, then reloads running agents in place
/// so changes apply without losing the conversation.
@MainActor
final class MarketplaceStore: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case mcp, plugins, skills, prompts

        var id: String { rawValue }
        var title: String {
            switch self {
            case .mcp: "MCP Servers"
            case .plugins: "Plugins"
            case .skills: "Skills"
            case .prompts: "Prompts"
            }
        }
        var symbol: String {
            switch self {
            case .mcp: "point.3.connected.trianglepath.dotted"
            case .plugins: "puzzlepiece.extension"
            case .skills: "graduationcap"
            case .prompts: "text.bubble"
            }
        }
    }

    @Published var section: Section = .mcp
    @Published var query = ""
    @Published private(set) var hosts: [AgentHost] = []
    @Published private(set) var plugins: [MarketplaceEntry] = []
    @Published private(set) var servers: [MarketplaceEntry] = []
    @Published private(set) var skills: [AgentLibrary.Item] = []
    @Published private(set) var prompts: [AgentLibrary.Item] = []
    @Published private(set) var marketplaces: [String: [String]] = [:]
    @Published private(set) var loading: Set<Section> = []
    /// Set after a change that running agents only pick up on restart.
    @Published private(set) var pendingReload = false

    private let recovery: AgentRecoveryController
    private unowned let herdr: HerdrStore
    private var catalogLoadedAt = Date.distantPast
    private static let catalogURL = HerdrSession.supportDirectory.appendingPathComponent("plugin-catalog.json")
    /// The plugin catalogs take tens of seconds to fetch, so they're cached.
    static let catalogLifetime: TimeInterval = 6 * 3600

    init(herdr: HerdrStore) {
        self.herdr = herdr
        recovery = herdr.recovery
        hosts = AgentHosts.installed()
    }

    /// The agent a prompt would run in: the focused pane's, else the only one.
    var promptTarget: HerdrAgent? {
        let agents = herdr.snapshot.agents
        return agents.first { $0.paneId == herdr.snapshot.focusedPaneId }
            ?? agents.first { $0.tabId == herdr.snapshot.focusedTabId }
            ?? (agents.count == 1 ? agents.first : nil)
    }

    /// Submits a library prompt to a running agent, whichever agent it is.
    func runPrompt(_ item: AgentLibrary.Item) {
        guard let agent = promptTarget else {
            ToastCenter.shared.info("No agent to run this in", detail: "Focus a tab running an agent first")
            return
        }
        let text = text(of: item)
        let body = AgentLibrary.promptBody(text)
        guard !body.isEmpty else {
            ToastCenter.shared.fail(nil, "\(item.name) is empty")
            return
        }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? "the agent"
        let toast = ToastCenter.shared.progress("Sending \(item.name) to \(name)…")
        let client = herdr.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try client.call("agent.prompt", ["target": agent.paneId, "text": body]) }
            DispatchQueue.main.async {
                switch outcome {
                case .success:
                    ToastCenter.shared.succeed(toast, "Sent \(item.name) to \(name)")
                case .failure(let error):
                    ToastCenter.shared.fail(toast, "Couldn't send \(item.name)", detail: String(describing: error))
                }
            }
        }
    }

    /// Copies `.md` files from a folder into the library (a prompt pack).
    func importPrompts(from directory: URL, installIn hosts: [AgentHost]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasSuffix(".md") && $0.lowercased() != "readme.md" }
        guard !files.isEmpty else {
            ToastCenter.shared.info("No prompts found", detail: "\(directory.lastPathComponent) has no .md files")
            return
        }
        var added = 0
        for file in files {
            let slug = String(file.dropLast(3))
            guard let text = try? String(contentsOfFile: directory.appendingPathComponent(file).path, encoding: .utf8) else { continue }
            if saveLibraryItem(kind: .prompt, slug: slug, text: text, installIn: hosts, quiet: true) { added += 1 }
        }
        loadLibrary()
        ToastCenter.shared.info("Imported \(added) prompt\(added == 1 ? "" : "s")",
                                detail: "From \(directory.lastPathComponent)")
    }

    // MARK: - Loading

    func refreshAll(force: Bool = false) {
        hosts = AgentHosts.installed()
        loadLibrary()
        loadServers()
        loadPlugins(force: force)
    }

    func loadLibrary() {
        skills = AgentLibrary.items(.skill, hosts: hosts)
        prompts = AgentLibrary.items(.prompt, hosts: hosts)
    }

    func loadServers() {
        guard !loading.contains(.mcp) else { return }
        loading.insert(.mcp)
        let hosts = self.hosts
        run(hosts.map { "\($0.cli) mcp list" }, timeout: 120) { [weak self] outputs in
            guard let self else { return }
            let lists = zip(hosts, outputs).map { host, output in
                host.id == "codex" ? MarketplaceCatalog.codexMCP(output) : MarketplaceCatalog.claudeMCP(output)
            }
            self.servers = MarketplaceCatalog.merge(lists).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.loading.remove(.mcp)
        }
    }

    func loadPlugins(force: Bool) {
        guard !loading.contains(.plugins) else { return }
        if !force, plugins.isEmpty, let cached = Self.loadCachedCatalog() {
            plugins = cached.entries
            catalogLoadedAt = cached.date
        }
        guard force || Date().timeIntervalSince(catalogLoadedAt) > Self.catalogLifetime else { return }
        loading.insert(.plugins)
        let hosts = self.hosts.filter(\.supportsPlugins)
        // --available pulls every configured marketplace, which is slow.
        run(hosts.map { "\($0.cli) plugin list --json --available" }, timeout: 300) { [weak self] outputs in
            guard let self else { return }
            let lists = zip(hosts, outputs).map { host, output in
                MarketplaceCatalog.plugins(json: Data(Self.jsonBody(output).utf8), hostId: host.id)
            }
            let merged = MarketplaceCatalog.merge(lists)
            if !merged.isEmpty {
                self.plugins = merged
                self.catalogLoadedAt = Date()
                Self.cacheCatalog(outputs: zip(hosts.map(\.id), outputs).map { ($0, $1) })
            }
            self.loading.remove(.plugins)
        }
        run(hosts.map { "\($0.cli) plugin marketplace list" }, timeout: 120) { [weak self] outputs in
            guard let self else { return }
            var result: [String: [String]] = [:]
            for (host, output) in zip(hosts, outputs) {
                result[host.id] = MarketplaceCatalog.marketplaces(output).map(\.name)
            }
            self.marketplaces = result
        }
    }

    // MARK: - Actions

    func installPlugin(_ entry: MarketplaceEntry, into hosts: [AgentHost]) {
        perform(
            hosts.map { "\($0.cli) plugin install \(PluginCLI.quote(entry.identifier))" },
            progress: "Installing \(entry.name)…",
            success: "Installed \(entry.name)",
            failure: "Couldn't install \(entry.name)",
            reloadAgents: true
        ) { [weak self] in self?.loadPlugins(force: true) }
    }

    func uninstallPlugin(_ entry: MarketplaceEntry, from hosts: [AgentHost]) {
        perform(
            hosts.map { "\($0.cli) plugin uninstall \(PluginCLI.quote(entry.identifier))" },
            progress: "Removing \(entry.name)…",
            success: "Removed \(entry.name)",
            failure: "Couldn't remove \(entry.name)",
            reloadAgents: true
        ) { [weak self] in self?.loadPlugins(force: true) }
    }

    func setPluginEnabled(_ entry: MarketplaceEntry, in host: AgentHost, enabled: Bool) {
        let verb = enabled ? "enable" : "disable"
        perform(
            ["\(host.cli) plugin \(verb) \(PluginCLI.quote(entry.identifier))"],
            progress: "\(enabled ? "Enabling" : "Disabling") \(entry.name)…",
            success: "\(enabled ? "Enabled" : "Disabled") \(entry.name)",
            failure: "Couldn't \(verb) \(entry.name)",
            reloadAgents: true
        ) { [weak self] in self?.loadPlugins(force: true) }
    }

    func addMarketplace(_ source: String, to hosts: [AgentHost]) {
        perform(
            hosts.map { "\($0.cli) plugin marketplace add \(PluginCLI.quote(source))" },
            progress: "Adding marketplace \(source)…",
            success: "Added marketplace \(source)",
            failure: "Couldn't add \(source)",
            reloadAgents: false
        ) { [weak self] in self?.loadPlugins(force: true) }
    }

    /// Adds an MCP server from one definition, in each host's own syntax.
    func addServer(name: String, command: String, into hosts: [AgentHost]) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let isURL = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        let commands = hosts.map { host -> String in
            switch host.id {
            case "codex":
                return isURL
                    ? "\(host.cli) mcp add \(PluginCLI.quote(name)) --url \(PluginCLI.quote(trimmed))"
                    : "\(host.cli) mcp add \(PluginCLI.quote(name)) -- \(trimmed)"
            default:
                return isURL
                    ? "\(host.cli) mcp add --transport http \(PluginCLI.quote(name)) \(PluginCLI.quote(trimmed))"
                    : "\(host.cli) mcp add \(PluginCLI.quote(name)) -- \(trimmed)"
            }
        }
        perform(commands, progress: "Adding \(name)…", success: "Added MCP server \(name)",
                failure: "Couldn't add \(name)", reloadAgents: true) { [weak self] in self?.loadServers() }
    }

    func removeServer(_ entry: MarketplaceEntry, from hosts: [AgentHost]) {
        perform(
            hosts.map { "\($0.cli) mcp remove \(PluginCLI.quote(entry.identifier))" },
            progress: "Removing \(entry.name)…",
            success: "Removed MCP server \(entry.name)",
            failure: "Couldn't remove \(entry.name)",
            reloadAgents: true
        ) { [weak self] in self?.loadServers() }
    }

    /// Adds an entry to hosts it isn't in yet. For an MCP server this copies
    /// the definition another agent already has.
    func add(_ entry: MarketplaceEntry, to hosts: [AgentHost]) {
        switch entry.kind {
        case .plugin: installPlugin(entry, into: hosts)
        case .mcp: addServer(name: entry.identifier, command: entry.detail, into: hosts)
        }
    }

    func remove(_ entry: MarketplaceEntry, from hosts: [AgentHost]) {
        switch entry.kind {
        case .plugin: uninstallPlugin(entry, from: hosts)
        case .mcp: removeServer(entry, from: hosts)
        }
    }

    // MARK: Library (skills and prompts)

    func setLibraryInstalled(_ item: AgentLibrary.Item, host: AgentHost, installed: Bool) {
        do {
            if installed {
                try AgentLibrary.install(item, into: host)
            } else {
                try AgentLibrary.uninstall(item, from: host)
            }
            loadLibrary()
            markPendingReload(item.kind == .skill)
            ToastCenter.shared.info(
                "\(installed ? "Added" : "Removed") \(item.name) \(installed ? "to" : "from") \(host.displayName)"
            )
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't update \(item.name)", detail: String(describing: error))
        }
    }

    @discardableResult
    func saveLibraryItem(kind: AgentLibrary.Kind, slug: String, text: String, installIn hosts: [AgentHost], quiet: Bool = false) -> Bool {
        do {
            let item = try AgentLibrary.save(kind: kind, slug: slug, text: text, hosts: self.hosts)
            for host in hosts { try AgentLibrary.install(item, into: host) }
            loadLibrary()
            markPendingReload(kind == .skill)
            if !quiet {
                ToastCenter.shared.info("Saved \(item.name)", detail: hosts.isEmpty ? nil : "Installed in \(hosts.map(\.displayName).joined(separator: ", "))")
            }
            return true
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't save \(slug)", detail: String(describing: error))
            return false
        }
    }

    func deleteLibraryItem(_ item: AgentLibrary.Item) {
        do {
            try AgentLibrary.delete(item, hosts: hosts)
            loadLibrary()
            markPendingReload(item.kind == .skill)
            ToastCenter.shared.info("Deleted \(item.name)")
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't delete \(item.name)", detail: String(describing: error))
        }
    }

    /// Skills and prompts a host already had, which the library can take over.
    func unmanaged(_ kind: AgentLibrary.Kind) -> [(host: AgentHost, slugs: [String])] {
        hosts.compactMap { host in
            let slugs = AgentLibrary.unmanaged(kind, in: host)
            return slugs.isEmpty ? nil : (host, slugs)
        }
    }

    func adopt(kind: AgentLibrary.Kind, slug: String, from host: AgentHost) {
        do {
            try AgentLibrary.adopt(kind: kind, slug: slug, from: host, hosts: hosts)
            loadLibrary()
            ToastCenter.shared.info("Added \(slug) to your library", detail: "Now shareable with your other agents")
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't import \(slug)", detail: String(describing: error))
        }
    }

    func text(of item: AgentLibrary.Item) -> String {
        (try? String(contentsOfFile: item.contentPath, encoding: .utf8)) ?? ""
    }

    // MARK: - Hot swap

    /// Restarts running agents so new MCP servers, plugins, or skills load,
    /// resuming each conversation where it left off.
    func reloadAgents(confirm: Bool = true) {
        let reloadable = recovery.reloadableAgents()
        let blocked = recovery.unreloadableAgents()
        guard !reloadable.isEmpty else {
            let detail = blocked.isEmpty
                ? "Nothing is running that Herd can restart"
                : blocked.map { "\(AgentBrand.forAgent($0.agent.agent)?.displayName ?? "agent"): \($0.reason)" }.joined(separator: "\n")
            ToastCenter.shared.info("No agents to reload", detail: detail)
            pendingReload = false
            return
        }
        if confirm {
            let working = reloadable.filter { $0.agent.agentStatus == .working }.count
            let alert = NSAlert()
            alert.messageText = "Reload \(reloadable.count) running agent\(reloadable.count == 1 ? "" : "s")?"
            var lines = ["Each one restarts with --resume, so the conversation is kept."]
            if working > 0 { lines.append("\(working) \(working == 1 ? "is" : "are") working right now and will be interrupted.") }
            if !blocked.isEmpty { lines.append("Skipping \(blocked.count): \(blocked.map(\.reason).joined(separator: ", ")).") }
            alert.informativeText = lines.joined(separator: "\n")
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        pendingReload = false
        recovery.reload(reloadable)
    }

    private func markPendingReload(_ affectsAgents: Bool = true) {
        if affectsAgents, !recovery.reloadableAgents().isEmpty { pendingReload = true }
    }

    // MARK: - Filtering

    func filteredServers() -> [MarketplaceEntry] { filter(servers) { [$0.name, $0.detail] } }

    func filteredPlugins() -> [MarketplaceEntry] {
        MarketplaceCatalog.sorted(filter(plugins) { [$0.name, $0.summary, $0.marketplace] })
    }

    func filteredLibrary(_ kind: AgentLibrary.Kind) -> [AgentLibrary.Item] {
        filter(kind == .skill ? skills : prompts) { [$0.name, $0.summary, $0.slug] }
    }

    private func filter<T>(_ items: [T], fields: (T) -> [String]) -> [T] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            fields(item).contains { FuzzyMatcher.match(needle, in: $0) != nil }
        }
    }

    // MARK: - Running CLIs

    /// Runs commands in parallel and delivers their outputs in order.
    private func run(_ commands: [String], timeout: TimeInterval, completion: @escaping ([String]) -> Void) {
        guard !commands.isEmpty else {
            completion([])
            return
        }
        var outputs = [String?](repeating: nil, count: commands.count)
        var remaining = commands.count
        for (index, command) in commands.enumerated() {
            PluginCLI.runShell(command, timeout: timeout) { result in
                outputs[index] = result.output
                remaining -= 1
                if remaining == 0 { completion(outputs.map { $0 ?? "" }) }
            }
        }
    }

    private func perform(
        _ commands: [String],
        progress: String,
        success: String,
        failure: String,
        reloadAgents: Bool,
        then: @escaping () -> Void
    ) {
        guard !commands.isEmpty else { return }
        let toast = ToastCenter.shared.progress(progress)
        var failures: [String] = []
        var remaining = commands.count
        for command in commands {
            PluginCLI.runShell(command, timeout: 600) { [weak self] result in
                if result.exitCode != 0 { failures.append(PluginCLI.lastLines(result.output)) }
                remaining -= 1
                guard remaining == 0, let self else { return }
                if failures.isEmpty {
                    ToastCenter.shared.succeed(toast, success)
                    if reloadAgents { self.markPendingReload() }
                } else {
                    ToastCenter.shared.fail(toast, failure, detail: failures.prefix(2).joined(separator: "\n"))
                }
                then()
            }
        }
    }

    /// CLI output can carry banner lines before the JSON body.
    private static func jsonBody(_ output: String) -> String {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return output }
        return String(output[start...])
    }

    private static func cacheCatalog(outputs: [(String, String)]) {
        let payload = outputs.map { ["host": $0.0, "output": jsonBody($0.1)] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["fetchedAt": Date().timeIntervalSince1970, "hosts": payload]) else { return }
        try? FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: catalogURL, options: .atomic)
    }

    private static func loadCachedCatalog() -> (entries: [MarketplaceEntry], date: Date)? {
        guard let data = try? Data(contentsOf: catalogURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fetchedAt = object["fetchedAt"] as? TimeInterval,
              let hosts = object["hosts"] as? [[String: String]] else { return nil }
        let lists = hosts.map { entry in
            MarketplaceCatalog.plugins(json: Data((entry["output"] ?? "").utf8), hostId: entry["host"] ?? "")
        }
        return (MarketplaceCatalog.merge(lists), Date(timeIntervalSince1970: fetchedAt))
    }
}
