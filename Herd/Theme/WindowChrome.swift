import AppKit
import SwiftUI

/// Makes the hosting window's title bar transparent and dark so the
/// sidebar runs to the top edge, like the main window.
struct DarkTransparentTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = Theme.palette.nsColor(\.background)
            window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps the window's background and appearance in step with the theme.
struct ThemedWindow: NSViewRepresentable {
    let themeName: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.backgroundColor = Theme.palette.nsColor(\.background)
            window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
        }
    }
}
