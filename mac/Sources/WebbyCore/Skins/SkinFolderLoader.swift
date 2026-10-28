import Foundation

/// Where a loaded skin folder came from. Built-in skins may use the reserved
/// `webby.` id prefix and are not subject to installed-skin restrictions.
public enum SkinOrigin: Sendable, Equatable {
    case builtIn
    case installed
}

/// The bounded folder loader's complete result.
public struct SkinFolderLoadResult: Sendable, Equatable {
    public let manifest: SkinManifest?
    public let document: SkinManifestDocument?
    public let diagnostics: [SkinDiagnostic]
    public let assetChecker: FolderSkinAssetChecker
    public let entries: [SkinEntry]

    public init(
        manifest: SkinManifest?,
        document: SkinManifestDocument?,
        diagnostics: [SkinDiagnostic],
        assetChecker: FolderSkinAssetChecker,
        entries: [SkinEntry]
    ) {
        self.manifest = manifest
        self.document = document
        self.diagnostics = diagnostics
        self.assetChecker = assetChecker
        self.entries = entries
    }

    /// A load is accepted only when no diagnostic is fatal, matching
    /// `SkinValidationResult.isAccepted`.
    public var isAccepted: Bool {
        !diagnostics.contains { $0.severity == .fatal }
    }
}

/// Reads skin assets from one folder without decoding images or sounds through
/// system media frameworks. All reads are bounded by the skin size caps.
public struct FolderSkinAssetChecker: SkinAssetChecking, Sendable, Equatable {
    public let folder: URL

    private let records: [SkinAssetRecord]
    private let imageChecks: [String: AssetCheck<ImageAssetMetadata>]
    private let soundChecks: [String: AssetCheck<SoundAssetMetadata>]

    init(
        folder: URL,
        records: [SkinAssetRecord],
        imageChecks: [String: AssetCheck<ImageAssetMetadata>],
        soundChecks: [String: AssetCheck<SoundAssetMetadata>]
    ) {
        self.folder = folder
        self.records = records
        self.imageChecks = imageChecks
        self.soundChecks = soundChecks
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
}

/// Loads a plain skin folder. It never writes, moves or copies files and never
/// follows a symlink out of the folder.
public enum SkinFolderLoader {
    public static let maximumManifestBytes = 256_000
    public static let maximumEntries = 400
    public static let maximumTotalBytes = 64_000_000
    public static let maximumImageBytes = 4_000_000
    public static let maximumSoundBytes = 1_000_000

