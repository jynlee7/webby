import AppKit
import WebbyCore

/// Follows the frontmost app, and its focused window's frame when Accessibility is
/// allowed.
///
/// Webby's own activations (Settings, alerts) are ignored, so the notes of the app the
/// user was in stay up. Frames use top-left coordinates, as the Accessibility API and
/// `NoteFrame` do.
@MainActor
final class ContextMonitor {
    struct FrontApp: Equatable {
        let bundleID: String
        let pid: pid_t
        let name: String
    }

    private(set) var app: FrontApp?
    private(set) var windowFrame: CGRect?
    /// Called after `app` or `windowFrame` changes.
    var onChange: (() -> Void)?

    var context: Context? {
        app.map { Context(appBundleID: $0.bundleID) }
    }

    private let permission: AccessibilityPermission
    private var activationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var axApp: AXUIElement?
    private var axWindow: AXUIElement?

    private static let appNotifications = [
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]
    // Some apps post moves and resizes only to the window element itself.
    private static let windowNotifications = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    init(permission: AccessibilityPermission) {
        self.permission = permission
    }

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let front = running.flatMap(Self.frontApp)
            let isWebby = running?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated { self?.activated(front, isWebby: isWebby) }
        }
        let running = NSWorkspace.shared.frontmostApplication
        activated(running.flatMap(Self.frontApp),
                  isWebby: running?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        stopObservingWindows()
    }

    /// Re-attaches to the current app after the Accessibility permission changes.
    func permissionChanged() {
        stopObservingWindows()
        if let app { observeWindows(of: app.pid) }
        refreshWindowFrame(force: true)
    }

    private nonisolated static func frontApp(_ running: NSRunningApplication) -> FrontApp? {
        guard running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let bundleID = running.bundleIdentifier else { return nil }
        return FrontApp(bundleID: bundleID, pid: running.processIdentifier, name: running.localizedName ?? bundleID)
    }

    private func activated(_ front: FrontApp?, isWebby: Bool) {
        guard !isWebby else { return }
        permission.refresh()
        guard front != app else {
            refreshWindowFrame(force: false)
            return
        }
        app = front
        stopObservingWindows()
        if let front { observeWindows(of: front.pid) }
        windowFrame = readFocusedWindowFrame()
        onChange?()
    }

    private func refreshWindowFrame(force: Bool) {
        if axWindow == nil || !Self.isSameElement(axWindow, focusedWindow()) {
            observeFocusedWindow()
        }
        let frame = readFocusedWindowFrame()
        guard force || frame != windowFrame else { return }
        windowFrame = frame
        onChange?()
    }

    // MARK: Accessibility

    private func observeWindows(of pid: pid_t) {
        guard permission.isTrusted else { return }
        let element = AXUIElementCreateApplication(pid)
        // A hung app must not stall the main thread for the default six seconds.
        AXUIElementSetMessagingTimeout(element, 0.25)
        axApp = element

        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<ContextMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refreshWindowFrame(force: false) }
        }, &created)
        guard status == .success, let created else { return }
        axObserver = created

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observeFocusedWindow()
    }

    private func observeFocusedWindow() {
        guard let axObserver else { return }
        if let axWindow {
            for name in Self.windowNotifications {
                AXObserverRemoveNotification(axObserver, axWindow, name as CFString)
            }
        }
        axWindow = focusedWindow()
        guard let axWindow else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(axObserver, axWindow, name as CFString, refcon)
        }
    }

    private func stopObservingWindows() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        axApp = nil
        axWindow = nil
    }

    private func focusedWindow() -> AXUIElement? {
        guard permission.isTrusted, let axApp else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func readFocusedWindowFrame() -> CGRect? {
        guard let window = focusedWindow() else { return nil }
        var minimized: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
           (minimized as? Bool) == true {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = Self.axValue(of: kAXPositionAttribute, in: window, type: .cgPoint),
              AXValueGetValue(position, .cgPoint, &origin),
              let extent = Self.axValue(of: kAXSizeAttribute, in: window, type: .cgSize),
              AXValueGetValue(extent, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue(of attribute: String, in element: AXUIElement, type: AXValueType) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }

    private static func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }
}
