// Herd-facing API over the embedded libghostty terminal.
//
// Usage:
//   HerdTerminalRuntime.configure(overrides: "background = 050505")   // once, at launch
//   HerdTerminalView(command: "...", environment: [...], workingDirectory: ..., onTitleChange: ..., onExit: ...)
//
// The Ghostty glue in ./Ghostty is MIT-licensed code copied from Ghostty
// (see Ghostty/LICENSE-ghostty).

import AppKit
import GhosttyKit
import SwiftUI

/// Owns the process-wide libghostty app and configuration.
@MainActor
final class HerdTerminalRuntime {
    static let shared = HerdTerminalRuntime()

    private var overrides: String = ""
    private var didInitGhostty = false
    private var ghosttyApp: Ghostty.App?

    private init() {}

    /// Call once at launch, before any terminal view is created.
    /// `overrides` uses Ghostty config-file syntax, one setting per line
    /// (e.g. "background = 050505\nfont-size = 13"). The user's own Ghostty
    /// config files are never loaded.
    static func configure(overrides: String) {
        let runtime = shared
        precondition(runtime.ghosttyApp == nil, "HerdTerminalRuntime.configure must be called before any terminal is created")
        runtime.overrides = overrides
        runtime.initGhosttyIfNeeded()
        runtime.ghosttyApp = Ghostty.App(overrides: overrides)
    }

    /// Replaces the overrides and applies them live to every surface.
    static func updateConfig(overrides: String) {
        let runtime = shared
        runtime.overrides = overrides
        runtime.ghosttyApp?.updateConfig(overrides: overrides)
    }

    /// Applies (or clears) Ghostty's background blur on a window.
    static func applyBackgroundBlur(to window: NSWindow) {
        shared.ghosttyApp?.applyBackgroundBlur(to: window)
    }

    /// Makes the key window's terminal surface first responder again.
    static func focusTerminal() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
                  let content = window.contentView,
                  let surface = findSurface(in: content) else { return }
            window.makeFirstResponder(surface)
        }
    }

    private static func findSurface(in view: NSView) -> Ghostty.SurfaceView? {
        if let surface = view as? Ghostty.SurfaceView { return surface }
        for sub in view.subviews {
            if let surface = findSurface(in: sub) { return surface }
        }
        return nil
    }

    /// Config diagnostics (invalid override lines, etc.).
    var configErrors: [String] {
        app.config.errors
    }

    fileprivate var app: Ghostty.App {
        if let ghosttyApp { return ghosttyApp }
        initGhosttyIfNeeded()
        let created = Ghostty.App(overrides: overrides)
        ghosttyApp = created
        return created
    }

    private func initGhosttyIfNeeded() {
        guard !didInitGhostty else { return }
        didInitGhostty = true
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            Ghostty.logger.critical("ghostty_init failed")
        }
    }

    /// Create a terminal surface view running `command` (through the login shell,
    /// `/bin/sh -c`-style, as Ghostty does). The returned view accepts first
    /// responder; make it first responder to type into it.
    func makeTerminalView(
        command: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> NSView {
        makeSurfaceView(command: command, environment: environment, workingDirectory: workingDirectory)
    }

    fileprivate func makeSurfaceView(
        command: String,
        environment: [String: String],
        workingDirectory: String?
    ) -> Ghostty.SurfaceView {
        guard let cApp = app.app else {
            fatalError("libghostty app failed to initialize")
        }
        var config = Ghostty.SurfaceConfiguration()
        config.command = command.isEmpty ? nil : command
        config.environmentVariables = environment
        config.workingDirectory = workingDirectory
        return Ghostty.SurfaceView(cApp, baseConfig: config)
    }
}

/// Convenience free function mirroring the runtime method.
@MainActor
func makeTerminalView(command: String, environment: [String: String], workingDirectory: String?) -> NSView {
    HerdTerminalRuntime.shared.makeTerminalView(command: command, environment: environment, workingDirectory: workingDirectory)
}

/// SwiftUI host for a single terminal surface. The surface (and its child
/// process) is created once when the view is first made and lives as long as
/// the SwiftUI view identity; give it a new `.id(...)` to restart.
struct HerdTerminalView: NSViewRepresentable {
    let command: String
    let environment: [String: String]
    let workingDirectory: String?
    /// Terminal rows clipped off the top (Herd hides herdr's own tab row).
    var hiddenTopRows = 0
    var onTitleChange: (String) -> Void = { _ in }
    var onExit: () -> Void = {}

    init(
        command: String,
        environment: [String: String],
        workingDirectory: String?,
        hiddenTopRows: Int = 0,
        onTitleChange: @escaping (String) -> Void = { _ in },
        onExit: @escaping () -> Void = {}
    ) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.hiddenTopRows = hiddenTopRows
        self.onTitleChange = onTitleChange
        self.onExit = onExit
    }

    @MainActor
    func makeNSView(context: Context) -> NSView {
        let view = HerdTerminalRuntime.shared.makeSurfaceView(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory
        )
        view.onTitleChange = onTitleChange
        view.onExit = onExit

        // Grab keyboard focus once we're in a window.
        view.focusOnAttach = true
        guard hiddenTopRows > 0 else { return view }
        return TopRowClippingView(surfaceView: view, hiddenRows: hiddenTopRows)
    }

    @MainActor
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = (nsView as? Ghostty.SurfaceView)
            ?? (nsView as? TopRowClippingView)?.surfaceView else { return }
        // Keep callbacks current (closures may capture fresh SwiftUI state).
        view.onTitleChange = onTitleChange
        view.onExit = onExit
    }
}

/// Hosts a surface taller than itself, shifted up so its first `hiddenRows`
/// terminal rows sit above the visible bounds and are clipped away.
final class TopRowClippingView: NSView {
    let surfaceView: Ghostty.SurfaceView
    let hiddenRows: Int
    private var retryScheduled = false

    init(surfaceView: Ghostty.SurfaceView, hiddenRows: Int) {
        self.surfaceView = surfaceView
        self.hiddenRows = hiddenRows
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(surfaceView)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// Height of the hidden rows in points; 0 until the surface reports a grid.
    var hiddenHeight: CGFloat {
        guard let surface = surfaceView.surface else { return 0 }
        let size = ghostty_surface_size(surface)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGFloat(size.cell_height_px) / scale * CGFloat(hiddenRows)
    }

    override func layout() {
        super.layout()
        let offset = hiddenHeight
        surfaceView.frame = NSRect(x: 0, y: -offset, width: bounds.width, height: bounds.height + offset)
        if offset == 0, !retryScheduled {
            retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.retryScheduled = false
                self?.needsLayout = true
            }
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}
