import Foundation

/// A loaded skin with its per-group validation outcome.
public struct InstalledSkin: Sendable, Equatable {
    public let id: String
    public let manifest: SkinManifest
    public let groups: [SkinGroup: SkinGroupStatus]
    /// Logical image paths the validated folder actually contained. `nil` means the
    /// caller did not supply an inventory; resolution then assumes the declared
    /// variants exist, which is only appropriate for in-memory fixture skins.
    public let availableImagePaths: Set<String>?

    public init(
        id: String,
        manifest: SkinManifest,
        groups: [SkinGroup: SkinGroupStatus]? = nil,
        availableImagePaths: Set<String>? = nil
    ) {
        self.id = id
        self.manifest = manifest
        self.groups = groups ?? Self.inferredGroups(for: manifest)
        self.availableImagePaths = availableImagePaths
    }

    private static func inferredGroups(for manifest: SkinManifest) -> [SkinGroup: SkinGroupStatus] {
        var groups: [SkinGroup: SkinGroupStatus] = [:]
        for group in SkinGroup.allCases {
            groups[group] = isPresent(group, in: manifest) ? .usable : .absent
        }
        return groups
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
}

public enum AppearanceMode: String, Sendable, Equatable, Hashable, CaseIterable {
    case light
    case dark
}

/// Resolves installed skins into one complete theme for a note.
///
/// Selection is workspace -> global -> `webby.clear`. Each element group falls
/// back as a unit along the selected skin's base chain. The surface and palette
/// are then checked together for text contrast, and accessibility settings are
/// applied last.
public struct SkinResolver: Sendable {
    public static let defaultSkinID = "webby.clear"

    private let builtIns: [InstalledSkin]
    private let availableBaseIDs: Set<String>

    public init(builtIns: [InstalledSkin], availableBaseIDs: Set<String>) {
        self.builtIns = builtIns
        self.availableBaseIDs = availableBaseIDs
    }

