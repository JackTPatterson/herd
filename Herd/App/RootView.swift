import SwiftUI

/// Window layout: Warp title bar, sidebar, tab bar, and the herdr terminal.
struct RootView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var ui: UIState
    let session: HerdrSession?
    @StateObject private var palette = PaletteModel()

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
        .overlay {
            if ui.paletteVisible {
                CommandPaletteView(model: palette) { closePalette() }
                    .transition(.opacity)
            }
        }
        .onChange(of: ui.paletteVisible) { _, visible in
            DebugSnapshot.overlayVisible = visible
            if visible {
                palette.reset()
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            } else {
                HerdTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: store.snapshot) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            }
        }
        .background(Theme.terminalBackground)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func closePalette() {
        ui.paletteVisible = false
    }

    @ViewBuilder
    private var terminal: some View {
        if let session {
            HerdTerminalView(
                command: session.command,
                environment: session.environment,
                workingDirectory: NSHomeDirectory(),
                hiddenTopRows: HerdrSession.hiddenTopRows,
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
    @Published var paletteVisible = false
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
            Button {
                ui.paletteVisible = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text(titleText).font(Theme.uiFontMedium).lineLimit(1)
                    Spacer(minLength: 8)
                    Keycap(text: "⌘P")
                }
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(width: 420, height: 26)
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
            .buttonStyle(.plain)
            .help("Command Palette (⌘P)")
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
