import AppKit
import SwiftUI

/// Browse and install MCP servers, plugins, skills and prompts for every
/// agent from one window, then reload running agents in place.
struct MarketplaceView: View {
    @ObservedObject var store: MarketplaceStore
    @State private var editing: LibraryDraft?
    @State private var addingServer = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.divider).frame(height: 1)
                content
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .background(Theme.chrome)
        .background(DarkTransparentTitleBar())
        .background(ThemedWindow(themeName: SettingsStore.shared.values.themeName))
        .preferredColorScheme(Theme.colorScheme)
        .onAppear {
            store.refreshAll()
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["HERD_MARKETPLACE_SECTION"],
               let section = MarketplaceStore.Section(rawValue: name) {
                store.section = section
            }
            #endif
        }
        .sheet(item: $editing) { draft in
            LibraryEditor(store: store, draft: draft) { editing = nil }
        }
        .sheet(isPresented: $addingServer) {
            ServerEditor(store: store) { addingServer = false }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MARKETPLACE")
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 30)
                .padding(.bottom, 6)
            ForEach(MarketplaceStore.Section.allCases) { section in
                SidebarRow(
                    title: section.title,
                    symbol: section.symbol,
                    count: count(of: section),
                    selected: store.section == section,
                    loading: store.loading.contains(section)
                ) { store.section = section }
            }
            Spacer()
            if !store.hosts.isEmpty {
                Text("AGENTS")
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(store.hosts) { host in
                    HStack(spacing: 6) {
                        if let brand = AgentBrand.forAgent(host.id) { AgentLogo(brand: brand, size: 12) }
                        Text(host.displayName)
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
                .padding(.bottom, 10)
            }
        }
        .frame(width: 190)
        .background(Theme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search \(store.section.title)", text: $store.query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
            if store.pendingReload {
                Button("Reload Agents") { store.reloadAgents() }
                    .controlSize(.small)
                    .help("Restart running agents with --resume so the new configuration loads")
            }
            Button {
                switch store.section {
                case .mcp: addingServer = true
                case .plugins: editing = LibraryDraft(kind: .prompt, marketplaceSource: true)
                case .skills: editing = LibraryDraft(kind: .skill)
                case .prompts: editing = LibraryDraft(kind: .prompt)
                }
            } label: {
                Label(addTitle, systemImage: "plus")
            }
            .controlSize(.small)
            if store.section == .prompts {
                Button("Import…") { importPrompts() }
                    .controlSize(.small)
                    .help("Copy a folder of .md prompts into your library")
            }
            Button {
                store.section == .plugins ? store.loadPlugins(force: true) : store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of .md prompts"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importPrompts(from: url, installIn: store.hosts)
    }

    private var addTitle: String {
        switch store.section {
        case .mcp: "Add Server"
        case .plugins: "Add Marketplace"
        case .skills: "New Skill"
        case .prompts: "New Prompt"
        }
    }

    private func count(of section: MarketplaceStore.Section) -> Int {
        switch section {
        case .mcp: store.servers.count
        case .plugins: store.plugins.filter(\.isInstalled).count
        case .skills: store.skills.count
        case .prompts: store.prompts.count
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                switch store.section {
                case .mcp:
                    ForEach(store.filteredServers()) { entry in
                        EntryRow(store: store, entry: entry)
                    }
                case .plugins:
                    ForEach(store.filteredPlugins().prefix(400)) { entry in
                        EntryRow(store: store, entry: entry)
                    }
                case .skills, .prompts:
                    let kind: AgentLibrary.Kind = store.section == .skills ? .skill : .prompt
                    ForEach(store.filteredLibrary(kind)) { item in
                        LibraryRow(store: store, item: item) {
                            editing = LibraryDraft(item: item, text: store.text(of: item))
                        }
                    }
                    ImportRow(store: store, kind: kind)
                }
            }
            .padding(10)
        }
        .background(Theme.terminalBackground)
    }
}