    public func resolve(
        workspaceSkinID: String?,
        globalSkinID: String?,
        requested: AppearanceMode,
        noteAppearance: NoteAppearance?,
        accessibility: AccessibilitySettings,
        textScale: Double
    ) -> ThemeResolution {
        let appearance: SkinAppearance = requested == .dark ? .dark : .light
        var diagnostics: [SkinDiagnostic] = []

        let workspaceSkin = workspaceSkinID.flatMap {
            selectedSkin(id: $0, key: "workspaceSkinID", diagnostics: &diagnostics)
        }
        let globalSkin = globalSkinID.flatMap {
            selectedSkin(id: $0, key: "globalSkinID", diagnostics: &diagnostics)
        }
        let clearSkin = selectedSkin(
            id: Self.defaultSkinID,
            key: "id",
            diagnostics: &diagnostics
        )

        let selected = workspaceSkin ?? globalSkin ?? clearSkin

        let paletteResolution = resolveGroup(.palette, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildPalette(manifest, sourceID: sourceID, appearance: appearance)
        }
        let surfaceResolution = resolveGroup(.surface, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildSurface(
                manifest,
                sourceID: sourceID,
                appearance: appearance,
                inventory: inventory(for: sourceID)
            )
        }
        let typographyResolution = resolveGroup(.typography, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, _, appearance in
            buildTypography(manifest, appearance: appearance)
        }
        let headerResolution = resolveGroup(.header, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildHeader(manifest, sourceID: sourceID, appearance: appearance)
        }
        let collapsedResolution = resolveGroup(.collapsed, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildCollapsed(manifest, sourceID: sourceID, appearance: appearance)
        }
        let decorationResolution = resolveGroup(.decoration, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildDecoration(manifest, sourceID: sourceID, appearance: appearance)
        }
        let iconsResolution = resolveGroup(.icons, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildIcons(manifest, sourceID: sourceID, appearance: appearance)
        }
        let resizeResolution = resolveGroup(.resizeHandle, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildResizeHandle(manifest, sourceID: sourceID, appearance: appearance)
        }
        let libraryResolution = resolveGroup(.library, from: globalSkin ?? clearSkin, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildLibrary(manifest, sourceID: sourceID, appearance: appearance)
        }
        let orbResolution = resolveGroup(.voiceOrb, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildOrb(manifest, sourceID: sourceID, appearance: appearance)
        }
        let soundsResolution = resolveGroup(.sounds, from: selected, appearance: appearance, diagnostics: &diagnostics) {
            manifest, sourceID, appearance in
            buildSounds(manifest, sourceID: sourceID, appearance: appearance)
        }

        var palette = paletteResolution?.value ?? []
        var surface = surfaceResolution?.value ?? Self.terminalSurface
        let typography = typographyResolution?.value ?? Self.terminalTypography
        let header = headerResolution?.value ?? Self.terminalHeader
        let collapsed = collapsedResolution?.value ?? Self.terminalCollapsed
        var decoration = decorationResolution?.value ?? Self.terminalDecoration
        let icons = iconsResolution?.value ?? Self.terminalIcons
        let resizeHandle = resizeResolution?.value ?? Self.terminalResizeHandle
        let library = libraryResolution?.value ?? Self.terminalLibrary
        let orb = orbResolution?.value ?? [:]
        let sounds = soundsResolution?.value ?? ResolvedSounds()

        var provenance: [SkinGroup: String] = [:]
        provenance[.palette] = paletteResolution?.sourceID ?? Self.defaultSkinID
        provenance[.surface] = surfaceResolution?.sourceID ?? Self.defaultSkinID
        provenance[.typography] = typographyResolution?.sourceID ?? Self.defaultSkinID
        provenance[.header] = headerResolution?.sourceID ?? Self.defaultSkinID
        provenance[.collapsed] = collapsedResolution?.sourceID ?? Self.defaultSkinID
        provenance[.decoration] = decorationResolution?.sourceID ?? Self.defaultSkinID
        provenance[.icons] = iconsResolution?.sourceID ?? Self.defaultSkinID
        provenance[.resizeHandle] = resizeResolution?.sourceID ?? Self.defaultSkinID
        provenance[.library] = libraryResolution?.sourceID ?? Self.defaultSkinID
        provenance[.voiceOrb] = orbResolution?.sourceID ?? Self.defaultSkinID
        provenance[.sounds] = soundsResolution?.sourceID ?? Self.defaultSkinID

        applyContrastUnit(
            surface: &surface,
            palette: &palette,
            typography: typography,
            appearance: appearance,
            selected: selected,
            textScale: textScale,
            provenance: &provenance,
            diagnostics: &diagnostics
        )

        if let requestedIndex = noteAppearance?.paletteIndex {
            if palette.indices.contains(requestedIndex) {
                // The selected slot is recorded below.
            } else {
                diagnostics.append(SkinDiagnostic(
                    code: "palette-index-out-of-range",
                    severity: .warning,
                    path: [.key("appearance"), .key("paletteIndex")],
                    group: SkinGroup.palette.rawValue,
                    message: "Palette index \(requestedIndex) is outside the resolved palette; using 0."
                ))
            }
        }
        if noteAppearance?.hideDecoration == true {
            decoration = ResolvedDecoration(
                image: decoration.image,
                anchor: decoration.anchor,
                origin: decoration.origin,
                offset: decoration.offset,
                rotation: decoration.rotation,
                hidden: true
            )
        }

        let selectedIndex: Int?
        if let requestedIndex = noteAppearance?.paletteIndex {
            selectedIndex = palette.indices.contains(requestedIndex) ? requestedIndex : 0
        } else {
            selectedIndex = nil
        }

        let theme = ResolvedTheme(
            skinID: selected?.id ?? Self.defaultSkinID,
            baseID: selected?.manifest.base ?? Self.defaultSkinID,
            surface: surface,
            typography: typography,
            header: header,
            collapsed: collapsed,
            decoration: decoration,
            icons: icons,
            resizeHandle: resizeHandle,
            palette: palette,
            selectedIndex: selectedIndex,
            library: library,
            orb: orb,
            sounds: sounds,
            accessibility: ResolvedAccessibility(),
            provenance: provenance,
            highContrast: resolveHighContrast(
                from: selected,
                appearance: appearance
            )
        )

        let transformed = AccessibilityTransform.apply(
            theme: theme,
            in: AccessibilitySettings(
                reduceTransparency: accessibility.reduceTransparency,
                increaseContrast: accessibility.increaseContrast,
                reduceMotion: accessibility.reduceMotion,
                textScale: textScale
            )
        )

        return ThemeResolution(
            theme: transformed.theme,
            diagnostics: deduplicated(diagnostics + transformed.diagnostics)
        )
    }

