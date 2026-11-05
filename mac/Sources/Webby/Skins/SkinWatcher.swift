import CoreServices
import Foundation

/// Reports file changes anywhere under the user skins folder through FSEvents.
///
/// The folder may not exist until the first install or duplicate, so `startIfPossible()`
/// is cheap to call again after those. Events arrive on a private queue and are
/// forwarded to the main actor; the caller debounces them.
@MainActor
final class SkinWatcher {
    /// Carries the callback through the C context pointer. The closure is `@Sendable`
    /// and does nothing but hop to the main actor.
    private final class Box: @unchecked Sendable {
        let handler: @Sendable () -> Void
        init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    }

    private let root: URL
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "app.webby.skin-watcher", qos: .utility)
    // The stream is touched only from the main actor; `deinit` is the one other reader.
    nonisolated(unsafe) private var stream: FSEventStreamRef?

    var isWatching: Bool { stream != nil }

    init(root: URL, onChange: @escaping @MainActor () -> Void) {
        self.root = root
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts the stream when the folder exists and it isn't already running.
    func startIfPossible() {
        guard stream == nil else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }

        let onChange = self.onChange
        let box = Box {
            Task { @MainActor in onChange() }
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).takeUnretainedValue().handler()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else {
            // The stream never took ownership of the context.
            Unmanaged<Box>.fromOpaque(context.info!).release()
            return
        }
        FSEventStreamSetDispatchQueue(created, queue)
        if FSEventStreamStart(created) {
            stream = created
        } else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
