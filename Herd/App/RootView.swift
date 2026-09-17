import SwiftUI

/// Window layout: Warp title bar, sidebar, tab bar, and the herdr terminal.
struct RootView: View {
    @ObservedObject var store: HerdrStore
    @ObservedObject var ui: UIState
    let session: HerdrSession?
    @StateObject private var palette = PaletteModel()
    @ObservedObject private var motion = MotionPreferences.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Chrome views are re-identified per theme so every color
            // re-resolves; the terminal keeps its identity (and herdr client).
            TitleBar(store: store, ui: ui)
                .id(settings.values.themeName)
            HStack(spacing: 0) {
                if ui.sidebarVisible {
                    HStack(spacing: 0) {
                        SidebarView(store: store)
                        Rectangle().fill(Theme.divider).frame(width: 1)
                    }
                    .id(settings.values.themeName)
                    .transition(motion.animates(.sidebar) ? .move(edge: .leading) : .identity)
                }
                VStack(spacing: 0) {
                    TabBarView(store: store)
                        .id(settings.values.themeName)
                    terminal
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Toasts sit above the recovery panel, both anchored bottom-right.
            VStack(alignment: .trailing, spacing: 8) {
                ToastStack(center: ToastCenter.shared)
                RecoveryOverlay(recovery: store.recovery)
            }
            .id(settings.values.themeName)
        }
        .onChange(of: store.lastError) { _, error in
            guard let error else { return }
            ToastCenter.shared.fail(nil, "herdr request failed", detail: error)
            store.lastError = nil
        }
        .overlay {
            if ui.paletteVisible {
                CommandPaletteView(model: palette) { closePalette() }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: ui.paletteVisible)
        .animation(motion.animation(.sidebar), value: ui.sidebarVisible)
        .onChange(of: ui.paletteVisible) { _, visible in
            DebugSnapshot.overlayVisible = visible
            if visible {
                store.refreshPlugins()
                palette.reset()
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            } else {
                HerdTerminalRuntime.focusTerminal()
            }
        }
        .onChange(of: store.plugins) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            }
        }
        .onChange(of: store.snapshot) { _, _ in
            if ui.paletteVisible, palette.prompt == nil {
                palette.reload(items: PaletteCatalog.items(store: store, ui: ui))
            }
        }
        .background(settings.values.backgroundOpacity < 1 ? Color.clear : Theme.terminalBackground)
        .background(WindowTransparency(
            opacity: settings.values.backgroundOpacity,
            blur: settings.values.backgroundBlur,
            themeName: settings.values.themeName
        ))
        .ignoresSafeArea()
        .preferredColorScheme(Theme.colorScheme)
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
            .background(Color(hex: TerminalTheme.named(settings.values.themeName).background)
                .opacity(settings.values.backgroundOpacity))
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

/// Makes the window see-through when the terminal background is translucent,
/// and applies Ghostty's background blur.
private struct WindowTransparency: NSViewRepresentable {
    let opacity: Double
    let blur: Bool
    let themeName: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let translucent = opacity < 1
            window.isOpaque = !translucent
            window.backgroundColor = translucent ? .clear : Theme.palette.nsColor(\.background)
            window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
            HerdTerminalRuntime.applyBackgroundBlur(to: window)
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

/// Shows the recovery panel under the title bar while sessions are offered.
private struct RecoveryOverlay: View {
    @ObservedObject var recovery: AgentRecoveryController
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            if !recovery.offered.isEmpty {
                RecoveryPanel(recovery: recovery)
                    .padding([.trailing, .bottom], 12)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .move(edge: .bottom))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.18)), value: recovery.offered.isEmpty)
        .onChange(of: recovery.offered.isEmpty) { _, empty in
            DebugSnapshot.overlayVisible = !empty
        }
    }
}