    // MARK: - Selection

    private func selectedSkin(
        id: String,
        key: String,
        diagnostics: inout [SkinDiagnostic]
    ) -> InstalledSkin? {
        guard let skin = builtIns.first(where: { $0.id == id }) else {
            diagnostics.append(SkinDiagnostic(
                code: "skin-not-installed",
                severity: .warning,
                path: [.key(key)],
                message: "Skin '\(id)' is not installed; falling back."
            ))
            return nil
        }

        guard !isFatal(skin) else {
            diagnostics.append(SkinDiagnostic(
                code: "skin-rejected",
                severity: .warning,
                path: [.key(key)],
                message: "Skin '\(id)' was rejected by validation; falling back."
            ))
            return nil
        }

        return skin
    }

    private func isFatal(_ skin: InstalledSkin) -> Bool {
        guard skin.manifest.formatVersion == 1 else {
            return true
        }
        guard !skin.groups.isEmpty else {
            return true
        }
        return SkinGroup.allCases.allSatisfy { skin.groups[$0] == .invalid }
    }

    // MARK: - Group resolution

    private func resolveGroup<T>(
        _ group: SkinGroup,
        from start: InstalledSkin?,
        appearance: SkinAppearance,
        diagnostics: inout [SkinDiagnostic],
        build: (SkinManifest, String, SkinAppearance) throws -> T?
    ) -> (value: T, sourceID: String)? {
        var current = start ?? Self.terminalSkin
        var seen: Set<String> = []

        while true {
            guard seen.insert(current.id).inserted else {
                diagnostics.append(cycleDiagnostic(group: group, skinID: current.id))
                break
            }

            let status = current.groups[group] ?? .absent
            if status == .usable {
                if let value = try? build(current.manifest, current.id, appearance) {
                    return (value, current.id)
                }
                diagnostics.append(SkinDiagnostic(
                    code: "group-unusable",
                    severity: .groupError,
                    path: [.key(group.rawValue)],
                    group: group.rawValue,
                    message: "Group '\(group.rawValue)' from skin '\(current.id)' could not be resolved; falling back."
                ))
            } else if status == .invalid {
                diagnostics.append(SkinDiagnostic(
                    code: "group-invalid",
                    severity: .groupError,
                    path: [.key(group.rawValue)],
                    group: group.rawValue,
                    message: "Group '\(group.rawValue)' from skin '\(current.id)' is invalid; falling back."
                ))
            }

            guard let next = nextBase(after: current, seen: seen, diagnostics: &diagnostics) else {
                break
            }
            current = next
        }

        if current.id != Self.terminalSkin.id,
           let value = try? build(Self.terminalManifest, Self.defaultSkinID, appearance)
        {
            return (value, Self.defaultSkinID)
        }
        return nil
    }

    private func nextBase(
        after skin: InstalledSkin,
        seen: Set<String>,
        diagnostics: inout [SkinDiagnostic]
    ) -> InstalledSkin? {
        guard skin.id != Self.defaultSkinID else {
            return nil
        }

        let explicitBase = skin.manifest.base
        var baseID = explicitBase ?? Self.defaultSkinID
        if baseID == skin.id {
            diagnostics.append(cycleDiagnostic(group: nil, skinID: skin.id))
            return nil
        }

        if let explicitBase, !availableBaseIDs.contains(explicitBase) {
            diagnostics.append(SkinDiagnostic(
                code: "base-unavailable",
                severity: .warning,
                path: [.key("base")],
                message: "Base skin '\(explicitBase)' is not available; falling back to \(Self.defaultSkinID)."
            ))
            baseID = Self.defaultSkinID
        }

        if seen.contains(baseID) {
            diagnostics.append(cycleDiagnostic(group: nil, skinID: baseID))
            return nil
        }

        if let installed = builtIns.first(where: { $0.id == baseID && !isFatal($0) }) {
            return installed
        }

        if baseID != Self.defaultSkinID {
            diagnostics.append(SkinDiagnostic(
                code: "base-not-installed",
                severity: .warning,
                path: [.key("base")],
                message: "Base skin '\(baseID)' is not installed; falling back to \(Self.defaultSkinID)."
            ))
        }

        guard !seen.contains(Self.defaultSkinID) else {
            diagnostics.append(cycleDiagnostic(group: nil, skinID: Self.defaultSkinID))
            return nil
        }

        if let installedClear = builtIns.first(where: {
            $0.id == Self.defaultSkinID && !isFatal($0)
        }) {
            return installedClear
        }
        return Self.terminalSkin
    }

