import AVFAudio
import ImageIO
import ZIPFoundation

/// Compile-and-link smoke used by the Command Line Tools CI lane.
///
/// Real archive and media behavior is implemented in later issue #18 slices; this
/// keeps the foundation slice honest about the system and package modules it needs.
enum ArchiveFrameworkAvailability {
    static func typeNames() -> [String] {
        [
            String(reflecting: AVAudioFile.self),
            String(reflecting: CGImageSource.self),
            String(reflecting: Archive.self),
        ]
    }
}
