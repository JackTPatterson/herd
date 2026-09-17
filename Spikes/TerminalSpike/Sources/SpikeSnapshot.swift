// Spike-only verification helper: when SPIKE_SNAPSHOT_DIR is set, periodically
// dumps the terminal's rendered IOSurface (layer contents) to snap.png and the
// visible screen text to snap.txt. Self-capture needs no Screen Recording permission.
import AppKit
import CoreImage
import GhosttyKit
import IOSurface

@MainActor
enum SpikeSnapshot {
    static func start() {
        guard let dir = ProcessInfo.processInfo.environment["SPIKE_SNAPSHOT_DIR"] else { return }
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { dump(to: dir) }
        }
    }

    private static func findSurface(in view: NSView) -> Ghostty.SurfaceView? {
        if let s = view as? Ghostty.SurfaceView { return s }
        for sub in view.subviews { if let s = findSurface(in: sub) { return s } }
        return nil
    }

    private static func dump(to dir: String) {
        for window in NSApp.windows {
            guard let content = window.contentView, let view = findSurface(in: content) else { continue }
            var info = "window=\(window.frame) view=\(view.frame) firstResponder=\(window.firstResponder === view) key=\(window.isKeyWindow) title=\(window.title)\n"
            if let surface = view.surface {
                let size = ghostty_surface_size(surface)
                info += "grid=\(size.columns)x\(size.rows) px=\(size.width_px)x\(size.height_px)\n"
                var text = ghostty_text_s()
                let sel = ghostty_selection_s(
                    top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                    bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                    rectangle: false)
                if ghostty_surface_read_text(surface, sel, &text) {
                    info += String(cString: text.text)
                    ghostty_surface_free_text(surface, &text)
                }
            }
            try? info.write(toFile: dir + "/snap.txt", atomically: true, encoding: .utf8)

            let contents = view.layer?.contents ?? view.layer?.sublayers?.first?.contents
            if let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                let ioSurface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let image = CIImage(ioSurface: ioSurface)
                let ctx = CIContext()
                if let cg = ctx.createCGImage(image, from: image.extent) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/snap.png"))
                }
            }
            return
        }
    }
}