    private func cycleDiagnostic(
        group: SkinGroup?,
        skinID: String
    ) -> SkinDiagnostic {
        SkinDiagnostic(
            code: "base-cycle",
            severity: .warning,
            path: [.key("base")],
            group: group?.rawValue,
            message: "The base chain repeats skin '\(skinID)'; fallback stopped."
        )
    }

    private func inventory(for skinID: String) -> Set<String>? {
        builtIns.first(where: { $0.id == skinID })?.availableImagePaths
    }

    // MARK: - Contrast unit

    private func applyContrastUnit(
        surface: inout ResolvedSurface,
        palette: inout [RGBAColor],
        typography: ResolvedTypography,
        appearance: SkinAppearance,
        selected: InstalledSkin?,
        textScale: Double,
        provenance: inout [SkinGroup: String],
        diagnostics: inout [SkinDiagnostic]
    ) {
        let scale = textScale.isFinite ? min(max(textScale, 0.5), 3) : 1
        // Contrast depends on the size the user will actually read, so apply the
        // current text scale before choosing the large-text floor.
        let requiredRatio = Contrast.requiredRatio(
            pointSize: min(max(typography.effectiveSize * scale, 1), 512),
            weight: typography.weight
        )

        switch Contrast.minimumFillAlpha(
            surface: surface.fill,
            palette: palette,
            text: surface.text,
            minimumAlpha: surface.fill.a,
            requiredRatio: requiredRatio
        ) {
        case .feasible(let alpha):
            apply(fillAlpha: alpha, to: &surface, diagnostics: &diagnostics)
        case .impossible:
            diagnostics.append(SkinDiagnostic(
                code: "contrast-impossible",
                severity: .groupError,
                path: [.key("surface"), .key("fill")],
                group: SkinGroup.surface.rawValue,
                message: "No surface opacity keeps every text and palette pair above the contrast floor; the surface and palette fall back together."
            ))
            if let pair = fallbackSurfacePalette(
                after: selected,
                appearance: appearance,
                requiredRatio: requiredRatio,
                diagnostics: &diagnostics
            ) {
                surface = pair.surface
                palette = pair.palette
                provenance[.surface] = pair.sourceID
                provenance[.palette] = pair.sourceID
            } else {
                surface = Self.terminalSurface
                palette = []
                provenance[.surface] = Self.defaultSkinID
                provenance[.palette] = Self.defaultSkinID
            }
        }
    }

    private func fallbackSurfacePalette(
        after selected: InstalledSkin?,
        appearance: SkinAppearance,
        requiredRatio: Double,
        diagnostics: inout [SkinDiagnostic]
    ) -> (surface: ResolvedSurface, palette: [RGBAColor], sourceID: String)? {
        guard let selected else {
            return nil
        }

        var seen: Set<String> = [selected.id]
        var candidate = nextBase(after: selected, seen: seen, diagnostics: &diagnostics)

        while let skin = candidate {
            guard seen.insert(skin.id).inserted else {
                break
            }

            let surface = resolveGroup(.surface, from: skin, appearance: appearance, diagnostics: &diagnostics) {
                manifest, sourceID, appearance in
                buildSurface(
                manifest,
                sourceID: sourceID,
                appearance: appearance,
                inventory: inventory(for: sourceID)
            )
            }
            let palette = resolveGroup(.palette, from: skin, appearance: appearance, diagnostics: &diagnostics) {
                manifest, sourceID, appearance in
                buildPalette(manifest, sourceID: sourceID, appearance: appearance)
            }

            if let resolvedSurface = surface?.value, let resolvedPalette = palette?.value {
                switch Contrast.minimumFillAlpha(
                    surface: resolvedSurface.fill,
                    palette: resolvedPalette,
                    text: resolvedSurface.text,
                    minimumAlpha: resolvedSurface.fill.a,
                    requiredRatio: requiredRatio
                ) {
                case .feasible(let alpha):
                    var repaired = resolvedSurface
                    repaired = replacingFill(repaired, with: resolvedSurface.fill.replacingAlpha(alpha))
                    return (repaired, resolvedPalette, skin.id)
                case .impossible:
                    break
                }
            }

            if skin.id == Self.defaultSkinID {
                break
            }
            candidate = nextBase(after: skin, seen: seen, diagnostics: &diagnostics)
        }

        return nil
    }

