import SwiftUI

@main
struct HerdApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: HerdrStore
    @StateObject private var ui = UIState()
    private let session: HerdrSession?

    init() {
        let session = HerdrSession.make()
        session?.writeManagedConfig()
        self.session = session
        let socketPath = session?.socketPath ?? HerdrClient.socketPath(session: HerdrSession.name)
        _store = StateObject(wrappedValue: HerdrStore(client: HerdrClient(socketPath: socketPath)))
        HerdTerminalRuntime.configure(overrides: Theme.ghosttyConfig)
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store, ui: ui, session: session)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    store.start()
                    DebugSnapshot.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { HerdCommands(store: store, ui: ui) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct HerdCommands: Commands {
    let store: HerdrStore
    let ui: UIState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Workspace") { store.newWorkspace() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open Folder as Workspace…") { PaletteCatalog.openFolder(store: store) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Close Tab") { store.closeFocusedTab() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(after: .appSettings) {
            Button("Install Claude Subagent Tabs Hook") { ClaudeHookMenu.install() }
            Button("Remove Claude Subagent Tabs Hook") { ClaudeHookMenu.uninstall() }
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette") { ui.paletteVisible.toggle() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Command Palette ") { ui.paletteVisible.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Toggle Sidebar") { ui.sidebarVisible.toggle() }
                .keyboardShortcut("b", modifiers: .command)
        }
        CommandMenu("Pane") {
            Button("Split Right") { store.splitPane(.right) }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { store.splitPane(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Toggle Zoom") { store.toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Close Pane") { store.closeFocusedPane() }
            Divider()
            Button("Focus Left") { store.focusPane(.left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Focus Right") { store.focusPane(.right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Focus Up") { store.focusPane(.up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Focus Down") { store.focusPane(.down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
        CommandMenu("Navigate") {
            Button("Next Tab") { store.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Button("Next Workspace") { store.selectAdjacentWorkspace(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Previous Workspace") { store.selectAdjacentWorkspace(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Divider()
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Last Tab" : "Tab \(number)") { store.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}

/// Menu actions for the Claude Code hook that opens subagent tabs.
enum ClaudeHookMenu {
    @MainActor
    static func install() {
        let toasts = ToastCenter.shared
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "herd-cli")?.path else {
            toasts.fail(nil, "Couldn't install the subagent tabs hook", detail: "herd-cli is missing from the app bundle")
            return
        }
        let handle = toasts.progress("Installing the Claude subagent tabs hook…")
        do {
            let changed = try ClaudeHookInstaller.install(cliPath: cli)
            toasts.succeed(handle, changed ? "Installed the subagent tabs hook" : "Subagent tabs hook already installed",
                           detail: "New Claude Code sessions in Herd open a tab per subagent")
        } catch {
            toasts.fail(handle, "Couldn't update ~/.claude/settings.json", detail: String(describing: error))
        }
    }

    @MainActor
    static func uninstall() {
        let toasts = ToastCenter.shared
        let handle = toasts.progress("Removing the Claude subagent tabs hook…")
        do {
            let changed = try ClaudeHookInstaller.uninstall()
            toasts.succeed(handle, changed ? "Removed the subagent tabs hook" : "Subagent tabs hook was not installed")
        } catch {
            toasts.fail(handle, "Couldn't update ~/.claude/settings.json", detail: String(describing: error))
        }
    }
}
