import AVFAudio
import Foundation
import ImageIO
import WebbyCore

/// Decode-level asset checks for one extracted skin staging root.
///
/// All filesystem and media-framework work happens once in `init`. The value is
/// immutable afterwards, so calling `inventory()`, `image(_:)` or `sound(_:)`
/// repeatedly is cheap, thread-safe and never writes anything.
public struct SkinAssetChecker: SkinAssetChecking, Sendable, Equatable {
    public let root: URL

    private let records: [SkinAssetRecord]
    private let imageChecks: [String: AssetCheck<ImageAssetMetadata>]
    private let soundChecks: [String: AssetCheck<SoundAssetMetadata>]

    public init(stagingRoot: URL, entries: [SkinArchivePreflightEntry]) {
        let sortedEntries = entries.sorted { lhs, rhs in
            Data(lhs.path.utf8).lexicographicallyPrecedes(Data(rhs.path.utf8))
        }

        var records: [SkinAssetRecord] = []
        var imageChecks: [String: AssetCheck<ImageAssetMetadata>] = [:]
        var soundChecks: [String: AssetCheck<SoundAssetMetadata>] = [:]

        for entry in sortedEntries {
            let url = Self.stagedURL(for: entry.path, in: stagingRoot)
            let bytes = url.flatMap(Self.fileByteCount) ?? 0
            records.append(SkinAssetRecord(path: entry.path, bytes: bytes))

            guard case .accepted(let skinEntry) = SkinEntryRules.classify(entry.path),
                  let asset = skinEntry.asset
            else {
                continue
            }

            switch asset.kind {
            case .image, .orb:
                imageChecks[entry.path] = url.map {
                    Self.imageCheck(path: entry.path, url: $0, bytes: bytes)
                } ?? .invalid(code: "unreadable")
            case .sound:
                soundChecks[entry.path] = url.map {
                    Self.soundCheck(path: entry.path, url: $0, bytes: bytes)
                } ?? .invalid(code: "unreadable")
            }
        }

        self.root = stagingRoot
        self.records = records
        self.imageChecks = imageChecks
        self.soundChecks = soundChecks
    }

    public init(_ staged: StagedSkinArchive) {
        self.init(stagingRoot: staged.root, entries: staged.entries)
    }

    public func inventory() -> [SkinAssetRecord] {
        records
    }

    public func image(_ path: String) -> AssetCheck<ImageAssetMetadata> {
        imageChecks[path] ?? .missing
    }

    public func sound(_ path: String) -> AssetCheck<SoundAssetMetadata> {
        soundChecks[path] ?? .missing
    }

    // MARK: - Staging paths

    /// The archive extractor creates regular files only. Re-checking the resolved
    /// location keeps a later symlink planted in the staging root from selecting
    /// a file outside it.
    private static func stagedURL(for path: String, in root: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else {
            return nil
        }

        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let candidate = rootURL.appendingPathComponent(path).standardizedFileURL
        guard candidate.path.hasPrefix(prefix) else {
            return nil
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(resolvedPrefix) else {
            return nil
        }
        return candidate
    }

    private static func fileByteCount(at url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue
        else {
            return nil
        }
        return max(0, size)
    }

    // MARK: - Images

    private static func imageCheck(
        path: String,
        url: URL,
        bytes: Int
    ) -> AssetCheck<ImageAssetMetadata> {
        guard bytes <= SkinValidator.maximumImageBytes else {
            return .invalid(code: "image-too-large")
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: 33) ?? Data()
        } catch {
            return .invalid(code: "unreadable")
        }

        let header: PNGHeader
        do {
            header = try PNGHeader.parse(data)
        } catch let error as PNGHeaderError {
            return .invalid(code: pngHeaderCode(for: error))
        } catch {
            return .invalid(code: "png-header")
        }

        // PNGHeader already bounds the dimensions. Keep the validator's public cap
        // as the authority here so the two cannot drift apart.
        guard header.width <= SkinValidator.maximumImageDimension,
              header.height <= SkinValidator.maximumImageDimension
        else {
            return .invalid(code: "image-dimension-exceeded")
        }

        return decodeImage(path: path, url: url, bytes: bytes, header: header)
    }

    private static func pngHeaderCode(for error: PNGHeaderError) -> String {
        switch error {
        case .truncated:
            return "png-truncated"
        case .badSignature:
            return "not-png"
        case .badIHDRLength:
            return "png-ihdr-length"
        case .badIHDRChunkType:
            return "png-ihdr-type"
        case .badCRC:
            return "png-crc"
        case .invalidDimensions:
            return "png-dimensions"
        case .unsupportedColorDepth:
            return "png-color-depth"
        case .unsupportedCompression:
            return "png-compression"
        case .unsupportedFilter:
            return "png-filter"
        case .unsupportedInterlace:
            return "png-interlace"
        case .oversized:
            return "image-dimension-exceeded"
        }
    }

    private static func decodeImage(
        path: String,
        url: URL,
        bytes: Int,
        header: PNGHeader
    ) -> AssetCheck<ImageAssetMetadata> {
        let options = [kCGImageSourceTypeIdentifierHint: "public.png"] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            return .invalid(code: "png-source")
        }

        let count = CGImageSourceGetCount(source)
        guard count == 1 else {
            return .invalid(code: count == 0 ? "png-no-image" : "png-multiple-images")
        }