    private func apply(
        fillAlpha: Double,
        to surface: inout ResolvedSurface,
        diagnostics: inout [SkinDiagnostic]
    ) {
        guard fillAlpha > surface.fill.a + 1e-9 else {
            return
        }
        surface = replacingFill(surface, with: surface.fill.replacingAlpha(fillAlpha))
        diagnostics.append(SkinDiagnostic(
            code: "contrast-opacity-raised",
            severity: .warning,
            path: [.key("surface"), .key("fill")],
            group: SkinGroup.surface.rawValue,
            message: "The surface fill opacity was raised to \(fillAlpha) to meet the contrast floor."
        ))
    }

    private func replacingFill(_ surface: ResolvedSurface, with fill: RGBAColor) -> ResolvedSurface {
        ResolvedSurface(
            fill: fill,
            contrastBacking: ResolvedContrastBacking(
                overBlack: fill.composited(over: .black),
                overWhite: fill.composited(over: .white)
            ),
            material: surface.material,
            image: surface.image,
            cornerRadius: surface.cornerRadius,
            border: surface.border,
            shadow: surface.shadow,
            padding: surface.padding,
            text: surface.text,
            placeholder: surface.placeholder,
            selection: surface.selection,
            caret: surface.caret
        )
    }

    private func deduplicated(_ diagnostics: [SkinDiagnostic]) -> [SkinDiagnostic] {
        var seen: Set<SkinDiagnostic> = []
        return diagnostics.filter { seen.insert($0).inserted }
    }

    // MARK: - Group builders

