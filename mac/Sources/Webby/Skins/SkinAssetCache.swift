import AppKit
import SwiftUI
import WebbyCore

/// Turns a resolved image key into an `NSImage` from the skin folder's 1x and 2x files.
///
/// Decoded files are cached by URL and reused while their modification date and size are
/// unchanged, so a hot-reloaded skin shows its new artwork without a manual flush. The
/// file name comes from `ResolvedImageKey.relativeName`, so no path grammar lives here.
@MainActor
final class SkinAssetCache {
    /// The skin folder for an installed skin ID, or nil when it isn't installed.
    typealias FolderProvider = (String) -> URL?

    private struct Entry {
        let skinID: String
        let modified: Date?
        let size: Int
        let rep: NSBitmapImageRep
    }

    private let folder: FolderProvider
    private var entries: [URL: Entry] = [:]

    init(folder: @escaping FolderProvider) {
        self.folder = folder
    }

    /// An image with a representation for each scale in `availableScales`, sized in
    /// points. Returns nil when no file for those scales can be read.
    func image(for key: ResolvedImageKey, availableScales: Set<SkinScale>) -> NSImage? {
        guard let root = folder(key.skinID) else { return nil }
        let scales = availableScales.isEmpty ? [key.scale] : availableScales.sorted { $0.rawValue < $1.rawValue }
        var reps: [NSBitmapImageRep] = []
        for scale in scales {
            let variant = ResolvedImageKey(skinID: key.skinID, element: key.element, appearance: key.appearance, scale: scale)
            let url = root.appendingPathComponent(variant.relativeName)
            if let rep = representation(at: url, skinID: key.skinID, scale: scale) {
                reps.append(rep)
            }
        }
        guard let first = reps.first else { return nil }
        let image = NSImage(size: first.size)
        for rep in reps { image.addRepresentation(rep) }
        return image
    }

    func image(for resolved: ResolvedImage) -> NSImage? {
        image(for: resolved.key, availableScales: resolved.availableScales)
    }

    /// Forgets everything decoded for `skinID`.
    func invalidate(skinID: String) {
        entries = entries.filter { $0.value.skinID != skinID }
    }

    func removeAll() {
        entries.removeAll()
    }

    private func representation(at url: URL, skinID: String, scale: SkinScale) -> NSBitmapImageRep? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let size = values?.fileSize else {
            entries.removeValue(forKey: url)
            return nil
        }
        let modified = values?.contentModificationDate
        if let entry = entries[url], entry.modified == modified, entry.size == size {
            return entry.rep
        }
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            entries.removeValue(forKey: url)
            return nil
        }
        // Points, not pixels: a @2x file covers half as many points as it has pixels.
        rep.size = NSSize(width: Double(rep.pixelsWide) / Double(scale.rawValue),
                          height: Double(rep.pixelsHigh) / Double(scale.rawValue))
        entries[url] = Entry(skinID: skinID, modified: modified, size: size, rep: rep)
        return rep
    }
}

// Hand-written rather than with SwiftUI's Entry macro (plan §5.4.8). A computed default
// keeps the non-Sendable class out of a static stored property.
private struct SkinAssetCacheKey: EnvironmentKey {
    static var defaultValue: SkinAssetCache? { nil }
}

extension EnvironmentValues {
    var skinAssetCache: SkinAssetCache? {
        get { self[SkinAssetCacheKey.self] }
        set { self[SkinAssetCacheKey.self] = newValue }
    }
}
