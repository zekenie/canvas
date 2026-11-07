import AppKit

// A label drawn in a shape's content, not above it: a chip in a row of fields (Types), looking as the
// same label does in the row above the shape, so the two cannot drift apart.

extension AdornmentLabel {
    /// The label's size drawn as a chip in a shape's content (`draw(at:in:)`): the row's height and its
    /// face's width, in the units it is drawn in.
    @MainActor public var contentSize: CGSize {
        CGSize(width: ContentFaces.face(of: self).width, height: AdornmentLayout.rowHeight)
    }

    /// Draws the label as its chip, its top-left at `origin`, in `cg`'s units: in a shape's render that
    /// is world units, so it scales with the zoom as the shape's text does. Its face is kept by label.
    /// Drawn as in the light appearance, whatever the canvas's: a shape's body is the same in both, and
    /// a light tint's ink, a missing chip's dashes and its text follow the appearance drawn.
    @MainActor public func draw(at origin: CGPoint, in cg: CGContext) {
        let face = ContentFaces.face(of: self)
        let frame = CGRect(x: 0, y: 0, width: face.width, height: AdornmentLayout.rowHeight)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
            AdornmentStyle.draw(self, in: .aboveTopLeft, face: face, in: frame, from: origin, scale: 1, look: .normal, in: cg)
        }
    }
}

// A label typed in: a field laid over a title's pill (Titles' title field) draws the pill's chip, its capsule and its
// symbol, as wide as what is typed needs, and sets its text where the pill's text goes, in its font and ink, so
// nothing moves as typing starts and ends.

extension AdornmentLabel {
    /// The font a label's text is set in, in the row above a shape, view points.
    @MainActor public static var rowFont: NSFont { AdornmentStyle.rowText[.font] as? NSFont ?? .systemFont(ofSize: 11, weight: .medium) }

    /// Where the label's text starts in its chip, from the chip's left edge, view points: the padding, and its symbol's
    /// place and the gap after it where it has one.
    @MainActor public var textStart: CGFloat { AdornmentStyle.rowPadding + AdornmentStyle.lead(of: self, in: .aboveTopLeft) }

    /// Between the text's end and the chip's right edge, view points.
    @MainActor public static var textEnd: CGFloat { AdornmentStyle.rowPadding }

    /// The ink the label's text is drawn in, as its chip sets it (a tint's ink, or the pill's white).
    @MainActor public var textInk: NSColor { attributes[.foregroundColor] as? NSColor ?? .white }

    /// The attributes its text is set in, in the row.
    @MainActor private var attributes: [NSAttributedString.Key: Any] {
        guard case .text(let string, _, _, _, _) = AdornmentStyle.face(of: self, in: .aboveTopLeft), string.length > 0 else { return AdornmentStyle.rowText }
        return string.attributes(at: 0, effectiveRange: nil)
    }

    /// Draws the label whole, its top-left at `origin`, in `cg`'s units at `scale` of them a point, in the appearance being
    /// drawn, as the row above a shape draws it: what a field typed over a pill shows while nothing is typed (its
    /// placeholder, dimmed).
    @MainActor public func draw(at origin: CGPoint, scale: CGFloat, in cg: CGContext) {
        let face = AdornmentStyle.face(of: self, in: .aboveTopLeft)
        let frame = CGRect(x: 0, y: 0, width: face.width, height: AdornmentLayout.rowHeight)
        AdornmentStyle.draw(self, in: .aboveTopLeft, face: face, in: frame, from: origin, scale: scale, look: .normal, in: cg)
    }

    /// Draws the label's chip `width` wide with no text, its top-left at `origin`, in `cg`'s units at `scale` of them a
    /// point: its capsule and its symbol, where a field sets the text over it. Drawn in the appearance being drawn, as
    /// the row above a shape is.
    @MainActor public func drawChip(width: CGFloat, at origin: CGPoint, scale: CGFloat, in cg: CGContext) {
        let blank = AdornmentLabel(" ", systemImage: systemImage)
        let label = tint.map { blank.tinted($0) } ?? blank
        guard case .text(_, let size, let symbol, _, _) = AdornmentStyle.face(of: label, in: .aboveTopLeft) else { return }
        let face = AdornmentStyle.Face.text(NSAttributedString(), size: size, symbol: symbol, count: nil, width: width)
        let frame = CGRect(x: 0, y: 0, width: width, height: AdornmentLayout.rowHeight)
        AdornmentStyle.draw(label, in: .aboveTopLeft, face: face, in: frame, from: origin, scale: scale, look: .normal, in: cg)
    }
}

/// The faces of the labels drawn in content, kept by label: a row of fields draws the same few every frame.
@MainActor
private enum ContentFaces {
    /// How many faces are kept; past it the lot is let go.
    static let capacity = 512
    private static var kept: [AdornmentLabel: AdornmentStyle.Face] = [:]

    static func face(of label: AdornmentLabel) -> AdornmentStyle.Face {
        if let known = kept[label] { return known }
        if kept.count >= capacity { kept.removeAll(keepingCapacity: true) }
        let face = AdornmentStyle.face(of: label, in: .aboveTopLeft)
        #if DEBUG
        AdornmentContentCounts.facesMade += 1
        #endif
        kept[label] = face
        return face
    }
}

#if DEBUG
/// How many faces for content have been made (debug builds), so tests can hold a frame to what changed.
@MainActor
public enum AdornmentContentCounts {
    public static var facesMade = 0
}
#endif
