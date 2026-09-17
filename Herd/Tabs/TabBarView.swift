import SwiftUI

/// Warp-style horizontal tabs for the focused workspace's herdr tabs. Tabs
/// that run an agent show its state glyph and vendor mark; subagent viewer
/// tabs are named after the subagent.
struct TabBarView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject private var motion = MotionPreferences.shared
    @Namespace private var selection

    /// One spring for every tab change so moves, opens, and closes stay in step.
    static let spring = Animation.spring(response: 0.26, dampingFraction: 0.88)

    var body: some View {
        let tabs = store.displayedTabs
        let focusedId = store.displayedFocusedTabId

        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs) { tab in
                            TabItem(store: store, tab: tab, isActive: tab.tabId == focusedId, selection: selection)
                                .id(tab.tabId)
                                .transition(motion.animates(.tabs) ? .tabCollapse : .identity)
                        }
                    }
                    .animation(motion.animation(.tabs, Self.spring), value: tabs.map(\.tabId))
                    .animation(motion.animation(.tabs, Self.spring), value: focusedId)
                }
                .onChange(of: focusedId) { _, id in
                    guard let id else { return }
                    motion.perform(.tabs, Self.spring) { proxy.scrollTo(id) }
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
    let isActive: Bool
    let selection: Namespace.ID
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    var body: some View {
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
            Text(TabAutoName.display(label: tab.label, number: tab.number))
                .font(Theme.uiFont)
                .fontWeight(isActive ? .medium : .regular)
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
        .background {
            ZStack {
                if hovered && !isActive { Theme.hover }
                if let hue = brand?.hueHex, !isActive {
                    Color(hex: hue).opacity(Theme.tabColorOpacity)
                }
                // A single selection surface slides between tabs.
                if isActive {
                    ZStack(alignment: .top) {
                        Theme.terminalBackground
                        if let hue = brand?.hueHex { Color(hex: hue).opacity(0.08) }
                        Rectangle()
                            .fill(brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent)
                            .frame(height: 2)
                    }
                    .matchedGeometryEffect(id: "selectedTab", in: selection)
                }
            }
            .animation(motion.animation(.tabs, .easeOut(duration: 0.12)), value: hovered)
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

/// Opening a tab grows it from zero width and closing shrinks it away, so
/// neighbors glide instead of jumping.
private struct WidthCollapse: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)) ?? .zero
        return CGSize(width: ideal.width * progress, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let ideal = child.sizeThatFits(ProposedViewSize(width: nil, height: bounds.height))
        child.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: ideal.width, height: bounds.height))
    }
}

private struct TabCollapseModifier: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        WidthCollapse(progress: progress) {
            content.opacity(progress)
        }
        .clipped()
    }
}

private extension AnyTransition {
    static var tabCollapse: AnyTransition {
        .modifier(active: TabCollapseModifier(progress: 0), identity: TabCollapseModifier(progress: 1))
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
