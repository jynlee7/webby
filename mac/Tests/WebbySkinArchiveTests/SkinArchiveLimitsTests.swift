import Testing
import WebbyCore
@testable import WebbySkinArchive

@Test func archiveLimitsMatchCoreAndTheDocumentedArchiveCap() {
    #expect(SkinArchiveLimits.archiveByteCount == 25_000_000)
    #expect(SkinArchiveLimits.uncompressedByteCount == SkinFolderLoader.maximumTotalBytes)
    #expect(SkinArchiveLimits.entryCount == SkinFolderLoader.maximumEntries)
    #expect(SkinArchiveLimits.manifestByteCount == SkinFolderLoader.maximumManifestBytes)
    #expect(SkinArchiveLimits.imageByteCount == SkinValidator.maximumImageBytes)
    #expect(SkinArchiveLimits.soundByteCount == SkinValidator.maximumSoundBytes)
    #expect(SkinArchiveLimits.imageSidePixels == SkinValidator.maximumImageDimension)
    #expect(SkinArchiveLimits.imageTotalPixels == SkinValidator.maximumImagePixels)
}

@Test func archiveFrameworksLoadUnderSupportedToolchain() {
    let names = ArchiveFrameworkAvailability.typeNames()
    #expect(names.count == 3)
    #expect(names.allSatisfy { !$0.isEmpty })
}