// MARK: - Rows

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    let loading: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(selected ? Theme.uiFontMedium : Theme.uiFont)
                Spacer(minLength: 4)
                if loading {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
                } else if count > 0 {
                    Text("\(count)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Theme.cardSelected : (hovered ? Theme.hover : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}

/// A plugin or MCP server, with a chip per agent showing where it is installed.
private struct EntryRow: View {
    @ObservedObject var store: MarketplaceStore
    let entry: MarketplaceEntry
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind == .mcp ? "point.3.connected.trianglepath.dotted" : "puzzlepiece.extension")
                .font(.system(size: 12))
                .foregroundStyle(entry.isInstalled ? Theme.accent : Theme.textTertiary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                    if !entry.version.isEmpty {
                        Text(entry.version).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if let count = entry.installCount, count > 0 {
                        Text("\(count) installs").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if !entry.marketplace.isEmpty {
                        Text(entry.marketplace).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                }
                if !entry.summary.isEmpty || !entry.detail.isEmpty {
                    Text(entry.summary.isEmpty ? entry.detail : entry.summary)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(store.hosts) { host in
                        HostChip(
                            host: host,
                            installed: entry.installedIn.contains(host.id),
                            enabled: entry.enabledIn.contains(host.id),
                            status: entry.status[host.id]
                        ) {
                            toggle(host)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            if entry.isInstalled {
                Button("Remove") {
                    store.remove(entry, from: store.hosts.filter { entry.installedIn.contains($0.id) })
                }
                .controlSize(.small)
                .opacity(hovered ? 1 : 0.5)
            }
        }
        .padding(10)
        .background(hovered ? Theme.hover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }

    private func toggle(_ host: AgentHost) {
        if entry.installedIn.contains(host.id) {
            store.remove(entry, from: [host])
        } else {
            store.add(entry, to: [host])
        }
    }
}

/// One agent's install state for an item; click to add or remove it there.
private struct HostChip: View {
    let host: AgentHost
    let installed: Bool
    var enabled = true
    var status: String?
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                if let brand = AgentBrand.forAgent(host.id) {
                    AgentLogo(brand: brand, size: 10)
                } else {
                    Image(systemName: "terminal").font(.system(size: 9))
                }
                Text(host.displayName)
                    .font(Theme.captionFont)
                if let status, status.contains("✘") || status == "disabled" {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(installed ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                let tint = AgentBrand.forAgent(host.id)?.hueHex.map { Color(hex: $0) } ?? Theme.accent
                RoundedRectangle(cornerRadius: 10)
                    .fill(installed ? tint.opacity(enabled ? 0.22 : 0.1) : Color.clear)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(installed ? tint.opacity(0.5) : Theme.border, lineWidth: 1)
            }
            .opacity(hovered ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(status ?? (installed ? "Installed in \(host.displayName)" : "Add to \(host.displayName)"))
    }
}

private struct LibraryRow: View {
    @ObservedObject var store: MarketplaceStore
    let item: AgentLibrary.Item
    let edit: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind == .skill ? "graduationcap" : "text.bubble")
                .font(.system(size: 12))
                .foregroundStyle(item.installedIn.isEmpty ? Theme.textTertiary : Theme.accent)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(store.hosts) { host in
                        HostChip(host: host, installed: item.installedIn.contains(host.id)) {
                            store.setLibraryInstalled(item, host: host, installed: !item.installedIn.contains(host.id))
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if item.kind == .prompt, let agent = store.promptTarget {
                    Button("Run") { store.runPrompt(item) }
                        .controlSize(.small)
                        .help("Send this prompt to \(AgentBrand.forAgent(agent.agent)?.displayName ?? "the focused agent")")
                }
                Button("Edit", action: edit).controlSize(.small)
                Button("Delete") { store.deleteLibraryItem(item) }.controlSize(.small)
            }
            .opacity(hovered ? 1 : 0.5)
        }
        .padding(10)
        .background(hovered ? Theme.hover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

/// Offers to pull an agent's own skills and prompts into the shared library.
private struct ImportRow: View {
    @ObservedObject var store: MarketplaceStore
    let kind: AgentLibrary.Kind

    var body: some View {
        let groups = store.unmanaged(kind)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("In your agents but not in the library")
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(groups, id: \.host.id) { group in
                    ForEach(group.slugs, id: \.self) { slug in
                        HStack(spacing: 8) {
                            Text(slug).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                            Text(group.host.displayName).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button("Add to Library") { store.adopt(kind: kind, slug: slug, from: group.host) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .background(Theme.card.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Editors

struct LibraryDraft: Identifiable {
    let id = UUID()
    var kind: AgentLibrary.Kind
    var slug = ""
    var text = ""
    var hosts: Set<String> = []
    var isNew = true
    /// Reuses the sheet to add a plugin marketplace instead.
    var marketplaceSource = false

    init(kind: AgentLibrary.Kind, marketplaceSource: Bool = false) {
        self.kind = kind
        self.marketplaceSource = marketplaceSource
        text = kind == .skill
            ? "---\nname: my-skill\ndescription: What this skill is for, and when to use it\n---\n\n# My Skill\n\nSteps the agent should follow.\n"
            : "---\ndescription: What this prompt does\n---\n\nWrite the prompt here.\n"
    }

    init(item: AgentLibrary.Item, text: String) {
        kind = item.kind
        slug = item.slug
        self.text = text
        hosts = item.installedIn
        isNew = false
    }
}

private struct LibraryEditor: View {
    @ObservedObject var store: MarketplaceStore
    @State var draft: LibraryDraft
    let close: () -> Void
    @State private var source = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            if draft.marketplaceSource {
                Text("A GitHub repo, URL, or local path holding a plugin marketplace.")
                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                TextField("owner/repo", text: $source)
                    .textFieldStyle(.roundedBorder)
                hostPicker
            } else {
                TextField("name", text: $draft.slug)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!draft.isNew)
                TextEditor(text: $draft.text)
                    .font(Theme.monoFont)
                    .frame(minHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
                hostPicker
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.marketplaceSource ? source.isEmpty : draft.slug.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(Theme.chrome)
    }

    private var title: String {
        if draft.marketplaceSource { return "Add a plugin marketplace" }
        let noun = draft.kind == .skill ? "skill" : "prompt"
        return draft.isNew ? "New \(noun)" : "Edit \(draft.slug)"
    }

    private var hostPicker: some View {
        HStack(spacing: 8) {
            Text("Install in").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            ForEach(store.hosts) { host in
                HostChip(host: host, installed: draft.hosts.contains(host.id)) {
                    if draft.hosts.contains(host.id) { draft.hosts.remove(host.id) } else { draft.hosts.insert(host.id) }
                }
            }
        }
    }

    private func save() {
        let hosts = store.hosts.filter { draft.hosts.contains($0.id) }
        if draft.marketplaceSource {
            store.addMarketplace(source.trimmingCharacters(in: .whitespaces), to: hosts.isEmpty ? store.hosts : hosts)
            close()
            return
        }
        let slug = draft.slug.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        if store.saveLibraryItem(kind: draft.kind, slug: slug, text: draft.text, installIn: hosts) {
            // Links for hosts that were unchecked are removed too.
            if let item = (draft.kind == .skill ? store.skills : store.prompts).first(where: { $0.slug == slug }) {
                for host in store.hosts where !draft.hosts.contains(host.id) && item.installedIn.contains(host.id) {
                    store.setLibraryInstalled(item, host: host, installed: false)
                }
            }
            close()
        }
    }
}

private struct ServerEditor: View {
    @ObservedObject var store: MarketplaceStore
    let close: () -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var hosts: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an MCP server").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text("A command to run, or an HTTP URL. Herd adds it in each agent's own syntax.")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            TextField("name", text: $name).textFieldStyle(.roundedBorder)
            TextField("npx -y @acme/mcp-server  ·  https://mcp.example.com/mcp", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(Theme.monoFont)
            HStack(spacing: 8) {
                Text("Add to").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                ForEach(store.hosts) { host in
                    HostChip(host: host, installed: hosts.contains(host.id)) {
                        if hosts.contains(host.id) { hosts.remove(host.id) } else { hosts.insert(host.id) }
                    }
                }
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    let targets = store.hosts.filter { hosts.contains($0.id) }
                    store.addServer(name: name.trimmingCharacters(in: .whitespaces),
                                    command: command,
                                    into: targets.isEmpty ? store.hosts : targets)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(Theme.chrome)
        .onAppear { hosts = Set(store.hosts.map(\.id)) }
    }
}
