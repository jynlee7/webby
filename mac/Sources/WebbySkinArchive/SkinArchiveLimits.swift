import WebbyCore

/// Size caps for `.webbyskin` archives, from plan.md §5.4.6 "Size caps".
///
/// Values shared with folder loading and validation reference `WebbyCore` so the
/// archive lane cannot silently drift to a looser interpretation of the limits.
public enum SkinArchiveLimits {
    /// Largest accepted `.webbyskin` file. This cap exists only at the archive layer.
    public static let archiveByteCount = 25_000_000
    /// Largest total of bytes actually decompressed.
    public static let uncompressedByteCount = SkinFolderLoader.maximumTotalBytes
    /// Most central-directory entries an archive may declare.
    public static let entryCount = SkinFolderLoader.maximumEntries
    /// Largest `skin.json`.
    public static let manifestByteCount = SkinFolderLoader.maximumManifestBytes
    /// Largest single image asset.
    public static let imageByteCount = SkinValidator.maximumImageBytes
    /// Largest single sound asset.
    public static let soundByteCount = SkinValidator.maximumSoundBytes
    /// Largest image side, in pixels.
    public static let imageSidePixels = SkinValidator.maximumImageDimension
    /// Largest decoded pixel total across one skin. `SkinValidator` owns enforcement.
    public static let imageTotalPixels = SkinValidator.maximumImagePixels
}