    private func buildPalette(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> [RGBAColor]? {
        guard let palette = manifest.palette else {
            return nil
        }
        var colors: [RGBAColor] = []
        colors.reserveCapacity(palette.count)
        for token in palette {
            guard let color = parseColor(token, appearance: appearance) else {
                return nil
            }
            colors.append(color)
        }
        return colors
    }

    private func buildSurface(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance,
        inventory: Set<String>?
    ) -> ResolvedSurface? {
        guard let source = manifest.surface else {
            return nil
        }

        guard let fill = parseColor(source.fill, appearance: appearance, fallback: .clear),
              let text = parseColor(source.text?.color, appearance: appearance, fallback: .black),
              let placeholder = parseColor(source.placeholderColor, appearance: appearance, fallback: text),
              let selection = parseColor(source.selection, appearance: appearance, fallback: .clear),
              let caret = parseColor(source.caret, appearance: appearance, fallback: text),
              let borderColor = parseColor(source.border?.color, appearance: appearance, fallback: text)
        else {
            return nil
        }

        var image: ResolvedSurfaceImage?
        if let sourceImage = source.image {
            let element: SkinImageElement
            if let rawElement = sourceImage.element {
                guard let parsed = SkinImageElement(rawValue: rawElement) else {
                    return nil
                }
                element = parsed
            } else {
                element = .noteBody
            }
            guard let resolved = resolveImage(
                skinID: sourceID,
                element: element,
                appearance: appearance,
                inventory: inventory
            ) else {
                return nil
            }
            image = ResolvedSurfaceImage(
                key: resolved.key,
                availableScales: Set(resolved.scales),
                insets: sourceImage.insets ?? SkinInsets(),
                mode: sourceImage.mode ?? .known(.stretch),
                tintWithPalette: sourceImage.tintWithPalette ?? false
            )
        }

        let material = appearanceValue(source.material, appearance: appearance) ?? .known(.none)
        let border = ResolvedBorder(
            width: min(max(source.border?.width ?? 0, 0), 4),
            color: borderColor
        )

        return ResolvedSurface(
            fill: fill,
            contrastBacking: ResolvedContrastBacking(
                overBlack: fill.composited(over: .black),
                overWhite: fill.composited(over: .white)
            ),
            material: material,
            image: image,
            cornerRadius: min(max(source.cornerRadius ?? 0, 0), 32),
            border: border,
            shadow: source.shadow ?? .known(.none),
            padding: source.padding ?? SkinInsets(),
            text: text,
            placeholder: placeholder,
            selection: selection,
            caret: caret
        )
    }

    /// Chooses an image variant that exists: requested appearance, then the base
    /// appearance; twice the sharpness first, then 1x.
    private func resolveImage(
        skinID: String,
        element: SkinImageElement,
        appearance: SkinAppearance,
        inventory: Set<String>?
    ) -> (key: ResolvedImageKey, scales: [SkinScale])? {
        // A base image (no `~dark` suffix) is the light appearance, so a dark skin
        // falls back to it before giving up.
        let appearances: [SkinAppearance] = appearance == .dark ? [.dark, .light] : [.light]
        let scales: [SkinScale] = [.two, .one]

        for candidateAppearance in appearances {
            for scale in scales {
                let key = ResolvedImageKey(
                    skinID: skinID,
                    element: element,
                    appearance: candidateAppearance,
                    scale: scale
                )
                guard let inventory else {
                    return (key, [.one, .two])
                }
                guard inventory.contains(key.relativeName) else {
                    continue
                }
                let one = ResolvedImageKey(
                    skinID: skinID,
                    element: element,
                    appearance: candidateAppearance,
                    scale: .one
                )
                let available = [one.relativeName, key.relativeName]
                    .filter { inventory.contains($0) }
                let availableScales = available.compactMap { path -> SkinScale? in
                    path.contains("@2x") ? .two : .one
                }
                return (key, availableScales.isEmpty ? [scale] : availableScales)
            }
        }
        return nil
    }

    private func buildTypography(
        _ manifest: SkinManifest,
        appearance: SkinAppearance
    ) -> ResolvedTypography? {
        guard let typography = manifest.typography else {
            return nil
        }
        return ResolvedTypography(
            family: typography.font?.family,
            effectiveSize: min(max(typography.size ?? 14, 10), 32),
            weight: typography.weight ?? .known(.regular),
            lineSpacing: min(max(typography.lineSpacing ?? 0, 0), 64)
        )
    }

    private func buildHeader(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedHeader? {
        guard let header = manifest.header else {
            return nil
        }
        guard let fill = parseColor(header.fill, appearance: appearance, fallback: .clear) else {
            return nil
        }
        let height = header.height ?? 0
        let image = height > 0
            ? ResolvedImage(
                key: ResolvedImageKey(
                    skinID: sourceID,
                    element: .noteHeader,
                    appearance: appearance,
                    scale: .two
                ),
                availableScales: [.one, .two]
            )
            : nil
        return ResolvedHeader(
            height: height,
            fill: fill,
            showsTitle: header.showsTitle ?? false,
            image: image
        )
    }

    private func buildCollapsed(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedCollapsed? {
        guard let collapsed = manifest.collapsed else {
            return nil
        }
        let height = collapsed.height ?? 0
        let image = height > 0
            ? ResolvedImage(
                key: ResolvedImageKey(
                    skinID: sourceID,
                    element: .noteCollapsed,
                    appearance: appearance,
                    scale: .two
                ),
                availableScales: [.one, .two]
            )
            : nil
        return ResolvedCollapsed(
            height: height,
            fill: .clear,
            showsFirstLine: collapsed.showsFirstLine ?? false,
            image: image
        )
    }

    private func buildDecoration(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedDecoration? {
        guard let decoration = manifest.decoration else {
            return nil
        }

        var image: ResolvedImage?
        if let rawElement = decoration.element {
            guard let element = SkinImageElement(rawValue: rawElement) else {
                return nil
            }
            if decoration.hidden != true {
                image = ResolvedImage(
                    key: ResolvedImageKey(
                        skinID: sourceID,
                        element: element,
                        appearance: appearance,
                        scale: .two
                    ),
                    availableScales: [.one, .two]
                )
            }
        } else if decoration.hidden != true {
            return nil
        }

        return ResolvedDecoration(
            image: image,
            anchor: decoration.anchor ?? .known(.topCenter),
            origin: decoration.origin ?? .known(.center),
            offset: ResolvedOffset(
                x: decoration.offset?.x ?? 0,
                y: decoration.offset?.y ?? 0
            ),
            rotation: decoration.rotation ?? 0,
            hidden: decoration.hidden ?? false
        )
    }

    private func buildIcons(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedIcons? {
        guard let icons = manifest.icons else {
            return nil
        }
        guard let tint = parseColor(icons.tint, appearance: appearance, fallback: .black) else {
            return nil
        }

        func image(_ element: SkinImageElement) -> ResolvedImage {
            ResolvedImage(
                key: ResolvedImageKey(
                    skinID: sourceID,
                    element: element,
                    appearance: appearance,
                    scale: .two
                ),
                availableScales: [.one, .two]
            )
        }

        return ResolvedIcons(
            collapse: image(.iconCollapse),
            expand: image(.iconExpand),
            close: image(.iconClose),
            more: image(.iconMore),
            template: icons.template ?? false,
            tint: tint
        )
    }

    private func buildResizeHandle(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedResizeHandle? {
        guard let handle = manifest.resizeHandle else {
            return nil
        }
        guard let tint = parseColor(handle.tint, appearance: appearance, fallback: .black) else {
            return nil
        }
        let visibility = handle.visibility ?? .known(.hover)
        let image: ResolvedImage?
        if visibility == .known(.never) {
            image = nil
        } else {
            image = ResolvedImage(
                key: ResolvedImageKey(
                    skinID: sourceID,
                    element: .resizeHandle,
                    appearance: appearance,
                    scale: .two
                ),
                availableScales: [.one, .two]
            )
        }
        return ResolvedResizeHandle(visibility: visibility, tint: tint, image: image)
    }

    private func buildLibrary(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedLibrary? {
        guard let library = manifest.library else {
            return nil
        }
        guard let accent = parseColor(library.accent, appearance: appearance, fallback: .black),
              let background = parseColor(library.background, appearance: appearance, fallback: .white)
        else {
            return nil
        }
        return ResolvedLibrary(
            accent: accent,
            sidebarMaterial: library.sidebarMaterial ?? .known(.none),
            cardStyle: library.cardStyle ?? .known(.note),
            background: background
        )
    }

    private func buildOrb(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> [SkinOrbState.Known: ResolvedOrbAnimation]? {
        guard let voiceOrb = manifest.voiceOrb else {
            return nil
        }
        guard let states = voiceOrb.states else {
            return [:]
        }

        var result: [SkinOrbState.Known: ResolvedOrbAnimation] = [:]
        for (state, animation) in states.animations.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard case .known(let knownState) = state else {
                return nil
            }
            guard let tint = parseColor(animation.tint, appearance: appearance, fallback: .clear) else {
                return nil
            }

            let frameCount = min(max(animation.frames ?? 0, 0), 60)
            let frames = (0..<frameCount).map { frame in
                ResolvedOrbFrameKey(
                    skinID: sourceID,
                    state: knownState,
                    frame: frame,
                    appearance: appearance,
                    scale: .two
                )
            }
            result[knownState] = ResolvedOrbAnimation(
                state: knownState,
                frameKeys: frames,
                fps: animation.fps ?? 0,
                loop: animation.loop ?? false,
                audioReactive: min(max(animation.audioReactive ?? 0, 0), 0.3),
                tint: tint
            )
        }
        return result
    }

    private func buildSounds(
        _ manifest: SkinManifest,
        sourceID: String,
        appearance: SkinAppearance
    ) -> ResolvedSounds? {
        guard let sounds = manifest.sounds else {
            return nil
        }
        var byEvent: [SkinSoundEvent: ResolvedSoundKey] = [:]
        for event in SkinSoundEvent.Known.allCases {
            byEvent[.known(event)] = ResolvedSoundKey(skinID: sourceID, event: .known(event))
        }
        return ResolvedSounds(
            byEvent: byEvent,
            volume: min(max(sounds.volume ?? 1, 0), 1),
            muted: Set(sounds.mute ?? [])
        )
    }

    // MARK: - High contrast

    private func resolveHighContrast(
        from start: InstalledSkin?,
        appearance: SkinAppearance
    ) -> ResolvedHighContrast {
        guard var current = start else {
            return ResolvedHighContrast()
        }

        var seen: Set<String> = []
        var ignored: [SkinDiagnostic] = []
        while true {
            guard seen.insert(current.id).inserted else {
                break
            }

            if let highContrast = current.manifest.highContrast {
                let fill = parseColor(highContrast.surfaceFill, appearance: appearance)
                let text = parseColor(highContrast.surfaceTextColor, appearance: appearance)
                if fill != nil || text != nil {
                    return ResolvedHighContrast(surfaceFill: fill, surfaceTextColor: text)
                }
            }

            guard let next = nextBase(after: current, seen: seen, diagnostics: &ignored) else {
                break
            }
            current = next
        }
        return ResolvedHighContrast()
    }

    // MARK: - Token helpers

    private func appearanceValue<T>(
        _ value: AppearanceValue<T>?,
        appearance: SkinAppearance
    ) -> T? {
        guard let value else {
            return nil
        }
        return appearance == .light ? value.light : value.dark
    }

    private func parseColor(
        _ token: SkinColor?,
        appearance: SkinAppearance
    ) -> RGBAColor? {
        guard let token else {
            return nil
        }
        let hex = appearance == .light ? token.light : token.dark
        return try? RGBAColor(hex: hex)
    }

    private func parseColor(
        _ token: SkinColor?,
        appearance: SkinAppearance,
        fallback: RGBAColor
    ) -> RGBAColor? {
        guard token != nil else {
            return fallback
        }
        return parseColor(token, appearance: appearance)
    }

    // MARK: - Terminal values

    private static let terminalManifest = SkinManifest(
        formatVersion: 1,
        id: defaultSkinID,
        name: "Clear",
        author: "Webby",
        version: "1.0.0",
        palette: [],
        surface: SkinSurface(
            fill: SkinColor("#FFFFFF"),
            material: .bare(.known(.none)),
            cornerRadius: 0,
            shadow: .known(.none),
            text: SkinSurfaceText(color: SkinColor("#000000")),
            placeholderColor: SkinColor("#000000"),
            selection: SkinColor("#00000000"),
            caret: SkinColor("#000000")
        ),
        typography: SkinTypography(size: 14, weight: .known(.regular), lineSpacing: 0),
        header: SkinHeader(height: 0, fill: SkinColor("#00000000"), showsTitle: false),
        collapsed: SkinCollapsed(height: 32, showsFirstLine: false),
        decoration: SkinDecoration(hidden: true),
        icons: SkinIcons(tint: SkinColor("#000000"), template: true),
        resizeHandle: SkinResizeHandle(visibility: .known(.hover), tint: SkinColor("#000000")),
        library: SkinLibrary(
            accent: SkinColor("#000000"),
            sidebarMaterial: .known(.none),
            cardStyle: .known(.note),
            background: SkinColor("#FFFFFF")
        ),
        voiceOrb: SkinVoiceOrb(states: SkinOrbStates()),
        sounds: SkinSounds(volume: 1, mute: [])
    )

    private static let terminalSkin = InstalledSkin(
        id: defaultSkinID,
        manifest: terminalManifest
    )

    private static let terminalSurface = ResolvedSurface(
        fill: .white,
        contrastBacking: .white,
        text: .black,
        placeholder: .black
    )

    private static let terminalTypography = ResolvedTypography(effectiveSize: 14)

    private static let terminalHeader = ResolvedHeader(height: 0, fill: .clear, showsTitle: false)

    private static let terminalCollapsed = ResolvedCollapsed(
        height: 32,
        fill: .clear,
        showsFirstLine: false
    )

    private static let terminalDecoration = ResolvedDecoration(hidden: true)

    private static let terminalIcons = ResolvedIcons(tint: .black)

    private static let terminalResizeHandle = ResolvedResizeHandle(tint: .black)

    private static let terminalLibrary = ResolvedLibrary(accent: .black, background: .white)
}
