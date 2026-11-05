import AppKit
import SwiftUI

/// A small floating panel for messages. Like notes, it never activates Webby, so the
/// app the user is in keeps focus while they click its buttons.
@MainActor
private func makeMessagePanel<Content: View>(_ content: Content) -> NSPanel {
    let hosting = FirstMouseHostingView(rootView: content)
    let size = hosting.fittingSize
    let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.animationBehavior = .none

    let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
    blur.material = .hudWindow
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.maskImage = NotePanel.roundedMask(radius: 12)
    hosting.frame = blur.bounds
    hosting.autoresizingMask = [.width, .height]
    blur.addSubview(hosting)
    panel.contentView = blur
    return panel
}

/// "Note moved to Trash" with Undo, shown where the note was for 10 s.
@MainActor
final class UndoToast {
    static let duration: Duration = .seconds(10)

    private var panel: NSPanel?
    private var expiry: Task<Void, Never>?

    /// - Parameters:
    ///   - topLeft: The trashed note's top-left corner, in AppKit coordinates.
    ///   - undo: Restores the note. The toast closes either way.
    init(at topLeft: NSPoint?, undo: @escaping @MainActor () -> Void, closed: @escaping @MainActor () -> Void) {
        let panel = makeMessagePanel(UndoToastView(undo: { [weak self] in
            undo()
            self?.close()
        }))
        if let topLeft {
            panel.setFrameTopLeftPoint(topLeft)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        self.panel = panel
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.close()
            closed()
        }
    }

    func close() {
        expiry?.cancel()
        expiry = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct UndoToastView: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("Note moved to Trash")
            Button("Undo", action: undo)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize()
    }
}

/// A banner below the menu bar for problems that affect every note: a failed save,
/// with Retry, or a notes file that is open read-only.
@MainActor
final class StatusBanner {
    struct Action {
        let title: String
        let run: @MainActor () -> Void
    }

    private var panel: NSPanel?

    func show(title: String, message: String, actions: [Action]) {
        hide()
        let panel = makeMessagePanel(StatusBannerView(
            title: title,
            message: message,
            actions: actions.map { action in
                StatusBannerView.Button(title: action.title, run: action.run)
            } + [StatusBannerView.Button(title: "Dismiss", run: { [weak self] in self?.hide() })]
        ))
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct StatusBannerView: View {
    struct Button: Identifiable {
        let id = UUID()
        let title: String
        let run: @MainActor () -> Void
    }

    let title: String
    let message: String
    let actions: [Button]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    ForEach(actions) { action in
                        SwiftUI.Button(action.title) { action.run() }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
