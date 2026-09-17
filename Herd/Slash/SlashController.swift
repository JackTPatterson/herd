import AppKit
import Foundation

/// Herd's own `/` menu for agent panes. Typing `/` on an empty prompt is
/// caught before it reaches the terminal, so the agent's in-terminal list
/// never renders; picking a command types it into the pane instead.
@MainActor
final class SlashController: ObservableObject {
    @Published private(set) var commands: [SlashCommand] = []
    @Published var query = ""
    @Published var selection = 0
    /// The pane the menu is typing into; nil when closed.
    @Published private(set) var paneId: String?
    @Published private(set) var agentName = ""

    private unowned let store: HerdrStore
    /// Characters typed into each pane since its prompt was last submitted,
    /// so `/` only opens the menu at the start of an empty prompt.
    private var typed: [String: String] = [:]

    init(store: HerdrStore) {
        self.store = store
    }

    var isOpen: Bool { paneId != nil }

    var matches: [SlashCommand] {
        SlashCommands.matching(query, in: commands)
    }

    // MARK: - Key interception

    /// Called before the terminal sees a key. Returns true when Herd took it.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard SettingsStore.shared.values.slashMenu, !isOpen else { return false }
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }
        guard let pane = focusedAgentPane() else {
            typed.removeAll()
            return false
        }

        switch characters {
        case "\r", "\n", "\u{3}", "\u{1B}":
            typed[pane.paneId] = ""
            return false
        case "\u{7F}", "\u{8}":
            if var buffer = typed[pane.paneId], !buffer.isEmpty {
                buffer.removeLast()
                typed[pane.paneId] = buffer
            }
            return false
        case "/":
            guard (typed[pane.paneId] ?? "").isEmpty else { break }
            open(paneId: pane.paneId, agent: pane.agent)
            return true
        default:
            break
        }
        if characters.count == 1, characters.first.map({ $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isSymbol || $0 == " " }) == true {
            typed[pane.paneId, default: ""] += characters
        }
        return false
    }

    /// The focused pane, when an agent is running in it.
    private func focusedAgentPane() -> (paneId: String, agent: String?)? {
        let snapshot = store.snapshot
        let agents = snapshot.agents
        guard let agent = agents.first(where: { $0.paneId == snapshot.focusedPaneId })
            ?? agents.first(where: { $0.tabId == (store.displayedFocusedTabId ?? snapshot.focusedTabId) })
        else { return nil }
        return (agent.paneId, agent.agent)
    }

    // MARK: - Menu

    func open(paneId: String, agent: String?) {
        let snapshot = store.snapshot
        let cwd = snapshot.panes.first { $0.paneId == paneId }?.cwd
        commands = SlashCommands.all(agent: agent, cwd: cwd)
        agentName = AgentBrand.forAgent(agent)?.displayName ?? "the agent"
        query = ""
        selection = 0
        self.paneId = paneId
    }

    func close() {
        paneId = nil
        query = ""
        commands = []
    }

    func moveSelection(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    /// Types the highlighted command into the pane, leaving the cursor after
    /// it so arguments can follow. `submit` sends it right away.
    func choose(_ command: SlashCommand? = nil, submit: Bool = false) {
        guard let paneId else { return }
        let picked = command ?? (matches.indices.contains(selection) ? matches[selection] : nil)
        guard let picked else {
            cancel()
            return
        }
        send(text: picked.insertion + (submit ? "" : " "), to: paneId, submit: submit)
        close()
    }

    /// Escape: closes the menu and passes on what was typed, so nothing the
    /// user wrote is swallowed.
    func cancel() {
        guard let paneId else { return }
        let literal = "/" + query
        close()
        send(text: literal, to: paneId, submit: false)
    }

    private func send(text: String, to paneId: String, submit: Bool) {
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result {
                submit
                    ? try client.call("agent.prompt", ["target": paneId, "text": text])
                    : try client.call("pane.send_text", ["pane_id": paneId, "text": text])
            }
            DispatchQueue.main.async {
                if case .failure(let error) = outcome {
                    ToastCenter.shared.fail(nil, "Couldn't run that command", detail: String(describing: error))
                }
                HerdTerminalRuntime.focusTerminal()
            }
        }
    }

    /// Focus moved elsewhere: the pane's prompt state is unknown again.
    func resetTyping() {
        typed.removeAll()
    }
}
