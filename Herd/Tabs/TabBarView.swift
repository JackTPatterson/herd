import SwiftUI

/// Warp-style horizontal tabs for the focused workspace's herdr tabs. Tabs
/// that run an agent show its state glyph and vendor mark; subagent viewer
/// tabs are named after the subagent.
struct TabBarView: View {
    @ObservedObject var store: HerdrStore

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.focusedWorkspaceTabs) { tab in
                        TabItem(store: store, tab: tab)
                    }
                }
            }
            NewTabButton { store.newTab() }
            Spacer(minLength: 0)
        }
        .frame(height: Theme.tabBarHeight)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }
}

private struct TabItem: View {
    @ObservedObject var store: HerdrStore
    let tab: HerdrTab
    @State private var hovered = false

    var body: some View {
        let isActive = tab.tabId == store.snapshot.focusedTabId || (store.snapshot.focusedTabId == nil && tab.focused)
        let agent = store.primaryAgent(in: store.snapshot.agents(inTab: tab.tabId))
        let brand = AgentBrand.forAgent(agent?.agent)

        HStack(spacing: 6) {
            if let agent {
                AgentStateGlyph(status: agent.agentStatus, size: 9)
                    .frame(width: 10)
            }
            if let brand {
                AgentLogo(brand: brand, size: 11)
            }
            Text(tab.label.isEmpty ? "\(tab.number)" : tab.label)
                .font(isActive ? Theme.uiFontMedium : Theme.uiFont)
                .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                store.closeTab(tab.tabId)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .background(hovered ? Theme.cardSelected : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .opacity(hovered || isActive ? 1 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(minWidth: 120, maxWidth: 220, maxHeight: .infinity)
        .background(
            ZStack {
                isActive ? Theme.terminalBackground : (hovered ? Theme.hover : Theme.chrome)
                if let hue = brand?.hueHex {
                    Color(hex: hue).opacity(isActive ? 0.08 : Theme.tabColorOpacity)
                }
            }
        )
        .overlay(alignment: .top) {
            if isActive {
                Rectangle().fill(brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.divider).frame(width: 1) }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { store.focusTab(tab.tabId) }
        .contextMenu {
            Button("Close Tab") { store.closeTab(tab.tabId) }
        }
        .help(tab.label)
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 24)
                .background(hovered ? Theme.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 4)
        .help("New Tab (⌘T)")
    }
}
