import Foundation

/// Pure manifest and asset validation. It never touches the filesystem.
public enum SkinValidator {
    public static let maximumPaletteEntries = 12
    public static let maximumAudioReactive = 0.3
    public static let maximumOrbFrames = 60
    public static let maximumImageBytes = 4_000_000
    public static let maximumSoundBytes = 1_000_000
    public static let maximumSoundDuration = 3.0
    public static let maximumImageDimension = PNGHeader.maximumDimension
    public static let maximumImagePixels = PNGHeader.maxPixels

    private static let semverPattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-((?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"#

    private struct ExpectedImage {
        let path: String
        let group: SkinGroup
        let manifestPath: [SkinDiagnostic.PathSegment]
        let isOrbFrame: Bool
        let orbState: SkinOrbState.Known?

        init(
            path: String,
            group: SkinGroup,
            manifestPath: [SkinDiagnostic.PathSegment],
            isOrbFrame: Bool,
            orbState: SkinOrbState.Known? = nil
        ) {
            self.path = path
            self.group = group
            self.manifestPath = manifestPath
            self.isOrbFrame = isOrbFrame
            self.orbState = orbState
        }
    }

    public static func validate(
        document: SkinManifestDocument,
        assets: any SkinAssetChecking,
        context: SkinValidationContext
    ) -> SkinValidationResult {
        var diagnostics = document.diagnostics

        guard var manifest = document.manifest else {
            return result(
                document: document,
                manifest: nil,
                diagnostics: diagnostics,
                groups: Dictionary(uniqueKeysWithValues: SkinGroup.allCases.map { ($0, .absent) })
            )
        }

        guard !diagnostics.contains(where: { $0.severity == .fatal }) else {
            return rejected(document: document, manifest: manifest, diagnostics: diagnostics)
        }

        if let base = manifest.base, !context.availableBaseIDs.contains(base) {
            diagnostics.append(warning(
                code: "base-unavailable",
                path: [.key("base")],
                message: "Base skin '\(base)' is not installed; falling back to webby.clear."
            ))
            manifest = manifest.replacingBase("webby.clear")
        }

        validateMetadata(manifest, context: context, diagnostics: &diagnostics)
        guard !diagnostics.contains(where: { $0.severity == .fatal }) else {
            return rejected(document: document, manifest: manifest, diagnostics: diagnostics)
        }

        var expectedImages: [ExpectedImage] = []
        validateGroups(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateAssets(
            manifest,
            expectedImages: expectedImages,
            assets: assets,
            isBuiltIn: context.isBuiltIn,
            diagnostics: &diagnostics
        )

        let groups = groupStatuses(manifest: manifest, diagnostics: diagnostics)
        return result(document: document, manifest: manifest, diagnostics: diagnostics, groups: groups)
    }

    private static func result(
        document: SkinManifestDocument,
        manifest: SkinManifest?,
        diagnostics: [SkinDiagnostic],
        groups: [SkinGroup: SkinGroupStatus]
    ) -> SkinValidationResult {
        SkinValidationResult(
            document: document,
            manifest: manifest,
            isAccepted: !diagnostics.contains { $0.severity == .fatal },
            diagnostics: diagnostics,
            groups: groups
        )
    }

    private static func rejected(
        document: SkinManifestDocument,
        manifest: SkinManifest,
        diagnostics: [SkinDiagnostic]
    ) -> SkinValidationResult {
        result(
            document: document,
            manifest: manifest,
            diagnostics: diagnostics,
            groups: Dictionary(uniqueKeysWithValues: SkinGroup.allCases.map { ($0, .invalid) })
        )
    }

    // MARK: - Metadata

    private static func validateMetadata(
        _ manifest: SkinManifest,
        context: SkinValidationContext,
        diagnostics: inout [SkinDiagnostic]
    ) {
        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(SkinDiagnostic(
                code: "empty-name",
                severity: .fatal,
                path: [.key("name")],
                message: "Skin name must not be empty."
            ))
        }

        if manifest.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(SkinDiagnostic(
                code: "empty-author",
                severity: .fatal,
                path: [.key("author")],
                message: "Skin author must not be empty."
            ))
        }

        if !isSemver(manifest.version) {
            diagnostics.append(SkinDiagnostic(
                code: "invalid-version",
                severity: .fatal,
                path: [.key("version")],
                message: "Skin version '\(manifest.version)' is not semver 2.0."
            ))
        }

        if !isReverseDNS(manifest.id) {
            diagnostics.append(SkinDiagnostic(
                code: "invalid-id",
                severity: .fatal,
                path: [.key("id")],
                message: "Skin id '\(manifest.id)' is not a reverse-DNS identifier."
            ))
        }

        if !context.isBuiltIn, manifest.id.lowercased().hasPrefix("webby.") {
            diagnostics.append(SkinDiagnostic(
                code: "reserved-id-prefix",
                severity: .fatal,
                path: [.key("id")],
                message: "The 'webby.' id prefix is reserved for built-in skins."
            ))
        }
    }

    private static func isSemver(_ value: String) -> Bool {
        value.range(of: semverPattern, options: .regularExpression) != nil
    }

    private static func isReverseDNS(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }

        return labels.allSatisfy { label in
            guard let first = label.first, first.isLowercase, first.isLetter else {
                return false
            }
            guard !label.hasSuffix("-") else {
                return false
            }
            return label.allSatisfy { character in
                character.isLowercase || character.isNumber || character == "-"
            }
        }
    }

