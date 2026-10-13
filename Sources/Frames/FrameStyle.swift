import AppKit

/// The frame's look: a quiet region on the canvas, a surface with a thin neutral border and no
/// shadow, a step up from the canvas as a panel is. World units, but for the border's width and how
/// far the border is pressed, which are view points. Its colors follow the appearance it's drawn in,
/// resolved as it's drawn (each `NSColor` is dynamic, its `cgColor` read in the render), as a
/// subboard's do.
@MainActor
enum FrameStyle {
    static let cornerRadius: CGFloat = 12
    /// The border, in view points: a hairline at every zoom, as the canvas's outlines are.
    static let borderWidth: CGFloat = 1
    /// How far either side of its edge a frame that holds shapes is pressed, in view points: inside
    /// that, it's the canvas.
    static let borderReach: CGFloat = 6

    /// The surface: white on the light canvas, a raised gray on the dark one. Opaque, so the dots
    /// stop at its edge, and what it holds sits on it.
    static let fill = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 1, alpha: 1)
    }
    /// The border: neutral, and as light as a hairline can be and still be seen on both canvases.
    static let border = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)
    }
    /// The kind's color where a frame is shown by its kind: its row's symbol, and its mentions' tint
    /// in the picker. Neutral, as the frame is.
    static let tint = NSColor.systemGray

    /// While a frame is drawn with the Frame tool, its surface shows at this much, so what it's drawn
    /// over shows through until it's put down and takes in what's mostly inside it.
    static let previewFillOpacity: CGFloat = 0.3

    static func path(_ rect: CGRect, radius: CGFloat = cornerRadius) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A frame at `rect` (world units), at `zoom`: its surface, and its border just inside its edge,
    /// so nothing is drawn outside it; with `fillOpacity` under 1, a frame being drawn.
    static func draw(_ rect: CGRect, zoom: CGFloat, fillOpacity: CGFloat = 1, in cg: CGContext) {
        cg.saveGState()
        cg.addPath(path(rect))
        let surface = fill.cgColor
        cg.setFillColor(fillOpacity < 1 ? surface.copy(alpha: surface.alpha * fillOpacity) ?? surface : surface)
        cg.fillPath()
        let width = borderWidth / zoom
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        if inset.width > 0, inset.height > 0 {
            cg.addPath(path(inset, radius: cornerRadius - width / 2))
            cg.setStrokeColor(border.cgColor)
            cg.setLineWidth(width)
            cg.strokePath()
        }
        cg.restoreGState()
    }
}

extension NSAppearance {
    fileprivate var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
