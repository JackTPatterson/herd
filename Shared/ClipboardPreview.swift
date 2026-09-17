import Foundation

/// One line describing what was copied, for the clipboard toast.
enum ClipboardPreview {
    static func summary(_ text: String, limit: Int = 64) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var preview = first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
        let more = lines.count - 1
        if more > 0 {
            if preview.isEmpty {
                preview = "\(lines.count) lines"
            } else {
                preview += " · +\(more) line\(more == 1 ? "" : "s")"
            }
        }
        return preview
    }
}
