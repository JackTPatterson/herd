import SwiftUI

/// Warp-style vertical tabs: project groups with uppercase headers and
/// bordered workspace cards tinted by the running agent's vendor hue.
struct SidebarView: View {
    @ObservedObject var store: HerdrStore
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().overlay(Theme.divider)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.groups) { group in
                        groupSection(group)
                    }
                    if store.groups.isEmpty {
                        Text(store.isConnected ? "No workspaces" : "Starting herdr…")
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebar)
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            ControlButton(title: "New workspace", systemImage: "plus", shortcut: "⌘N") {
                store.newWorkspace()
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func groupSection(_ group: ProjectGroup) -> some View {
        let collapsed = collapsedGroups.contains(group.id)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if collapsed { collapsedGroups.remove(group.id) } else { collapsedGroups.insert(group.id) }
            } label: {
                HStack(spacing: 4) {
                    Text(group.name.uppercased())
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(group.workspaces.count == 1 ? "1 space" : "\(group.workspaces.count) spaces")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            if !collapsed {
                ForEach(group.workspaces) { workspace in
                    WorkspaceCard(store: store, workspace: workspace)
                        .padding(.horizontal, 8)
                }
            }
        }
    }
}

private struct WorkspaceCard: View {
    @ObservedObject var store: HerdrStore
    let workspace: HerdrWorkspace
    @State private var hovered = false

    var body: some View {
        let snapshot = store.snapshot
        let isSelected = workspace.workspaceId == store.focusedWorkspace?.workspaceId
        let agents = snapshot.agents(inWorkspace: workspace.workspaceId)
        let agent = store.primaryAgent(in: agents)
        let brand = AgentBrand.forAgent(agent?.agent)
        let directory = snapshot.directory(ofWorkspace: workspace.workspaceId)
        let branch = store.branches[workspace.workspaceId]

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                AgentStateGlyph(status: agent?.agentStatus ?? workspace.agentStatus)
                    .frame(width: 12)
                Text(workspace.label)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let branch {
                    Text("•").foregroundStyle(Theme.textTertiary)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textSecondary)
                    Text(branch)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let directory {
                Text(abbreviateHome(directory))
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 5) {
                if let brand {
                    AgentLogo(brand: brand, size: 11)
                    Text(agentLine(agent: agent, brand: brand, count: agents.count))
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textTertiary)
                    Text(workspace.tabCount == 1 ? "Terminal" : "\(workspace.tabCount) tabs")
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(isSelected: isSelected, hue: brand?.hueHex))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius)
                .strokeBorder(isSelected ? Theme.border.opacity(1.6) : Theme.border.opacity(hovered ? 1 : 0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.focusWorkspace(workspace.workspaceId) }
        .contextMenu {
            Button("Close Workspace") { store.closeWorkspace(workspace.workspaceId) }
        }
    }

    private func cardBackground(isSelected: Bool, hue: String?) -> some View {
        ZStack {
            (isSelected ? Theme.cardSelected : (hovered ? Theme.hover : Theme.card))
            if let hue {
                Color(hex: hue).opacity(hovered ? Theme.tabColorOpacity * 1.6 : Theme.tabColorOpacity)
            }
        }
    }

    private func agentLine(agent: HerdrAgent?, brand: AgentBrand, count: Int) -> String {
        let status = agent.map { stateLabel($0.agentStatus) } ?? ""
        let extra = count > 1 ? " · \(count) agents" : ""
        return "\(brand.displayName) \(status)\(extra)"
    }
}

func stateLabel(_ status: HerdrAgentStatus) -> String {
    switch status {
    case .working: return "working"
    case .blocked: return "needs input"
    case .done: return "done"
    case .idle: return "idle"
    case .unknown: return ""
    }
}

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

struct ControlButton: View {
    let title: String
    let systemImage: String
    var shortcut: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                Text(title).font(Theme.uiFontMedium)
                if let shortcut {
                    Text(shortcut).font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(hovered ? Theme.hover : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
