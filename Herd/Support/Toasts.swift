import SwiftUI

/// App-wide progress and confirmation toasts for lasting actions.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    enum Style: Equatable { case progress, success, failure, info }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var style: Style
        var title: String
        var detail: String?
        /// Progress toasts stay hidden until the work runs past this moment,
        /// so instant socket calls only show their confirmation.
        var visibleAfter: Date = .distantPast
    }

    /// Opaque reference to a toast that will be updated when work finishes.
    struct Handle { fileprivate let id: UUID }

    @Published private(set) var toasts: [Toast] = []

    static let progressDelay: TimeInterval = 0.2
    static let maxVisible = 4

    /// Shows a progress toast (after a short delay) and returns a handle to finish it.
    @discardableResult
    func progress(_ title: String, detail: String? = nil) -> Handle {
        let toast = Toast(style: .progress, title: title, detail: detail,
                          visibleAfter: Date().addingTimeInterval(Self.progressDelay))
        toasts.append(toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.progressDelay + 0.01) { [weak self] in
            self?.objectWillChange.send()
        }
        trim()
        return Handle(id: toast.id)
    }

    func succeed(_ handle: Handle?, _ title: String, detail: String? = nil) {
        finish(handle, style: .success, title: title, detail: detail, after: 3.5)
    }

    func fail(_ handle: Handle?, _ title: String, detail: String? = nil) {
        finish(handle, style: .failure, title: title, detail: detail, after: 8)
    }

    func info(_ title: String, detail: String? = nil) {
        finish(nil, style: .info, title: title, detail: detail, after: 3.5)
    }

    /// Updates a running toast's text without finishing it.
    func update(_ handle: Handle, title: String, detail: String? = nil) {
        guard let index = toasts.firstIndex(where: { $0.id == handle.id }) else { return }
        toasts[index].title = title
        toasts[index].detail = detail
    }

    func dismiss(handleId handle: Handle) {
        dismiss(handle.id)
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    var visibleToasts: [Toast] {
        let now = Date()
        return Array(toasts.filter { $0.visibleAfter <= now }.suffix(Self.maxVisible))
    }

    private func finish(_ handle: Handle?, style: Style, title: String, detail: String?, after seconds: TimeInterval) {
        let id: UUID
        if let handle, let index = toasts.firstIndex(where: { $0.id == handle.id }) {
            toasts[index].style = style
            toasts[index].title = title
            toasts[index].detail = detail
            toasts[index].visibleAfter = .distantPast
            id = handle.id
        } else {
            let toast = Toast(style: style, title: title, detail: detail)
            toasts.append(toast)
            id = toast.id
        }
        trim()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.dismiss(id)
        }
    }

    private func trim() {
        let finished = toasts.filter { $0.style != .progress }
        if finished.count > 8, let oldest = finished.first {
            dismiss(oldest.id)
        }
    }
}

/// Toast stack, bottom-right, Warp card styling.
struct ToastStack: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.visibleToasts) { toast in
                ToastCard(toast: toast) { center.dismiss(toast.id) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: center.visibleToasts)
        .padding(16)
    }
}

private struct ToastCard: View {
    let toast: ToastCenter.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            if toast.style != .progress {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.card)
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }

    private var accent: Color {
        switch toast.style {
        case .progress, .info: return Theme.accent
        case .success: return Color(hex: AgentStateColor.done)
        case .failure: return Color(hex: AgentStateColor.blocked)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.style {
        case .progress:
            ProgressView().controlSize(.small).tint(Theme.accent)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(accent)
        case .info:
            Image(systemName: "info.circle.fill").foregroundStyle(accent)
        }
    }
}