    public static func load(
        folder: URL,
        origin: SkinOrigin,
        availableBaseIDs: Set<String>
    ) -> SkinFolderLoadResult {
        let enumeration = enumerate(folder: folder)
        var loaderDiagnostics = enumeration.diagnostics

        // A fatal folder error means the skin is rejected. Do not read assets or
        // build a checker for a package that cannot be accepted.
        if loaderDiagnostics.contains(where: { $0.severity == .fatal }) {
            return SkinFolderLoadResult(
                manifest: nil,
                document: nil,
                diagnostics: sortedDiagnostics(loaderDiagnostics),
                assetChecker: FolderSkinAssetChecker(folder: folder, records: [], imageChecks: [:], soundChecks: [:]),
                entries: []
            )
        }

        let entries = acceptedEntries(from: enumeration.items, diagnostics: &loaderDiagnostics)
        let records = entries.map { SkinAssetRecord(path: $0.path, bytes: enumeration.bytes(for: $0.path)) }
        let checker = makeChecker(folder: folder, items: enumeration.items, records: records)

        let manifestItem = enumeration.items.first {
            $0.path == "skin.json" && $0.isRegularFile && !$0.isSymbolicLink
        }

        guard let manifestItem else {
            loaderDiagnostics.append(SkinDiagnostic(
                code: "manifest-missing",
                severity: .fatal,
                path: [],
                assetPath: "skin.json",
                message: "The skin folder has no skin.json at its root."
            ))
            return SkinFolderLoadResult(
                manifest: nil,
                document: nil,
                diagnostics: sortedDiagnostics(loaderDiagnostics),
                assetChecker: checker,
                entries: entries
            )
        }

        let manifestData: Data
        if manifestItem.size > maximumManifestBytes {
            loaderDiagnostics.append(SkinDiagnostic(
                code: "manifest-too-large",
                severity: .fatal,
                path: [],
                assetPath: "skin.json",
                message: "skin.json is \(manifestItem.size) bytes; the limit is \(maximumManifestBytes)."
            ))
            let diagnostics = sortedDiagnostics(loaderDiagnostics)
            return SkinFolderLoadResult(
                manifest: nil,
                document: nil,
                diagnostics: diagnostics,
                assetChecker: checker,
                entries: entries
            )
        }

        switch readBounded(at: manifestItem.url, maximumBytes: maximumManifestBytes) {
        case .success(let data):
            manifestData = data
        case .tooLarge:
            loaderDiagnostics.append(SkinDiagnostic(
                code: "manifest-too-large",
                severity: .fatal,
                path: [],
                assetPath: "skin.json",
                message: "skin.json exceeds the \(maximumManifestBytes)-byte limit."
            ))
            return SkinFolderLoadResult(
                manifest: nil,
                document: nil,
                diagnostics: sortedDiagnostics(loaderDiagnostics),
                assetChecker: checker,
                entries: entries
            )
        case .unreadable:
            loaderDiagnostics.append(SkinDiagnostic(
                code: "manifest-unreadable",
                severity: .fatal,
                path: [],
                assetPath: "skin.json",
                message: "skin.json could not be read."
            ))
            return SkinFolderLoadResult(
                manifest: nil,
                document: nil,
                diagnostics: sortedDiagnostics(loaderDiagnostics),
                assetChecker: checker,
                entries: entries
            )
        }

        let document = SkinManifestLoader.load(data: manifestData)
        let context = SkinValidationContext(
            isBuiltIn: origin == .builtIn,
            availableBaseIDs: availableBaseIDs
        )
        let validation = SkinValidator.validate(
            document: document,
            assets: checker,
            context: context
        )

        let diagnostics = loaderDiagnostics + validation.diagnostics
        return SkinFolderLoadResult(
            manifest: validation.manifest,
            document: document,
            diagnostics: sortedDiagnostics(diagnostics),
            assetChecker: checker,
            entries: entries
        )
    }

    // MARK: - Folder enumeration

    private struct FolderItem: Sendable, Equatable {
        let path: String
        let url: URL
        let size: Int
        let isRegularFile: Bool
        let isSymbolicLink: Bool
    }

    private struct Enumeration {
        let items: [FolderItem]
        let diagnostics: [SkinDiagnostic]

        func bytes(for path: String) -> Int {
            items.first { samePath($0.path, path) }?.size ?? 0
        }
    }

    private static func enumerate(folder: URL) -> Enumeration {
        let fileManager = FileManager.default
        var diagnostics: [SkinDiagnostic] = []
        var items: [FolderItem] = []

        let root = folder.standardizedFileURL
        let rootPath = root.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let resolvedRootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedPrefix = resolvedRootPath.hasSuffix("/")
            ? resolvedRootPath
            : resolvedRootPath + "/"

        var enumerationError: String?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error.localizedDescription
                return false
            }
        ) else {
            return Enumeration(
                items: [],
                diagnostics: [SkinDiagnostic(
                    code: "folder-unreadable",
                    severity: .fatal,
                    path: [],
                    message: "The skin folder could not be enumerated."
                )]
            )
        }