        // Creating the image forces ImageIO to decode the payload. A header-only
        // or truncated PNG fails here instead of being reported as available.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return .invalid(code: "png-decode")
        }

        guard CGImageGetWidth(image) == header.width,
              CGImageGetHeight(image) == header.height
        else {
            return .invalid(code: "png-dimension-mismatch")
        }

        return .available(ImageAssetMetadata(path: path, bytes: bytes, png: header))
    }

    // MARK: - Sounds

    private static func soundCheck(
        path: String,
        url: URL,
        bytes: Int
    ) -> AssetCheck<SoundAssetMetadata> {
        guard bytes <= SkinValidator.maximumSoundBytes else {
            return .invalid(code: "sound-too-large")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return .invalid(code: "unreadable")
        }

        // `fileFormat` is the on-disk format. `processingFormat` may be converted
        // to float PCM and would hide a compressed source.
        let sampleRate = file.fileFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            return .invalid(code: "sound-sample-rate")
        }

        let frameLength = file.length
        guard frameLength >= 0 else {
            return .invalid(code: "sound-length")
        }

        let duration = Double(frameLength) / sampleRate
        guard duration.isFinite, duration >= 0 else {
            return .invalid(code: "sound-duration")
        }

        let isPCM = file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM
        return .available(SoundAssetMetadata(
            path: path,
            bytes: bytes,
            isPCM: isPCM,
            duration: duration
        ))
    }
}

/// The archive lane's complete validation result for one staged skin.
public struct SkinArchiveValidation: Sendable {
    public let manifest: SkinManifest?
    public let document: SkinManifestDocument?
    public let validation: SkinValidationResult
    public let checker: SkinAssetChecker
    public let diagnostics: [SkinDiagnostic]

    public init(
        manifest: SkinManifest?,
        document: SkinManifestDocument?,
        validation: SkinValidationResult,
        checker: SkinAssetChecker,
        diagnostics: [SkinDiagnostic]
    ) {
        self.manifest = manifest
        self.document = document
        self.validation = validation
        self.checker = checker
        self.diagnostics = diagnostics
    }

    public var result: SkinValidationResult {
        validation
    }

    public var assetChecker: SkinAssetChecker {
        checker
    }

    public var groups: [SkinGroup: SkinGroupStatus] {
        validation.groups
    }

    /// A load is accepted only when no combined diagnostic is fatal.
    public var isAccepted: Bool {
        !diagnostics.contains { $0.severity == .fatal }
    }

    /// The image keys a validated staged skin actually contained, shaped for
    /// `InstalledSkin.availableImagePaths`.
    public var availableImagePaths: Set<String> {
        Set(checker.inventory().compactMap { record in
            guard case .accepted(let entry) = SkinEntryRules.classify(record.path),
                  let asset = entry.asset
            else {
                return nil
            }
            switch asset.kind {
            case .image, .orb:
                return record.path
            case .sound:
                return nil
            }
        })
    }
}

/// Loads the staged manifest and runs the shared validator against the staged
/// media. It never reads the caller's archive snapshot.
public enum SkinArchiveStaging {
    public static func validate(
        _ staged: StagedSkinArchive,
        availableBaseIDs: Set<String>
    ) -> SkinArchiveValidation {
        let checker = SkinAssetChecker(staged)
        let manifestURL = staged.root.appendingPathComponent("skin.json")

        var loaderDiagnostics: [SkinDiagnostic] = []
        let manifestData: Data
        if let data = try? Data(contentsOf: manifestURL) {
            manifestData = data
        } else {
            manifestData = Data()
            loaderDiagnostics.append(SkinDiagnostic(
                code: "manifest-unreadable",
                severity: .fatal,
                path: [],
                assetPath: "skin.json",
                message: "skin.json could not be read from the staging directory."
            ))
        }

        let document = SkinManifestLoader.load(data: manifestData)
        let validation = SkinValidator.validate(
            document: document,
            assets: checker,
            context: SkinValidationContext(
                isBuiltIn: false,
                availableBaseIDs: availableBaseIDs
            )
        )

        let diagnostics = sortedDiagnostics(
            staged.warnings + loaderDiagnostics + validation.diagnostics
        )

        return SkinArchiveValidation(
            manifest: validation.manifest,
            document: document,
            validation: validation,
            checker: checker,
            diagnostics: diagnostics
        )
    }

    /// The same ordering as `SkinFolderLoader`: severity, code, JSON path, group,
    /// asset path, then message.
    private static func sortedDiagnostics(_ diagnostics: [SkinDiagnostic]) -> [SkinDiagnostic] {
        diagnostics.sorted { lhs, rhs in
            let left = (
                severityRank(lhs.severity),
                lhs.code,
                lhs.jsonPath,
                lhs.group ?? "",
                lhs.assetPath ?? "",
                lhs.message
            )
            let right = (
                severityRank(rhs.severity),
                rhs.code,
                rhs.jsonPath,
                rhs.group ?? "",
                rhs.assetPath ?? "",
                rhs.message
            )
            return left < right
        }
    }

    private static func severityRank(_ severity: SkinDiagnostic.Severity) -> Int {
        switch severity {
        case .fatal:
            return 0
        case .groupError:
            return 1
        case .warning:
            return 2
        }
    }
}
