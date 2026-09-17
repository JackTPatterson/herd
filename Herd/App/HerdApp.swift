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
                .onAppear { store.start() }
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
            Divider()
            Button("Close Tab") { store.closeFocusedTab() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { ui.sidebarVisible.toggle() }
                .keyboardShortcut("b", modifiers: .command)
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
