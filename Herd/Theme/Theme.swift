import AppKit
import SwiftUI

/// Warp's default Dark theme and vertical-tab metrics.
///
/// Colors: `app/src/themes/default_themes.rs` `dark_theme()` (background
/// #050505, foreground #ffffff, accent #19AAD8) and its ANSI table. Metrics:
/// `app/src/workspace/view/vertical_tabs.rs` (248pt panel, 4pt row radius,
/// tab colors at 15% opacity, 50% on hover).
enum Theme {
    static let terminalBackground = Color(hex: "#050505")
    static let chrome = Color(hex: "#111111")
    static let sidebar = Color(hex: "#141414")
    static let card = Color(hex: "#1B1B1B")
    static let cardSelected = Color(hex: "#262626")
    static let hover = Color(hex: "#1F1F1F")
    static let border = Color(hex: "#2A2A2A")
    static let divider = Color(hex: "#1F1F1F")
    static let textPrimary = Color(hex: "#F1F1F1")
    static let textSecondary = Color(hex: "#9E9E9E")
    static let textTertiary = Color(hex: "#6B6B6B")
    static let accent = Color(hex: "#19AAD8")

    static let sidebarWidth: CGFloat = 248
    static let rowRadius: CGFloat = 4
    static let titleBarHeight: CGFloat = 38
    static let tabBarHeight: CGFloat = 34
    static let tabColorOpacity = 0.15
    static let tabColorHoverOpacity = 0.5

    static let uiFont = Font.system(size: 12)
    static let uiFontMedium = Font.system(size: 12, weight: .medium)
    static let headerFont = Font.system(size: 10.5, weight: .semibold)
    static let monoFont = Font.system(size: 11.5, design: .monospaced)

    /// libghostty config for the terminal, matching Warp Dark's ANSI palette.
    static let ghosttyConfig = """
    background = 050505
    foreground = f1f1f1
    cursor-color = 19aad8
    selection-background = 2a4a5a
    font-size = 13
    window-padding-x = 10
    window-padding-y = 0,6
    palette = 0=#616161
    palette = 1=#ff8272
    palette = 2=#b4fa72
    palette = 3=#fefdc2
    palette = 4=#a5d5fe
    palette = 5=#ff8ffd
    palette = 6=#d0d1fe
    palette = 7=#f1f1f1
    palette = 8=#8e8e8e
    palette = 9=#ffc4bd
    palette = 10=#d6fcb9
    palette = 11=#fefdd5
    palette = 12=#c1e3fe
    palette = 13=#ffb1fe
    palette = 14=#e5e6fe
    palette = 15=#feffff
    """ + "\n" + herdShortcutUnbinds

    /// Shortcuts Herd's menus own; unbound in Ghostty so the surface lets them through.
    static let herdShortcutUnbinds = [
        "super+t",
        "super+w",
        "super+n",
        "super+b",
        "super+shift+left_bracket",
        "super+shift+right_bracket",
        "ctrl+super+up",
        "ctrl+super+down",
        "super+shift+w",
        "super+shift+t",
        "super+digit_1",
        "super+digit_2",
        "super+digit_3",
        "super+digit_4",
        "super+digit_5",
        "super+digit_6",
        "super+digit_7",
        "super+digit_8",
        "super+digit_9",
    ].map { "keybind = \($0)=unbind" }.joined(separator: "\n")
}

extension Color {
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex) ?? .gray)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
