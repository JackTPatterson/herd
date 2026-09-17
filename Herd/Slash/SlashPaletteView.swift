import SwiftUI

/// The `/` menu, styled like Herd's command palette and anchored over the
/// terminal so it reads as part of the prompt.
struct SlashPaletteView: View {
    @ObservedObject var slash: SlashController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("/")
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.accent)
                TextField("", text: $slash.query)
                    .textFieldStyle(.plain)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { slash.choose(submit: NSEvent.modifierFlags.contains(.command)) }
                Text(slash.agentName)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(slash.matches.enumerated()), id: \.element.id) { index, command in
                            CommandRow(command: command, selected: index == slash.selection)
                                .id(command.id)
                                .onTapGesture { slash.choose(command) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
                .onChange(of: slash.selection) { _, index in
                    guard slash.matches.indices.contains(index) else { return }
                    proxy.scrollTo(slash.matches[index].id)
                }
            }

            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 10) {
                Hint(keys: "↩", label: "Insert")
                Hint(keys: "⌘↩", label: "Run")
                Hint(keys: "esc", label: "Keep typing")
                Spacer()
                Text("\(slash.matches.count)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 460)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
        .onAppear { focused = true }
        .onExitCommand { slash.cancel() }
        .background {
            // Arrow keys and ⌘↩ while the field holds focus.
            KeyCatcher(
                isActive: { slash.isOpen },
                up: { slash.moveSelection(-1) },
                down: { slash.moveSelection(1) },
                submitRunning: { slash.choose(submit: true) }
            )
        }
    }
}

private struct CommandRow: View {
    let command: SlashCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("/" + command.name)
                .font(Theme.monoFont)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if !command.summary.isEmpty {
                Text(command.summary)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !command.origin.label.isEmpty {
                Text(command.origin.label)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Theme.cardSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
    }
}

private struct Hint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Arrow-key and ⌘↩ handling that a plain TextField swallows.
private struct KeyCatcher: NSViewRepresentable {
    /// The monitor is app-wide, so every key it takes is gated on the menu
    /// still being open.
    let isActive: () -> Bool
    let up: () -> Void
    let down: () -> Void
    let submitRunning: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(isActive: isActive, up: up, down: down, submitRunning: submitRunning)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(isActive: isActive, up: up, down: down, submitRunning: submitRunning)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var isActive: (() -> Bool)?
        private var up: (() -> Void)?
        private var down: (() -> Void)?
        private var submitRunning: (() -> Void)?

        func install(isActive: @escaping () -> Bool, up: @escaping () -> Void, down: @escaping () -> Void, submitRunning: @escaping () -> Void) {
            self.isActive = isActive
            self.up = up
            self.down = down
            self.submitRunning = submitRunning
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive?() == true else { return event }
                switch event.keyCode {
                case 126: self.up?(); return nil
                case 125: self.down?(); return nil
                case 36, 76 where event.modifierFlags.contains(.command):
                    if event.modifierFlags.contains(.command) {
                        self.submitRunning?()
                        return nil
                    }
                    return event
                case 48: // Tab completes like ↩ without running.
                    return event
                default: return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
