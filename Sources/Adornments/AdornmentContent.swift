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
