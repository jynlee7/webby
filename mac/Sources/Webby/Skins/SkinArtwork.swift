import AppKit
import SwiftUI
import WebbyCore

/// The nine-slice `note-body` artwork, stretched or tiled over the note.
struct SurfaceArtwork: View {
    let image: ResolvedSurfaceImage
    /// The note's palette color, applied when the skin asks for `tintWithPalette`.
    let tint: RGBAColor?

    @Environment(\.skinAssetCache) private var cache

    var body: some View {
        if let nsImage = cache?.image(for: image.key, availableScales: image.availableScales) {
            let insets = image.insets
            let capInsets = EdgeInsets(
                top: insets.top ?? 0, leading: insets.left ?? 0,
                bottom: insets.bottom ?? 0, trailing: insets.right ?? 0
            )
            let mode: Image.ResizingMode = image.mode == .known(.tile) ? .tile : .stretch
            Image(nsImage: nsImage)
                .resizable(capInsets: capInsets, resizingMode: mode)
                .modifier(PaletteTint(color: image.tintWithPalette ? tint : nil))
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }
}

private struct PaletteTint: ViewModifier {
    let color: RGBAColor?

    func body(content: Content) -> some View {
        if let color {
            content.colorMultiply(Color(color))
        } else {
            content
        }
    }
}

/// The decoration, placed by its anchor on the note's visual frame, its own origin point
/// and an offset (positive x right, positive y down), inside the fixed transparent margin.
/// It never takes clicks and is hidden from the accessibility tree.
struct DecorationView: View {
    let decoration: ResolvedDecoration

    @Environment(\.skinAssetCache) private var cache

    var body: some View {
        if !decoration.hidden, let resolved = decoration.image,
           let nsImage = cache?.image(for: resolved) {
            GeometryReader { proxy in
                let margin = Geometry.decorationMargin
                let visual = CGRect(x: margin, y: margin,
                                    width: max(proxy.size.width - 2 * margin, 0),
                                    height: max(proxy.size.height - 2 * margin, 0))
                let size = nsImage.size
                let anchor = Self.point(of: decoration.anchor, in: visual)
                let originShift = Self.fractions(of: decoration.origin)
                let center = CGPoint(
                    x: anchor.x + decoration.offset.x + (0.5 - originShift.x) * size.width,
                    y: anchor.y + decoration.offset.y + (0.5 - originShift.y) * size.height
                )
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(decoration.rotation))
                    .position(center)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func fractions(of alignment: SkinAlignment) -> CGPoint {
        guard case .known(let known) = alignment else { return CGPoint(x: 0.5, y: 0.5) }
        switch known {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topCenter: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .centerLeft: return CGPoint(x: 0, y: 0.5)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .centerRight: return CGPoint(x: 1, y: 0.5)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomCenter: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }

    private static func point(of alignment: SkinAlignment, in rect: CGRect) -> CGPoint {
        let f = fractions(of: alignment)
        return CGPoint(x: rect.minX + f.x * rect.width, y: rect.minY + f.y * rect.height)
    }
}
