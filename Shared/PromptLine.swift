import Foundation

/// The command line Herd edits while a pane sits at a shell prompt: the text,
/// where the caret is, and every edit a shell's own line editor offers. Kept
/// free of AppKit so the editing rules can be tested directly.
struct PromptLine: Equatable {
    private(set) var text: String = ""
    /// Caret position as an offset in characters, 0...text.count.
    private(set) var caret: Int = 0
    /// Commands stepped through with the up arrow.
    private var historyCursor: Int?
    private var draftBeforeHistory: String?

    init(text: String = "", caret: Int? = nil) {
        self.text = text
        self.caret = caret ?? text.count
    }

    var isEmpty: Bool { text.isEmpty }
    var caretAtEnd: Bool { caret >= text.count }

    // MARK: - Editing

    mutating func insert(_ string: String) {
        let index = characterIndex(caret)
        text.insert(contentsOf: string, at: index)
        caret += string.count
        forgetHistory()
    }

    mutating func deleteBackward() {
        guard caret > 0 else { return }
        text.remove(at: characterIndex(caret - 1))
        caret -= 1
        forgetHistory()
    }

    mutating func deleteForward() {
        guard caret < text.count else { return }
        text.remove(at: characterIndex(caret))
        forgetHistory()
    }

    /// ⌥⌫ / ⌃W: remove the word before the caret, and the spaces it sits on.
    mutating func deleteWordBackward() {
        guard caret > 0 else { return }
        var index = caret
        while index > 0, character(at: index - 1) == " " { index -= 1 }
        while index > 0, character(at: index - 1) != " " { index -= 1 }
        text.removeSubrange(characterIndex(index)..<characterIndex(caret))
        caret = index
        forgetHistory()
    }

    /// ⌃U: clear to the start of the line.
    mutating func deleteToStart() {
        text.removeSubrange(text.startIndex..<characterIndex(caret))
        caret = 0
        forgetHistory()
    }

    /// ⌃K: clear to the end of the line.
    mutating func deleteToEnd() {
        text.removeSubrange(characterIndex(caret)..<text.endIndex)
        forgetHistory()
    }

    mutating func clear() {
        text = ""
        caret = 0
        forgetHistory()
    }

    // MARK: - Moving

    mutating func moveLeft() { caret = max(0, caret - 1) }
    mutating func moveRight() { caret = min(text.count, caret + 1) }
    mutating func moveToStart() { caret = 0 }
    mutating func moveToEnd() { caret = text.count }

    mutating func moveWordLeft() {
        var index = caret
        while index > 0, character(at: index - 1) == " " { index -= 1 }
        while index > 0, character(at: index - 1) != " " { index -= 1 }
        caret = index
    }

    mutating func moveWordRight() {
        var index = caret
        while index < text.count, character(at: index) == " " { index += 1 }
        while index < text.count, character(at: index) != " " { index += 1 }
        caret = index
    }

    // MARK: - History and suggestions

    /// Accepts the greyed-out completion, if the caret is at the end.
    mutating func accept(suggestion: String?) -> Bool {
        guard let suggestion, caretAtEnd, suggestion.hasPrefix(text), suggestion != text else { return false }
        text = suggestion
        caret = text.count
        forgetHistory()
        return true
    }

    /// Accepts one word of the completion, the way ⌥→ does in a shell.
    mutating func acceptWord(of suggestion: String?) -> Bool {
        guard let suggestion, caretAtEnd, suggestion.hasPrefix(text), suggestion != text else { return false }
        let rest = Array(suggestion)[text.count...]
        var taken = 0
        var seenWord = false
        for character in rest {
            if character == " " {
                // Take the space that ends the word too, so typing carries on
                // from the next one.
                if seenWord {
                    taken += 1
                    break
                }
            } else {
                seenWord = true
            }
            taken += 1
        }
        text = String(Array(suggestion)[0..<(text.count + taken)])
        caret = text.count
        forgetHistory()
        return true
    }

    /// ↑ / ↓ through the commands that match what has been typed so far.
    mutating func stepHistory(_ direction: Int, matches: [String]) {
        guard !matches.isEmpty else { return }
        if historyCursor == nil {
            guard direction > 0 else { return }
            draftBeforeHistory = text
            historyCursor = -1
        }
        let next = (historyCursor ?? -1) + direction
        if next < 0 {
            // Back past the newest entry: whatever was being typed returns.
            text = draftBeforeHistory ?? ""
            caret = text.count
            forgetHistory()
            return
        }
        let index = min(next, matches.count - 1)
        historyCursor = index
        text = matches[index]
        caret = text.count
    }

    /// True while the line is showing a history entry rather than typing.
    var isBrowsingHistory: Bool { historyCursor != nil }

    private mutating func forgetHistory() {
        historyCursor = nil
        draftBeforeHistory = nil
    }

    // MARK: - Helpers

    private func characterIndex(_ offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: min(max(offset, 0), text.count))
    }

    private func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < text.count else { return nil }
        return text[characterIndex(offset)]
    }
}
