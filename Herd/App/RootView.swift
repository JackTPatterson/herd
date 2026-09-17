import SwiftUI

/// Window layout: Warp title bar, sidebar, tab bar, and the herdr terminal.
struct RootView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var ui: UIState
    let session: HerdrSession?

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(store: store, ui: ui)
            HStack(spacing: 0) {
                if ui.sidebarVisible {
                    SidebarView(store: store)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                }
                VStack(spacing: 0) {
                    TabBarView(store: store)
                    terminal
                }
            }
        }
        .background(Theme.terminalBackground)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var terminal: some View {
        if let session {
            HerdTerminalView(
                command: session.command,
                environment: session.environment,
                workingDirectory: NSHomeDirectory(),
                onTitleChange: { _ in },
                onExit: { NSApp.terminate(nil) }
            )
            .background(Theme.terminalBackground)
        } else {
            VStack(spacing: 8) {
                Text("herdr not found").font(.system(size: 14, weight: .semibold))
                Text("Install it with `brew install herdr`, then relaunch Herd.")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
        }
    }
}

final class UIState: ObservableObject {
    @Published var sidebarVisible = true
}

private struct TitleBar: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var ui: UIState

    var body: some View {
        HStack(spacing: 8) {
            // Room for the traffic lights.
            Color.clear.frame(width: 70)
            Button {
                ui.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(ui.sidebarVisible ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 28, height: 24)
                    .background(ui.sidebarVisible ? Theme.cardSelected : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
            .buttonStyle(.plain)
            .help("Toggle Sidebar (⌘B)")
            Spacer()
            Text(titleText)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
            connectionIndicator
                .padding(.trailing, 12)
        }
        .frame(height: Theme.titleBarHeight)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private var titleText: String {
        guard let workspace = store.focusedWorkspace else { return "Herd" }
        let tab = store.focusedWorkspaceTabs.first { $0.tabId == store.snapshot.focusedTabId }
        return [workspace.label, tab?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var connectionIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(store.isConnected ? Color(hex: AgentStateColor.done) : Theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(store.isConnected ? "herdr" : "connecting")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
