import AppKit
import SwiftUI

/// Whether Webby may read other apps' window frames, and the onboarding that asks.
///
/// Without the permission notes still work, at fixed screen positions. Ad-hoc builds
/// lose the grant on every rebuild: System Settings still shows the switch on, but
/// `AXIsProcessTrusted()` is false until it is reset (`tccutil reset Accessibility
/// com.webby.app`) or the build is signed with `WEBBY_SIGN_IDENTITY`.
@MainActor
final class AccessibilityPermission {
    private(set) var isTrusted = AXIsProcessTrusted()

    private var observers: [@MainActor () -> Void] = []

    private var pollTimer: Timer?
    private var pollsLeft = 0
    private var onboarding: NSPanel?

    /// Adds a handler that runs after `isTrusted` changes.
    func onChange(_ handler: @escaping @MainActor () -> Void) {
        observers.append(handler)
    }

    /// Re-reads the permission, for example when the frontmost app changes.
    func refresh() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        if trusted { stopPolling() }
        for observer in observers { observer() }
    }

    /// Shows macOS's own prompt, which also adds Webby to the Accessibility list, and
    /// watches for the switch for two minutes.
    func requestAccess() {
        // The literal is `kAXTrustedCheckOptionPrompt`, whose global isn't concurrency-safe.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        startPolling()
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startPolling()
    }

    /// Explains the permission next to the note that needed it. The panel doesn't
    /// activate Webby, so the note keeps the keyboard and the app stays frontmost.
    func showOnboarding(near frame: NSRect?) {
        guard !isTrusted else { return }
        if onboarding == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: true
            )
            panel.title = "Accessibility"
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            panel.contentViewController = NSHostingController(rootView: AccessibilityOnboardingView(
                allow: { [weak self] in
                    self?.requestAccess()
                    self?.onboarding?.orderOut(nil)
                },
                dismiss: { [weak self] in self?.onboarding?.orderOut(nil) }
            ))
            onboarding = panel
        }
        guard let panel = onboarding else { return }
        if let frame, let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            var origin = NSPoint(x: frame.minX, y: frame.minY - panel.frame.height - 12)
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    private func startPolling() {
        pollsLeft = 60
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        pollsLeft -= 1
        refresh()
        if pollsLeft <= 0 { stopPolling() }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private struct AccessibilityOnboardingView: View {
    let allow: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let notes follow their window")
                .font(.headline)
            Text("Webby can keep a note in the same place on an app's window, even when the window moves. To do that it needs Accessibility access, which it uses only to read where the front window is. Without it, notes stay at a fixed place on the screen.")
                .fixedSize(horizontal: false, vertical: true)
            Text("If Webby is already turned on in the list, turn it off and on again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Allow Accessibility…", action: allow)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
