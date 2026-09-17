import Foundation

/// Keeps a tab's name on the work happening in it. Agents and shells alike
/// publish what they are doing as the terminal title, so Herd follows that
/// rather than guessing, for every agent equally: switch task inside a
/// workspace and the tab follows, while a name you typed is never
/// overwritten.
enum TabAutoName {
    static let maxLength = 26
    /// A title has to hold still before a rename, so tabs don't flicker.
    static let settleAfter: TimeInterval = 2.5

    /// Titles that say nothing about the work.
    static let uninformative: Set<String> = [
        "zsh", "bash", "fish", "sh", "login", "terminal", "claude", "codex",
        "node", "python", "herdr", "tmux", "vim", "nvim", "ssh", "git",
    ]

    /// Cleans a pane's terminal title into a tab label, or nil when the
    /// title says nothing worth showing.
    static func label(from title: String?, cwd: String? = nil) -> String? {
        guard let title else { return nil }
        // Agents prefix their title with a status glyph while they work.
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip the glyph, but never a leading path separator: a title that
        // is just a folder is not a description of the work.
        while let first = text.first, !first.isLetter, !first.isNumber, first != "/", first != "~" {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Some shells title the pane "user@host: ~/path" — that's the folder,
        // which the workspace already shows.
        if let colon = text.firstIndex(of: ":"), text[..<colon].contains("@") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty, !uninformative.contains(text.lowercased()) else { return nil }
        // A bare path is the folder, not the task.
        if text.hasPrefix("/") || text.hasPrefix("~") { return nil }
        if let cwd, text == (cwd as NSString).lastPathComponent { return nil }
        return truncate(text)
    }

    /// Cuts at a word boundary so labels read as phrases, not fragments.
    static func truncate(_ text: String, limit: Int = maxLength) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) > limit / 2 {
            return String(clipped[..<space]) + "…"
        }
        return clipped + "…"
    }

    /// One tab's proposed name, and when its title was first seen.
    struct Candidate: Equatable {
        let tabId: String
        let label: String
        var since: Date
    }

    /// Works out which tabs should be renamed. `manual` holds tabs the user
    /// named; `pending` carries the last round's candidates so a title has to
    /// hold still for `settleAfter` before anything is renamed.
    static func renames(
        snapshot: HerdrSnapshot,
        manual: Set<String>,
        pending: inout [String: Candidate],
        now: Date = Date()
    ) -> [(tabId: String, label: String)] {
        var renames: [(String, String)] = []
        var next: [String: Candidate] = [:]
        for tab in snapshot.tabs where !manual.contains(tab.tabId) {
            let panes = snapshot.panes.filter { $0.tabId == tab.tabId }
            // Split tabs have no single subject; leave their names alone.
            guard panes.count == 1, let pane = panes.first,
                  let label = label(from: pane.terminalTitle, cwd: pane.effectiveCwd),
                  label != tab.label else { continue }
            let candidate = pending[tab.tabId].map { $0.label == label ? $0 : Candidate(tabId: tab.tabId, label: label, since: now) }
                ?? Candidate(tabId: tab.tabId, label: label, since: now)
            next[tab.tabId] = candidate
            if now.timeIntervalSince(candidate.since) >= settleAfter {
                renames.append((tab.tabId, label))
                next[tab.tabId] = nil
            }
        }
        pending = next
        return renames
    }
}
