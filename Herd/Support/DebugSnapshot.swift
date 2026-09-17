// Verification helper: when HERD_SNAPSHOT_DIR is set, writes window.png (the
// SwiftUI chrome with the terminal's rendered IOSurface composited in place)
// and terminal.txt (visible terminal text) every second. Self-capture needs no
// Screen Recording permission. Adapted from Spikes/TerminalSpike.
import AppKit
import CoreImage
import GhosttyKit
import IOSurface

@MainActor
enum DebugSnapshot {
    /// Set while a SwiftUI overlay covers the terminal, so the terminal image
    /// isn't composited over it.
    static var overlayVisible = false
    static func start() {
        guard let dir = ProcessInfo.processInfo.environment["HERD_SNAPSHOT_DIR"] else { return }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { dump(to: dir) }
        }
    }

    private static func findSurface(in view: NSView) -> Ghostty.SurfaceView? {
        if let surface = view as? Ghostty.SurfaceView { return surface }
        for sub in view.subviews { if let surface = findSurface(in: sub) { return surface } }
        return nil
    }

    private static func dump(to dir: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let chrome = NSImage(size: content.bounds.size)
        chrome.addRepresentation(rep)

        let composed = NSImage(size: content.bounds.size)
        composed.lockFocus()
        chrome.draw(in: content.bounds)
        var info = "window=\(window.frame) key=\(window.isKeyWindow)\n"
        if let surfaceView = findSurface(in: content) {
            let frame = surfaceView.convert(surfaceView.bounds, to: content)
            if let clip = surfaceView.superview as? TopRowClippingView {
                let clipFrame = clip.convert(clip.bounds, to: content)
                NSBezierPath(rect: content.isFlipped
                    ? NSRect(x: clipFrame.minX, y: content.bounds.height - clipFrame.maxY, width: clipFrame.width, height: clipFrame.height)
                    : clipFrame).setClip()
            }
            info += "terminal=\(frame) firstResponder=\(window.firstResponder === surfaceView)\n"
            let contents = surfaceView.layer?.contents ?? surfaceView.layer?.sublayers?.first?.contents
            if !overlayVisible, let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let ioSurface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let image = CIImage(ioSurface: ioSurface)
                if let cg = CIContext().createCGImage(image, from: image.extent) {
                    NSImage(cgImage: cg, size: frame.size).draw(in: content.isFlipped
                        ? NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
                        : frame)
                }
            }
            if let surface = surfaceView.surface {
                var text = ghostty_text_s()
                let selection = ghostty_selection_s(
                    top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                    bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                    rectangle: false
                )
                if ghostty_surface_read_text(surface, selection, &text) {
                    info += String(cString: text.text)
                    ghostty_surface_free_text(surface, &text)
                }
            }
        }
        composed.unlockFocus()
        try? info.write(toFile: dir + "/terminal.txt", atomically: true, encoding: .utf8)
        if let tiff = composed.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/window.png"))
        }
    }
}