        var visitedEntries = 0
        var exceededEntryCount = false
        for case let url as URL in enumerator {
            visitedEntries += 1
            if visitedEntries > maximumEntries {
                exceededEntryCount = true
                break
            }
            let itemPath = url.standardizedFileURL.path
            guard itemPath.hasPrefix(prefix) else {
                continue
            }
            let relativePath = String(itemPath.dropFirst(prefix.count))
            guard !relativePath.isEmpty else {
                continue
            }

            // Reject any entry whose resolved location leaves the folder. This
            // also covers a platform enumerator that descends a symlinked folder.
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolvedPath == resolvedRootPath || resolvedPath.hasPrefix(resolvedPrefix) else {
                diagnostics.append(SkinDiagnostic(
                    code: "entry-symlink",
                    severity: .fatal,
                    assetPath: relativePath,
                    message: "Entry '\(relativePath)' resolves outside the skin folder."
                ))
                continue
            }

            guard let attributes = try? fileManager.attributesOfItem(atPath: itemPath) else {
                diagnostics.append(SkinDiagnostic(
                    code: "entry-unreadable",
                    severity: .fatal,
                    assetPath: relativePath,
                    message: "Entry '\(relativePath)' could not be inspected."
                ))
                continue
            }

            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
                continue
            }

            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            items.append(FolderItem(
                path: relativePath,
                url: url,
                size: max(0, size),
                isRegularFile: type == .typeRegular,
                isSymbolicLink: type == .typeSymbolicLink
            ))
        }

        if exceededEntryCount {
            diagnostics.append(SkinDiagnostic(
                code: "entry-count-exceeded",
                severity: .fatal,
                path: [],
                message: "The folder has more than \(maximumEntries) entries."
            ))
        }

        if let enumerationError {
            diagnostics.append(SkinDiagnostic(
                code: "folder-unreadable",
                severity: .fatal,
                path: [],
                message: "The skin folder could not be enumerated: \(enumerationError)"
            ))
        }

        // Filesystem order is unspecified. Every downstream step uses this order.
        items.sort { pathLess($0.path, $1.path) }

        if !exceededEntryCount && items.count > maximumEntries {
            diagnostics.append(SkinDiagnostic(
                code: "entry-count-exceeded",
                severity: .fatal,
                path: [],
                message: "The folder has \(items.count) entries; the limit is \(maximumEntries)."
            ))
        }

        let totalBytes = items.reduce(into: 0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.size)
            total = overflow ? Int.max : sum
        }
        if totalBytes > maximumTotalBytes {
            diagnostics.append(SkinDiagnostic(
                code: "total-size-exceeded",
                severity: .fatal,
                path: [],
                message: "The folder totals \(totalBytes) bytes; the limit is \(maximumTotalBytes)."
            ))
        }

        var firstByNormalizedName: [String: String] = [:]
        for item in items where !item.isSymbolicLink && item.isRegularFile {
            let key = normalizedName(item.path)
            if let first = firstByNormalizedName[key] {
                diagnostics.append(SkinDiagnostic(
                    code: "duplicate-entry",
                    severity: .fatal,
                    path: [],
                    assetPath: item.path,
                    message: "Entries '\(first)' and '\(item.path)' collide after NFC normalization and case folding."
                ))
            } else {
                firstByNormalizedName[key] = item.path
            }
        }

        return Enumeration(items: items, diagnostics: diagnostics)
    }

    private static func acceptedEntries(
        from items: [FolderItem],
        diagnostics: inout [SkinDiagnostic]
    ) -> [SkinEntry] {
        var entries: [SkinEntry] = []
        var seenNormalizedNames: Set<String> = []

        for item in items {
            if item.isSymbolicLink {
                diagnostics.append(SkinDiagnostic(
                    code: "entry-symlink",
                    severity: .fatal,
                    assetPath: item.path,
                    message: "Symbolic link '\(item.path)' is not allowed."
                ))
                continue
            }
            guard item.isRegularFile else {
                diagnostics.append(SkinDiagnostic(
                    code: "entry-not-regular",
                    severity: .fatal,
                    assetPath: item.path,
                    message: "Entry '\(item.path)' is not a regular file."
                ))
                continue
            }

            let key = normalizedName(item.path)
            if !seenNormalizedNames.insert(key).inserted {
                // The collision is already reported as fatal by enumeration.
                continue
            }

            switch SkinEntryRules.classify(item.path) {
            case .accepted(let entry):
                entries.append(entry)
            case .skipped:
                break
            case .warning(let reason):
                diagnostics.append(SkinDiagnostic(
                    code: "entry-skipped",
                    severity: .warning,
                    assetPath: item.path,
                    message: "Entry '\(item.path)' was skipped: \(reason)."
                ))
            case .rejected(let reason):
                diagnostics.append(SkinDiagnostic(
                    code: "entry-rejected",
                    severity: .fatal,
                    assetPath: item.path,
                    message: "Entry '\(item.path)' was rejected: \(reason)."
                ))
            }
        }

        entries.sort { pathLess($0.path, $1.path) }
        return entries
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func pathLess(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// The collision key used for two entries that a case-insensitive, normalizing
    /// filesystem would treat as one file. Exposed internally so the rule can be
    /// tested without depending on the test volume's case behaviour.
    static func normalizedName(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }

    // MARK: - Asset checks

    private static func makeChecker(
        folder: URL,
        items: [FolderItem],
        records: [SkinAssetRecord]
    ) -> FolderSkinAssetChecker {
        let itemsByPath = Dictionary(
            uniqueKeysWithValues: items.map { (Data($0.path.utf8), $0) }
        )
        var imageChecks: [String: AssetCheck<ImageAssetMetadata>] = [:]
        var soundChecks: [String: AssetCheck<SoundAssetMetadata>] = [:]

        for record in records {
            guard let item = itemsByPath[Data(record.path.utf8)],
                  case .accepted(let entry) = SkinEntryRules.classify(record.path),
                  let asset = entry.asset
            else {
                continue
            }

            switch asset.kind {
            case .image, .orb:
                imageChecks[record.path] = imageCheck(item: item)
            case .sound:
                soundChecks[record.path] = soundCheck(item: item)
            }
        }

        return FolderSkinAssetChecker(
            folder: folder,
            records: records,
            imageChecks: imageChecks,
            soundChecks: soundChecks
        )
    }

    private static func imageCheck(item: FolderItem) -> AssetCheck<ImageAssetMetadata> {
        guard item.size <= maximumImageBytes else {
            return .invalid(code: "image-too-large")
        }

        switch readPrefix(at: item.url, maximumBytes: 33) {
        case .success(let data):
            do {
                let header = try PNGHeader.parse(data)
                return .available(ImageAssetMetadata(
                    path: item.path,
                    bytes: item.size,
                    png: header
                ))
            } catch {
                return .invalid(code: String(describing: error))
            }
        case .tooLarge:
            return .invalid(code: "image-too-large")
        case .unreadable:
            return .invalid(code: "unreadable")
        }
    }

    private static func soundCheck(item: FolderItem) -> AssetCheck<SoundAssetMetadata> {
        guard item.size <= maximumSoundBytes else {
            return .invalid(code: "sound-too-large")
        }

        switch readBounded(at: item.url, maximumBytes: maximumSoundBytes) {
        case .success(let data):
            return parseSound(path: item.path, data: data)
        case .tooLarge:
            return .invalid(code: "sound-too-large")
        case .unreadable:
            return .invalid(code: "unreadable")
        }
    }

    // MARK: - Bounded reads

    private enum BoundedRead {
        case success(Data)
        case tooLarge
        case unreadable
    }

    private static func readPrefix(at url: URL, maximumBytes: Int) -> BoundedRead {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unreadable
        }
        defer { try? handle.close() }

        var data = Data()
        do {
            while data.count < maximumBytes {
                let remaining = maximumBytes - data.count
                guard let chunk = try handle.read(upToCount: min(remaining, 65_536)),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return .unreadable
        }
        return .success(data)
    }

    private static func readBounded(at url: URL, maximumBytes: Int) -> BoundedRead {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unreadable
        }
        defer { try? handle.close() }

        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard remaining > 0 else {
                    break
                }
                guard let chunk = try handle.read(upToCount: min(remaining, 65_536)),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return .unreadable
        }

        return data.count > maximumBytes ? .tooLarge : .success(data)
    }

    // MARK: - Sound containers

    private static func parseSound(
        path: String,
        data: Data
    ) -> AssetCheck<SoundAssetMetadata> {
        let bytes = [UInt8](data)
        let fileBytes = bytes.count
        let extensionName = fileExtension(of: path)

        switch extensionName {
        case "wav":
            return parseWAV(path: path, bytes: bytes, fileBytes: fileBytes)
        case "aif", "aiff":
            return parseAIFF(path: path, bytes: bytes, fileBytes: fileBytes)
        case "caf":
            return parseCAF(path: path, bytes: bytes, fileBytes: fileBytes)
        default:
            return .invalid(code: "unsupported sound container")
        }
    }

    private static func parseWAV(
        path: String,
        bytes: [UInt8],
        fileBytes: Int
    ) -> AssetCheck<SoundAssetMetadata> {
        guard bytes.count >= 12,
              ascii(bytes, 0, 4) == "RIFF",
              ascii(bytes, 8, 4) == "WAVE"
        else {
            return .invalid(code: "not a RIFF/WAVE file")
        }

        var isPCM = false
        var sampleRate: UInt32 = 0
        var byteRate: UInt32 = 0
        var dataBytes: Int?
        var offset = 12

        while offset + 8 <= bytes.count {
            guard let chunkName = ascii(bytes, offset, 4),
                  let chunkSize = uint32LE(bytes, offset + 4)
            else {
                break
            }

            let start = offset + 8
            let size = Int(chunkSize)

            if chunkName == "fmt " {
                guard size >= 16, start + 16 <= bytes.count else {
                    return .invalid(code: "WAV fmt chunk is truncated")
                }
                let format = uint16LE(bytes, start) ?? 0
                sampleRate = uint32LE(bytes, start + 4) ?? 0
                byteRate = uint32LE(bytes, start + 8) ?? 0
                isPCM = format == 1
                if format == 0xFFFE {
                    guard size >= 40, start + 26 <= bytes.count else {
                        return .invalid(code: "WAV extensible fmt chunk is truncated")
                    }
                    isPCM = uint16LE(bytes, start + 24) == 1
                }
            } else if chunkName == "data" {
                let available = max(0, bytes.count - start)
                dataBytes = min(size, available)
            }

            let padding = size & 1
            let (next, overflow) = start.addingReportingOverflow(size + padding)
            guard !overflow, next <= bytes.count else {
                break
            }
            offset = next
        }

        guard byteRate > 0, sampleRate > 0 else {
            return .invalid(code: "WAV has no usable sample rate")
        }
        guard let dataBytes else {
            return .invalid(code: "WAV has no data chunk")
        }

        return .available(SoundAssetMetadata(
            path: path,
            bytes: fileBytes,
            isPCM: isPCM,
            duration: Double(dataBytes) / Double(byteRate)
        ))
    }

    private static func parseAIFF(
        path: String,
        bytes: [UInt8],
        fileBytes: Int
    ) -> AssetCheck<SoundAssetMetadata> {
        guard bytes.count >= 12,
              ascii(bytes, 0, 4) == "FORM"
        else {
            return .invalid(code: "not an AIFF file")
        }

        let formType = ascii(bytes, 8, 4)
        guard formType == "AIFF" || formType == "AIFC" else {
            return .invalid(code: "not an AIFF file")
        }
        let isCompressed = formType == "AIFC"

        var sampleFrames: UInt32?
        var sampleRate: Double?
        var compression: String?
        var hasSoundData = false
        var offset = 12

        while offset + 8 <= bytes.count {
            guard let chunkName = ascii(bytes, offset, 4),
                  let chunkSize = uint32BE(bytes, offset + 4)
            else {
                break
            }

            let start = offset + 8
            let size = Int(chunkSize)

            if chunkName == "COMM" {
                guard size >= 18, start + 18 <= bytes.count else {
                    return .invalid(code: "AIFF COMM chunk is truncated")
                }
                sampleFrames = uint32BE(bytes, start + 2)
                guard let rate = extended80(bytes, start + 8), rate.isFinite, rate > 0 else {
                    return .invalid(code: "AIFF sample rate is invalid")
                }
                sampleRate = rate

                if isCompressed {
                    guard size >= 22, start + 22 <= bytes.count else {
                        return .invalid(code: "AIFC COMM chunk has no compression type")
                    }
                    compression = ascii(bytes, start + 18, 4)
                }
            } else if chunkName == "SSND" {
                hasSoundData = true
            }

            let padding = size & 1
            let (next, overflow) = start.addingReportingOverflow(size + padding)
            guard !overflow, next <= bytes.count else {
                break
            }
            offset = next
        }

        guard hasSoundData else {
            return .invalid(code: "AIFF has no SSND chunk")
        }
        guard let sampleFrames, let sampleRate else {
            return .invalid(code: "AIFF has no COMM chunk")
        }

        let pcmCompressionTypes: Set<String> = ["NONE", "twos", "sowt", "in24", "in32"]
        let isPCM = !isCompressed || pcmCompressionTypes.contains(compression ?? "")

        return .available(SoundAssetMetadata(
            path: path,
            bytes: fileBytes,
            isPCM: isPCM,
            duration: Double(sampleFrames) / sampleRate
        ))
    }

    private static func parseCAF(
        path: String,
        bytes: [UInt8],
        fileBytes: Int
    ) -> AssetCheck<SoundAssetMetadata> {
        guard bytes.count >= 8, ascii(bytes, 0, 4) == "caff" else {
            return .invalid(code: "not a CAF file")
        }
        guard uint16BE(bytes, 4) == 1 else {
            return .invalid(code: "unsupported CAF version")
        }

        var sampleRate: Double?
        var formatID: String?
        var formatFlags: UInt32?
        var bytesPerPacket: UInt32?
        var framesPerPacket: UInt32?
        var dataBytes: Int?
        var offset = 8

        while offset + 12 <= bytes.count {
            guard let chunkName = ascii(bytes, offset, 4),
                  let chunkSize = int64BE(bytes, offset + 4)
            else {
                break
            }

            let start = offset + 12

            if chunkName == "desc" {
                guard chunkSize >= 32, start + 32 <= bytes.count else {
                    return .invalid(code: "CAF desc chunk is truncated")
                }
                guard let rate = doubleBE(bytes, start), rate.isFinite, rate > 0 else {
                    return .invalid(code: "CAF sample rate is invalid")
                }
                sampleRate = rate
                formatID = ascii(bytes, start + 8, 4)
                formatFlags = uint32BE(bytes, start + 12)
                bytesPerPacket = uint32BE(bytes, start + 16)
                framesPerPacket = uint32BE(bytes, start + 20)
            } else if chunkName == "data" {
                let available = max(0, bytes.count - start)
                if chunkSize < 0 {
                    dataBytes = available
                    break
                }
                dataBytes = min(Int(chunkSize), available)
            }

            guard chunkSize >= 0 else {
                break
            }
            let (next, overflow) = start.addingReportingOverflow(Int(chunkSize))
            guard !overflow, next <= bytes.count else {
                break
            }
            offset = next
        }

        guard let sampleRate,
              let formatID,
              let formatFlags,
              let bytesPerPacket,
              let framesPerPacket
        else {
            return .invalid(code: "CAF has no desc chunk")
        }
        guard let dataBytes else {
            return .invalid(code: "CAF has no data chunk")
        }
        guard bytesPerPacket > 0, framesPerPacket > 0 else {
            return .invalid(code: "CAF desc has no usable packet size")
        }

        let isPCM = formatID == "lpcm" && (formatFlags & 0x1) == 0
        let frames = (Double(dataBytes) / Double(bytesPerPacket)) * Double(framesPerPacket)

        return .available(SoundAssetMetadata(
            path: path,
            bytes: fileBytes,
            isPCM: isPCM,
            duration: frames / sampleRate
        ))
    }

    // MARK: - Byte helpers

    private static func ascii(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String? {
        guard offset >= 0, length > 0, offset + length <= bytes.count else {
            return nil
        }
        return String(bytes: bytes[offset..<(offset + length)], encoding: .ascii)
    }

    private static func uint16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else {
            return nil
        }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint16BE(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else {
            return nil
        }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func uint32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }
        return (UInt32(bytes[offset]))
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func uint32BE(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else {
            return nil
        }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func uint64BE(_ bytes: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else {
            return nil
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(bytes[offset + index])
        }
        return value
    }

    private static func int64BE(_ bytes: [UInt8], _ offset: Int) -> Int64? {
        guard let value = uint64BE(bytes, offset) else {
            return nil
        }
        return Int64(bitPattern: value)
    }

    private static func doubleBE(_ bytes: [UInt8], _ offset: Int) -> Double? {
        guard let bits = uint64BE(bytes, offset) else {
            return nil
        }
        return Double(bitPattern: bits)
    }

    private static func extended80(_ bytes: [UInt8], _ offset: Int) -> Double? {
        guard offset >= 0, offset + 10 <= bytes.count else {
            return nil
        }
        let signExponent = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
        let exponent = Int(signExponent & 0x7FFF)
        let isNegative = (signExponent & 0x8000) != 0

        var mantissa: UInt64 = 0
        for index in 2..<10 {
            mantissa = (mantissa << 8) | UInt64(bytes[offset + index])
        }

        if exponent == 0 && mantissa == 0 {
            return isNegative ? -0.0 : 0.0
        }
        if exponent == 0x7FFF {
            return mantissa == 0 ? (isNegative ? -.infinity : .infinity) : nil
        }

        let value = Double(mantissa) * pow(2.0, Double(exponent - 16_383 - 63))
        return isNegative ? -value : value
    }

    private static func fileExtension(of path: String) -> String {
        guard let separator = path.lastIndex(of: ".") else {
            return ""
        }
        return path[path.index(after: separator)...].lowercased()
    }

    // MARK: - Diagnostics

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
