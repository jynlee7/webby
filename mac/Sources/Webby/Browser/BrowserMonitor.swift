import AppKit
@preconcurrency import ApplicationServices
import WebbyCore

/// Owns OS observations; the replayable browser state stays in WebbyCore.
@MainActor
final class BrowserMonitor {
    private var session = BrowserSession()
    private var pollTask: Task<Void, Never>?
    var onChange: (() -> Void)?
    private(set) var frame: CGRect?
    private(set) var isChromeActive = false
    var queryRules = QueryRules.builtIns
    var context: Context { session.context(focusedFrame: frame, queryRules: queryRules) }

    func start() {
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func receive(_ event: BridgeEvent) {
        // Establish the process identity before accepting its first hello.
        refresh(notify: false)
        session.receive(event)
        onChange?()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func refresh(notify: Bool = true) {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: BrowserSession.bundleID).first
        let identity = app.flatMap { app in
            app.launchDate.map { "\(app.processIdentifier)@\($0.timeIntervalSince1970)" }
        }
        session.setIdentity(identity)
        isChromeActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == BrowserSession.bundleID
        frame = isChromeActive ? app.flatMap { focusedFrame(pid: $0.processIdentifier) } : nil
        if notify { onChange?() }
    }

    private func focusedFrame(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(window, to: AXUIElement.self)
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