    // MARK: - Groups

    private static func validateGroups(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        validatePalette(manifest, diagnostics: &diagnostics)
        validateSurface(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateTypography(manifest, diagnostics: &diagnostics)
        validateHeader(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateCollapsed(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateDecoration(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateIcons(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateResizeHandle(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateLibrary(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateVoiceOrb(manifest, diagnostics: &diagnostics, expectedImages: &expectedImages)
        validateSounds(manifest, diagnostics: &diagnostics)
        validateHighContrast(manifest, diagnostics: &diagnostics)
    }

    private static func validatePalette(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard let palette = manifest.palette else {
            return
        }

        if palette.count > maximumPaletteEntries {
            diagnostics.append(groupError(
                code: "palette-too-large",
                path: [.key("palette"), .index(maximumPaletteEntries)],
                group: .palette,
                message: "A palette may contain at most \(maximumPaletteEntries) entries."
            ))
        }

        for (index, color) in palette.enumerated() {
            checkColor(
                color,
                path: [.key("palette"), .index(index)],
                group: .palette,
                diagnostics: &diagnostics
            )
        }
    }

    private static func validateSurface(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let surface = manifest.surface else {
            return
        }

        checkColor(surface.fill, path: [.key("surface"), .key("fill")], group: .surface, diagnostics: &diagnostics)

        if let material = surface.material {
            checkKnownAppearance(
                material,
                path: [.key("surface"), .key("material")],
                group: .surface,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }

        if let image = surface.image {
            if let element = image.element {
                if SkinImageElement(rawValue: element) == nil {
                    diagnostics.append(groupError(
                        code: "unknown-image-element",
                        path: [.key("surface"), .key("image"), .key("element")],
                        group: .surface,
                        message: "Unknown image element '\(element)'."
                    ))
                } else {
                    expectedImages.append(ExpectedImage(
                        path: "images/\(element).png",
                        group: .surface,
                        manifestPath: [.key("surface"), .key("image"), .key("element")],
                        isOrbFrame: false
                    ))
                }
            } else {
                diagnostics.append(groupError(
                    code: "missing-image-element",
                    path: [.key("surface"), .key("image"), .key("element")],
                    group: .surface,
                    message: "A surface image requires an element."
                ))
            }

            if let insets = image.insets {
                checkInsets(
                    insets,
                    path: [.key("surface"), .key("image"), .key("insets")],
                    group: .surface,
                    diagnostics: &diagnostics
                )
            } else {
                diagnostics.append(groupError(
                    code: "missing-nine-slice-insets",
                    path: [.key("surface"), .key("image"), .key("insets")],
                    group: .surface,
                    message: "A nine-slice surface image requires insets."
                ))
            }

            if let mode = image.mode {
                checkKnown(
                    mode,
                    path: [.key("surface"), .key("image"), .key("mode")],
                    group: .surface,
                    diagnostics: &diagnostics,
                    rawValue: \.rawValue,
                    isKnown: { if case .known = $0 { return true } else { return false } }
                )
            }
        }

        if let cornerRadius = surface.cornerRadius {
            _ = clamped(
                cornerRadius,
                to: 0...32,
                path: [.key("surface"), .key("cornerRadius")],
                group: .surface,
                diagnostics: &diagnostics
            )
        }

        if let border = surface.border {
            if let width = border.width {
                _ = clamped(
                    width,
                    to: 0...4,
                    path: [.key("surface"), .key("border"), .key("width")],
                    group: .surface,
                    diagnostics: &diagnostics
                )
            }
            checkColor(
                border.color,
                path: [.key("surface"), .key("border"), .key("color")],
                group: .surface,
                diagnostics: &diagnostics
            )
        }

        if let shadow = surface.shadow {
            checkKnown(
                shadow,
                path: [.key("surface"), .key("shadow")],
                group: .surface,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }

        if let padding = surface.padding {
            checkInsets(
                padding,
                path: [.key("surface"), .key("padding")],
                group: .surface,
                diagnostics: &diagnostics
            )
        }

        if let text = surface.text {
            checkColor(
                text.color,
                path: [.key("surface"), .key("text"), .key("color")],
                group: .surface,
                diagnostics: &diagnostics
            )
        }

        checkColor(
            surface.placeholderColor,
            path: [.key("surface"), .key("placeholderColor")],
            group: .surface,
            diagnostics: &diagnostics
        )
        checkColor(
            surface.selection,
            path: [.key("surface"), .key("selection")],
            group: .surface,
            diagnostics: &diagnostics
        )
        checkColor(
            surface.caret,
            path: [.key("surface"), .key("caret")],
            group: .surface,
            diagnostics: &diagnostics
        )
    }

    private static func validateTypography(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard let typography = manifest.typography else {
            return
        }

        if let size = typography.size {
            _ = clamped(
                size,
                to: 10...32,
                path: [.key("typography"), .key("size")],
                group: .typography,
                diagnostics: &diagnostics
            )
        }

        if let lineSpacing = typography.lineSpacing {
            _ = nonNegative(
                lineSpacing,
                path: [.key("typography"), .key("lineSpacing")],
                group: .typography,
                diagnostics: &diagnostics
            )
        }

        if let weight = typography.weight {
            checkKnown(
                weight,
                path: [.key("typography"), .key("weight")],
                group: .typography,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }
    }

    private static func validateHeader(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let header = manifest.header else {
            return
        }

        var isVisible = true
        if let height = header.height {
            if !height.isFinite {
                reportNonFinite(
                    path: [.key("header"), .key("height")],
                    group: .header,
                    diagnostics: &diagnostics
                )
                isVisible = false
            } else if height == 0 {
                isVisible = false
            } else if height < 16 || height > 36 {
                let replacement = height < 0 ? 0 : min(max(height, 16), 36)
                if replacement == 0 {
                    isVisible = false
                }
                diagnostics.append(warning(
                    code: "value-clamped",
                    path: [.key("header"), .key("height")],
                    group: .header,
                    message: "Header height \(height) is outside 0 or 16...36; using \(replacement)."
                ))
            }
        }

        if isVisible {
            expectedImages.append(ExpectedImage(
                path: "images/note-header.png",
                group: .header,
                manifestPath: [.key("header"), .key("height")],
                isOrbFrame: false
            ))
        }

        checkColor(
            header.fill,
            path: [.key("header"), .key("fill")],
            group: .header,
            diagnostics: &diagnostics
        )
    }

    private static func validateCollapsed(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let collapsed = manifest.collapsed else {
            return
        }

        if let height = collapsed.height {
            _ = clamped(
                height,
                to: 1...200,
                path: [.key("collapsed"), .key("height")],
                group: .collapsed,
                diagnostics: &diagnostics
            )
        }

        expectedImages.append(ExpectedImage(
            path: "images/note-collapsed.png",
            group: .collapsed,
            manifestPath: [.key("collapsed")],
            isOrbFrame: false
        ))
    }

    private static func validateDecoration(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let decoration = manifest.decoration else {
            return
        }

        if let element = decoration.element {
            if SkinImageElement(rawValue: element) == nil {
                diagnostics.append(groupError(
                    code: "unknown-decoration-element",
                    path: [.key("decoration"), .key("element")],
                    group: .decoration,
                    message: "Unknown decoration element '\(element)'."
                ))
            } else if decoration.hidden != true {
                expectedImages.append(ExpectedImage(
                    path: "images/\(element).png",
                    group: .decoration,
                    manifestPath: [.key("decoration"), .key("element")],
                    isOrbFrame: false
                ))
            }
        } else if decoration.hidden != true {
            diagnostics.append(groupError(
                code: "missing-decoration-element",
                path: [.key("decoration"), .key("element")],
                group: .decoration,
                message: "A visible decoration requires an element."
            ))
        }

        if let anchor = decoration.anchor {
            checkKnown(
                anchor,
                path: [.key("decoration"), .key("anchor")],
                group: .decoration,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }

        if let origin = decoration.origin {
            checkKnown(
                origin,
                path: [.key("decoration"), .key("origin")],
                group: .decoration,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }

        if let offset = decoration.offset {
            checkFinite(offset.x, path: [.key("decoration"), .key("offset"), .key("x")], group: .decoration, diagnostics: &diagnostics)
            checkFinite(offset.y, path: [.key("decoration"), .key("offset"), .key("y")], group: .decoration, diagnostics: &diagnostics)
        }

        checkFinite(
            decoration.rotation,
            path: [.key("decoration"), .key("rotation")],
            group: .decoration,
            diagnostics: &diagnostics
        )
    }

    private static func validateIcons(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let icons = manifest.icons else {
            return
        }

        checkColor(
            icons.tint,
            path: [.key("icons"), .key("tint")],
            group: .icons,
            diagnostics: &diagnostics
        )

        for element in [
            SkinImageElement.iconCollapse,
            .iconExpand,
            .iconClose,
            .iconMore,
        ] {
            expectedImages.append(ExpectedImage(
                path: "images/\(element.rawValue).png",
                group: .icons,
                manifestPath: [.key("icons")],
                isOrbFrame: false
            ))
        }
    }

    private static func validateResizeHandle(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let resizeHandle = manifest.resizeHandle else {
            return
        }

        var needsAsset = true
        if let visibility = resizeHandle.visibility {
            checkKnown(
                visibility,
                path: [.key("resizeHandle"), .key("visibility")],
                group: .resizeHandle,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
            if case .known(.never) = visibility {
                needsAsset = false
            }
        }

        if needsAsset {
            expectedImages.append(ExpectedImage(
                path: "images/resize-handle.png",
                group: .resizeHandle,
                manifestPath: [.key("resizeHandle")],
                isOrbFrame: false
            ))
        }

        checkColor(
            resizeHandle.tint,
            path: [.key("resizeHandle"), .key("tint")],
            group: .resizeHandle,
            diagnostics: &diagnostics
        )
    }

    private static func validateLibrary(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let library = manifest.library else {
            return
        }

        checkColor(
            library.accent,
            path: [.key("library"), .key("accent")],
            group: .library,
            diagnostics: &diagnostics
        )
        checkColor(
            library.background,
            path: [.key("library"), .key("background")],
            group: .library,
            diagnostics: &diagnostics
        )

        if let material = library.sidebarMaterial {
            checkKnown(
                material,
                path: [.key("library"), .key("sidebarMaterial")],
                group: .library,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }

        if let cardStyle = library.cardStyle {
            checkKnown(
                cardStyle,
                path: [.key("library"), .key("cardStyle")],
                group: .library,
                diagnostics: &diagnostics,
                rawValue: \.rawValue,
                isKnown: { if case .known = $0 { return true } else { return false } }
            )
        }

        expectedImages.append(ExpectedImage(
            path: "images/library-empty.png",
            group: .library,
            manifestPath: [.key("library")],
            isOrbFrame: false
        ))
    }

    private static func validateVoiceOrb(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic],
        expectedImages: inout [ExpectedImage]
    ) {
        guard let voiceOrb = manifest.voiceOrb, let states = voiceOrb.states else {
            return
        }

        for (state, animation) in states.animations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let statePath = [SkinDiagnostic.PathSegment.key("voiceOrb"), .key("states"), .key(state.rawValue)]

            guard case .known(let knownState) = state else {
                diagnostics.append(groupError(
                    code: "unknown-orb-state",
                    path: statePath,
                    group: .voiceOrb,
                    message: "Unknown orb state '\(state.rawValue)'."
                ))
                continue
            }

            var frameCount: Int?
            if let frames = animation.frames {
                frameCount = clamped(
                    frames,
                    to: 1...maximumOrbFrames,
                    path: statePath + [.key("frames")],
                    group: .voiceOrb,
                    diagnostics: &diagnostics
                )
            }

            if let fps = animation.fps {
                if fps.isFinite {
                    if fps < 0 && fps != -1 {
                        diagnostics.append(warning(
                            code: "value-clamped",
                            path: statePath + [.key("fps")],
                            group: .voiceOrb,
                            message: "Orb fps \(fps) is invalid; using -1."
                        ))
                    }
                } else {
                    reportNonFinite(path: statePath + [.key("fps")], group: .voiceOrb, diagnostics: &diagnostics)
                }
            }

            if let audioReactive = animation.audioReactive {
                _ = clamped(
                    audioReactive,
                    to: 0...maximumAudioReactive,
                    path: statePath + [.key("audioReactive")],
                    group: .voiceOrb,
                    diagnostics: &diagnostics
                )
            }

            checkColor(
                animation.tint,
                path: statePath + [.key("tint")],
                group: .voiceOrb,
                diagnostics: &diagnostics
            )

            if let frameCount {
                for frame in 0..<frameCount {
                    expectedImages.append(ExpectedImage(
                        path: "images/\(SkinAsset.orbKey(state: knownState, frame: frame)).png",
                        group: .voiceOrb,
                        manifestPath: statePath + [.key("frames")],
                        isOrbFrame: true,
                        orbState: knownState
                    ))
                }
            }
        }
    }

    private static func validateSounds(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard let sounds = manifest.sounds else {
            return
        }

        if let volume = sounds.volume {
            _ = clamped(
                volume,
                to: 0...1,
                path: [.key("sounds"), .key("volume")],
                group: .sounds,
                diagnostics: &diagnostics
            )
        }

        if let mute = sounds.mute {
            for (index, event) in mute.enumerated() {
                checkKnown(
                    event,
                    path: [.key("sounds"), .key("mute"), .index(index)],
                    group: .sounds,
                    diagnostics: &diagnostics,
                    rawValue: \.rawValue,
                    isKnown: { if case .known = $0 { return true } else { return false } }
                )
            }
        }
    }

    private static func validateHighContrast(
        _ manifest: SkinManifest,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard let highContrast = manifest.highContrast else {
            return
        }

        checkColor(
            highContrast.surfaceFill,
            path: [.key("highContrast"), .key("surface.fill")],
            group: "highContrast",
            diagnostics: &diagnostics
        )
        checkColor(
            highContrast.surfaceTextColor,
            path: [.key("highContrast"), .key("surface.text.color")],
            group: "highContrast",
            diagnostics: &diagnostics
        )
    }

    // MARK: - Assets

    /// Built-in skins draw header, collapsed, icon, resize, library and orb chrome in
    /// code, so their absent implicit artwork is not a diagnostic. Explicit surface
    /// and decoration artwork still has to exist.
    private static let builtInImplicitAssetGroups: Set<String> = [
        "header", "collapsed", "icons", "resizeHandle", "library", "voiceOrb",
    ]

    /// Groups that reference an image element, used when a variant file such as
    /// `images/note-body~dark@2x.png` is invalid: the base name never appears in
    /// `expectedByPath`, so the owning group has to be recovered from the asset.
    private static func groupsReferencingImage(path: String) -> [SkinGroup] {
        guard case .accepted(let entry) = SkinEntryRules.classify(path),
              let asset = entry.asset
        else {
            return []
        }
        switch asset.kind {
        case .image:
            guard let element = asset.element else { return [] }
            switch element {
            case .noteBody: return [.surface]
            case .noteHeader: return [.header]
            case .noteCollapsed: return [.collapsed]
            case .decoration: return [.decoration]
            case .iconCollapse, .iconExpand, .iconClose, .iconMore: return [.icons]
            case .resizeHandle: return [.resizeHandle]
            case .libraryEmpty: return [.library]
            }
        case .orb:
            return [.voiceOrb]
        case .sound:
            return [.sounds]
        }
    }

    private static func validateAssets(
        _ manifest: SkinManifest,
        expectedImages: [ExpectedImage],
        assets: any SkinAssetChecking,
        isBuiltIn: Bool,
        diagnostics: inout [SkinDiagnostic]
    ) {
        let inventory = assets.inventory()
        var inventoryImagePaths: Set<String> = []
        var inventorySoundPaths: Set<String> = []

        for record in inventory {
            guard case .accepted(let entry) = SkinEntryRules.classify(record.path),
                  let asset = entry.asset
            else {
                continue
            }
            switch asset.kind {
            case .image, .orb:
                inventoryImagePaths.insert(record.path)
            case .sound:
                inventorySoundPaths.insert(record.path)
            }
        }

        let expectedByPath = Dictionary(grouping: expectedImages, by: \.path)
        let allImagePaths = Set(expectedByPath.keys).union(inventoryImagePaths).sorted()
        let appearances = Set(manifest.appearances ?? [])
        var presentImagePaths: Set<String> = []
        var totalPixels = 0
        var pixelBudgetReported = false
        var reportedVariants: Set<String> = []
        var missingOrbFrames: [ExpectedImage] = []

        for path in allImagePaths {
            let expected = expectedByPath[path] ?? []
            let groups = orderedGroups(expected.map(\.group) + groupsReferencingImage(path: path))
            let check = assets.image(path)

            switch check {
            case .missing:
                if expected.isEmpty {
                    for group in groups {
                        diagnostics.append(warning(
                            code: "missing-asset",
                            path: [],
                            group: group,
                            assetPath: path,
                            message: "Asset '\(path)' is listed but missing."
                        ))
                    }
                } else {
                    for item in expected {
                        if item.isOrbFrame {
                            missingOrbFrames.append(item)
                        } else if isBuiltIn && builtInImplicitAssetGroups.contains(item.group.rawValue) {
                            continue
                        } else {
                            diagnostics.append(warning(
                                code: "missing-asset",
                                path: item.manifestPath,
                                group: item.group,
                                assetPath: path,
                                message: "Asset '\(path)' is missing."
                            ))
                        }
                    }
                }

            case .invalid(let code):
                reportAssetError(
                    code: "invalid-asset",
                    groups: groups,
                    path: path,
                    message: "Asset '\(path)' is invalid: \(code).",
                    diagnostics: &diagnostics
                )

            case .available(let metadata):
                presentImagePaths.insert(path)
                if metadata.bytes < 0 || metadata.bytes > maximumImageBytes {
                    reportAssetError(
                        code: "image-too-large",
                        groups: groups,
                        path: path,
                        message: "Image '\(path)' is \(metadata.bytes) bytes; the limit is \(maximumImageBytes).",
                        diagnostics: &diagnostics
                    )
                }

                let width = metadata.png.width
                let height = metadata.png.height
                if width <= 0 || height <= 0 || width > maximumImageDimension || height > maximumImageDimension {
                    reportAssetError(
                        code: "image-dimension-exceeded",
                        groups: groups,
                        path: path,
                        message: "Image '\(path)' is \(width)x\(height); each side must be 1...\(maximumImageDimension).",
                        diagnostics: &diagnostics
                    )
                } else if let pixels = metadata.png.pixelCount {
                    let (sum, overflow) = totalPixels.addingReportingOverflow(pixels)
                    if overflow || sum > maximumImagePixels {
                        totalPixels = maximumImagePixels
                        if !pixelBudgetReported {
                            pixelBudgetReported = true
                            diagnostics.append(SkinDiagnostic(
                                code: "pixel-budget-exceeded",
                                severity: .fatal,
                                path: [],
                                assetPath: path,
                                message: "Decoded skin images exceed \(maximumImagePixels) pixels."
                            ))
                        }
                    } else {
                        totalPixels = sum
                    }
                } else {
                    reportAssetError(
                        code: "image-pixel-overflow",
                        groups: groups,
                        path: path,
                        message: "Image '\(path)' has overflowing dimensions.",
                        diagnostics: &diagnostics
                    )
                }
            }
        }

        for item in missingOrbFrames {
            let hasPresentSibling = expectedImages.contains { other in
                other.orbState == item.orbState
                    && other.group == item.group
                    && presentImagePaths.contains(other.path)
            }
            if isBuiltIn && !hasPresentSibling {
                // Built-ins draw the orb in code when they ship no frames.
                continue
            }
            if hasPresentSibling {
                diagnostics.append(groupError(
                    code: "missing-orb-frame",
                    path: item.manifestPath,
                    group: item.group,
                    assetPath: item.path,
                    message: "Orb frame asset '\(item.path)' is missing."
                ))
            } else {
                diagnostics.append(warning(
                    code: "missing-asset",
                    path: item.manifestPath,
                    group: item.group,
                    assetPath: item.path,
                    message: "Asset '\(item.path)' is missing."
                ))
            }
        }

        validateImageVariants(
            expectedImages: expectedImages,
            presentPaths: presentImagePaths,
            appearances: appearances,
            diagnostics: &diagnostics,
            reported: &reportedVariants
        )

        for path in inventorySoundPaths.sorted() {
            switch assets.sound(path) {
            case .missing:
                diagnostics.append(warning(
                    code: "missing-asset",
                    path: [],
                    group: .sounds,
                    assetPath: path,
                    message: "Sound '\(path)' is listed but missing."
                ))
            case .invalid(let code):
                diagnostics.append(groupError(
                    code: "invalid-asset",
                    path: [],
                    group: .sounds,
                    assetPath: path,
                    message: "Sound '\(path)' is invalid: \(code)."
                ))
            case .available(let metadata):
                if metadata.bytes < 0 || metadata.bytes > maximumSoundBytes {
                    diagnostics.append(groupError(
                        code: "sound-too-large",
                        path: [],
                        group: .sounds,
                        assetPath: path,
                        message: "Sound '\(path)' is \(metadata.bytes) bytes; the limit is \(maximumSoundBytes)."
                    ))
                }
                if !metadata.isPCM {
                    diagnostics.append(groupError(
                        code: "sound-not-pcm",
                        path: [],
                        group: .sounds,
                        assetPath: path,
                        message: "Sound '\(path)' is not PCM."
                    ))
                }
                if !metadata.duration.isFinite {
                    diagnostics.append(groupError(
                        code: "non-finite-number",
                        path: [],
                        group: .sounds,
                        assetPath: path,
                        message: "Sound '\(path)' has a non-finite duration."
                    ))
                } else if metadata.duration < 0 || metadata.duration > maximumSoundDuration {
                    diagnostics.append(groupError(
                        code: "sound-duration-exceeded",
                        path: [],
                        group: .sounds,
                        assetPath: path,
                        message: "Sound '\(path)' lasts \(metadata.duration)s; the limit is \(maximumSoundDuration)s."
                    ))
                }
            }
        }
    }

    private static func validateImageVariants(
        expectedImages: [ExpectedImage],
        presentPaths: Set<String>,
        appearances: Set<SkinAppearance>,
        diagnostics: inout [SkinDiagnostic],
        reported: inout Set<String>
    ) {
        for image in expectedImages {
            guard presentPaths.contains(image.path) else {
                continue
            }

            let retinaPath = variantPath(image.path, token: "@2x")
            let retinaKey = "2x|\(image.group.rawValue)|\(retinaPath)"
            if !presentPaths.contains(retinaPath), reported.insert(retinaKey).inserted {
                diagnostics.append(warning(
                    code: "image-missing-at2x",
                    path: image.manifestPath,
                    group: image.group,
                    assetPath: retinaPath,
                    message: "Image '\(image.path)' has no @2x variant."
                ))
            }

            guard appearances.contains(.dark) else {
                continue
            }

            let darkPath = variantPath(image.path, token: "~dark")
            let darkKey = "dark|\(image.group.rawValue)|\(darkPath)"
            if !presentPaths.contains(darkPath), reported.insert(darkKey).inserted {
                diagnostics.append(warning(
                    code: "missing-dark-variant",
                    path: image.manifestPath,
                    group: image.group,
                    assetPath: darkPath,
                    message: "Dark variant '\(darkPath)' is missing."
                ))
            }
        }
    }

    private static func variantPath(_ path: String, token: String) -> String {
        guard path.hasSuffix(".png") else {
            return path
        }
        var stem = String(path.dropLast(4))
        if stem.hasSuffix("@2x") {
            stem.removeLast(3)
            return "\(stem)\(token)@2x.png"
        }
        return "\(stem)\(token).png"
    }

    private static func reportAssetError(
        code: String,
        groups: [SkinGroup],
        path: String,
        message: String,
        diagnostics: inout [SkinDiagnostic]
    ) {
        if groups.isEmpty {
            diagnostics.append(groupError(
                code: code,
                path: [],
                group: nil,
                assetPath: path,
                message: message
            ))
        } else {
            for group in groups {
                diagnostics.append(groupError(
                    code: code,
                    path: [],
                    group: group,
                    assetPath: path,
                    message: message
                ))
            }
        }
    }

    private static func orderedGroups(_ groups: [SkinGroup]) -> [SkinGroup] {
        var seen: Set<SkinGroup> = []
        var ordered: [SkinGroup] = []
        for group in groups where seen.insert(group).inserted {
            ordered.append(group)
        }
        return ordered
    }

    // MARK: - Diagnostics

    private static func groupError(
        code: String,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup?,
        assetPath: String? = nil,
        message: String
    ) -> SkinDiagnostic {
        SkinDiagnostic(
            code: code,
            severity: .groupError,
            path: path,
            group: group?.rawValue,
            assetPath: assetPath,
            message: message
        )
    }

    private static func warning(
        code: String,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup? = nil,
        assetPath: String? = nil,
        message: String
    ) -> SkinDiagnostic {
        SkinDiagnostic(
            code: code,
            severity: .warning,
            path: path,
            group: group?.rawValue,
            assetPath: assetPath,
            message: message
        )
    }

    private static func groupStatuses(
        manifest: SkinManifest,
        diagnostics: [SkinDiagnostic]
    ) -> [SkinGroup: SkinGroupStatus] {
        var statuses: [SkinGroup: SkinGroupStatus] = [:]
        let isFatal = diagnostics.contains { $0.severity == .fatal }
        for group in SkinGroup.allCases {
            if isFatal {
                // A rejected skin exposes nothing usable, even for groups that had
                // no group-level error of their own.
                statuses[group] = isPresent(group, in: manifest) ? .invalid : .absent
                continue
            }
            if !isPresent(group, in: manifest) {
                statuses[group] = .absent
                continue
            }
            let hasError = diagnostics.contains {
                $0.severity == .groupError && $0.group == group.rawValue
            }
            statuses[group] = hasError ? .invalid : .usable
        }
        return statuses
    }

    private static func isPresent(_ group: SkinGroup, in manifest: SkinManifest) -> Bool {
        switch group {
        case .palette:
            return manifest.palette != nil
        case .surface:
            return manifest.surface != nil
        case .typography:
            return manifest.typography != nil
        case .header:
            return manifest.header != nil
        case .collapsed:
            return manifest.collapsed != nil
        case .decoration:
            return manifest.decoration != nil
        case .icons:
            return manifest.icons != nil
        case .resizeHandle:
            return manifest.resizeHandle != nil
        case .library:
            return manifest.library != nil
        case .voiceOrb:
            return manifest.voiceOrb != nil
        case .sounds:
            return manifest.sounds != nil
        }
    }

    // MARK: - Value checks

    private static func checkColor(
        _ color: SkinColor?,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) {
        checkColor(color, path: path, group: group.rawValue, diagnostics: &diagnostics)
    }

    private static func checkColor(
        _ color: SkinColor?,
        path: [SkinDiagnostic.PathSegment],
        group: String?,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard let color else {
            return
        }

        switch color {
        case .bare(let hex):
            checkHex(hex, path: path, group: group, diagnostics: &diagnostics)
        case .paired(let light, let dark):
            checkHex(light, path: path + [.key("light")], group: group, diagnostics: &diagnostics)
            checkHex(dark, path: path + [.key("dark")], group: group, diagnostics: &diagnostics)
        }
    }

    private static func checkHex(
        _ hex: String,
        path: [SkinDiagnostic.PathSegment],
        group: String?,
        diagnostics: inout [SkinDiagnostic]
    ) {
        do {
            _ = try RGBAColor(hex: hex)
        } catch {
            diagnostics.append(SkinDiagnostic(
                code: "invalid-color",
                severity: .groupError,
                path: path,
                group: group,
                message: "Color '\(hex)' is not #RRGGBB or #RRGGBBAA."
            ))
        }
    }

    private static func checkKnown<T>(
        _ value: T,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic],
        rawValue: KeyPath<T, String>,
        isKnown: (T) -> Bool
    ) {
        guard !isKnown(value) else {
            return
        }
        diagnostics.append(groupError(
            code: "unknown-enum-value",
            path: path,
            group: group,
            message: "Unknown value '\(value[keyPath: rawValue])'."
        ))
    }

    private static func checkKnownAppearance<T>(
        _ value: AppearanceValue<T>,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic],
        rawValue: KeyPath<T, String>,
        isKnown: (T) -> Bool
    ) {
        switch value {
        case .bare(let item):
            checkKnown(
                item,
                path: path,
                group: group,
                diagnostics: &diagnostics,
                rawValue: rawValue,
                isKnown: isKnown
            )
        case .paired(let light, let dark):
            checkKnown(
                light,
                path: path + [.key("light")],
                group: group,
                diagnostics: &diagnostics,
                rawValue: rawValue,
                isKnown: isKnown
            )
            checkKnown(
                dark,
                path: path + [.key("dark")],
                group: group,
                diagnostics: &diagnostics,
                rawValue: rawValue,
                isKnown: isKnown
            )
        }
    }

    private static func checkInsets(
        _ insets: SkinInsets,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) {
        if let value = insets.top {
            _ = nonNegative(value, path: path + [.key("top")], group: group, diagnostics: &diagnostics)
        }
        if let value = insets.left {
            _ = nonNegative(value, path: path + [.key("left")], group: group, diagnostics: &diagnostics)
        }
        if let value = insets.bottom {
            _ = nonNegative(value, path: path + [.key("bottom")], group: group, diagnostics: &diagnostics)
        }
        if let value = insets.right {
            _ = nonNegative(value, path: path + [.key("right")], group: group, diagnostics: &diagnostics)
        }
    }

    private static func checkFinite(
        _ value: Double?,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard let value else {
            return
        }
        if !value.isFinite {
            reportNonFinite(path: path, group: group, diagnostics: &diagnostics)
        }
    }

    private static func clamped(
        _ value: Double,
        to range: ClosedRange<Double>,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) -> Double {
        guard value.isFinite else {
            reportNonFinite(path: path, group: group, diagnostics: &diagnostics)
            return range.lowerBound
        }
        guard !range.contains(value) else {
            return value
        }

        let replacement = min(max(value, range.lowerBound), range.upperBound)
        diagnostics.append(warning(
            code: "value-clamped",
            path: path,
            group: group,
            message: "Value \(value) is outside \(range.lowerBound)...\(range.upperBound); using \(replacement)."
        ))
        return replacement
    }

    private static func clamped(
        _ value: Int,
        to range: ClosedRange<Int>,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) -> Int {
        guard !range.contains(value) else {
            return value
        }

        let replacement = min(max(value, range.lowerBound), range.upperBound)
        diagnostics.append(warning(
            code: "value-clamped",
            path: path,
            group: group,
            message: "Value \(value) is outside \(range.lowerBound)...\(range.upperBound); using \(replacement)."
        ))
        return replacement
    }

    private static func nonNegative(
        _ value: Double,
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) -> Double {
        guard value.isFinite else {
            reportNonFinite(path: path, group: group, diagnostics: &diagnostics)
            return 0
        }
        guard value < 0 else {
            return value
        }

        diagnostics.append(warning(
            code: "value-clamped",
            path: path,
            group: group,
            message: "Value \(value) must not be negative; using 0."
        ))
        return 0
    }

    private static func reportNonFinite(
        path: [SkinDiagnostic.PathSegment],
        group: SkinGroup,
        diagnostics: inout [SkinDiagnostic]
    ) {
        let alreadyReported = diagnostics.contains {
            $0.path == path
                && ($0.code == "non-finite-number" || $0.code == "non-finite-metadata")
        }
        guard !alreadyReported else {
            return
        }
        diagnostics.append(groupError(
            code: "non-finite-number",
            path: path,
            group: group,
            message: "Non-finite numbers are not allowed."
        ))
    }
}

private extension SkinManifest {
    func replacingBase(_ newBase: String?) -> SkinManifest {
        SkinManifest(
            schema: schema,
            formatVersion: formatVersion,
            id: id,
            name: name,
            author: author,
            version: version,
            description: description,
            license: license,
            basedOn: basedOn,
            base: newBase,
            credits: credits,
            tags: tags,
            appearances: appearances,
            palette: palette,
            surface: surface,
            typography: typography,
            header: header,
            collapsed: collapsed,
            decoration: decoration,
            icons: icons,
            resizeHandle: resizeHandle,
            library: library,
            voiceOrb: voiceOrb,
            sounds: sounds,
            highContrast: highContrast
        )
    }
}
