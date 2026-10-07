import AppKit

public enum OverlaySpace: Sendable {
    /// Drawn with the camera transform, after the shapes and their outlines. Sizes meant as view
    /// points are divided by `zoom`.
    case world
    /// Drawn in view points, after everything in world units (and the session's drawing).
    case view
}

/// What a plugin wants outlined, from `registrar.outlines`: shapes by their `indicatorPath`, and
/// world rects. The core strokes every plugin's outlines and the hint in one pass, in the accent
/// color at a constant screen width, just above the shapes. `faintShapes` are stroked first, wider
/// and lighter (a hover beside a selection; stronger beside `tinted` groups, where it's the shape
/// they're about); a shape outlined in full too is stroked only in full. `tinted` groups are
/// stroked before those, in colors of their own. A closed shape's outline is
/// stroked standing off its edge, the same distance for every kind (`CanvasEditor.outlinePath(of:)`,
/// `outlineGap`: 4 view points), and so is a rect, which holds the shapes' own; an open shape's is
/// stroked on its own path. Zoomed out, where shapes are skeletons, an outline is a ring on its frame.
/// Outlines compare equal when all four lists do, so a plugin that keeps what it hands the core can
/// tell whether it changed, and ask for a frame only then.
public struct Outlines: Equatable {
    public var shapes: [ShapeID]
    /// World units.
    public var rects: [CGRect]
    public var faintShapes: [ShapeID]
    /// Shapes outlined in colors of their own, each group stroked under every other outline.
    public var tinted: [TintedOutlines]
    public init(shapes: [ShapeID] = [], rects: [CGRect] = [], faintShapes: [ShapeID] = [], tinted: [TintedOutlines] = []) {
        self.shapes = shapes
        self.rects = rects
        self.faintShapes = faintShapes
        self.tinted = tinted
    }
}

/// Shapes a plugin outlines in a color of its own (`Outlines.tinted`), stroked under every other
/// outline, the faint ones and the full ones, so a selected shape's accent line shows over its tint.
/// `ring` 0 is where the selection's outline stands; each ring after it stands a line and a gap
/// further out (4 view points), so a shape in two groups shows both, one ring inside the other. A
/// shape that's outlined in full too (selected, or the hint) has its tint one ring further out
/// than it says, clear of the selection's line, which would cover most of ring 0. An open shape (an
/// arrow) has no inside to stand off from: it's stroked on its own path whatever its ring, and a
/// kind drawn as a line (`StrokedShape`) has it covered, as wide as the line is on screen and a
/// point more, so the shape's own line isn't left to stripe it. The core knows no meaning of the
/// color or the group: what a plugin says it is, it strokes.
public struct TintedOutlines: Equatable {
    public var color: NSColor
    public var shapes: [ShapeID]
    public var ring: Int
    public init(color: NSColor, shapes: [ShapeID], ring: Int = 0) {
        self.color = color
        self.shapes = shapes
        self.ring = ring
    }
}

/// Something a plugin draws above every shape (status outlines, hints). Shapes never
/// know about it. Each overlay draws with a fresh graphics state. If what it draws changes other
/// than through the document or the editor's own state (on a timer, say), call
/// `editor.setNeedsDisplay()`.
@MainActor
public protocol CanvasOverlay {
    var space: OverlaySpace { get }
    func draw(in context: OverlayContext)
}

@MainActor
public struct OverlayContext {
    public let cg: CGContext
    public let editor: CanvasEditor
    public let shapes: ShapeContext
    /// What the view shows, in world units. An overlay that draws for some shapes goes through
    /// `editor.paintOrder(in:)` with this, grown by however far past its shapes it draws (and by
    /// `worldDrawingReach` if it follows drawing offsets), rather than through every shape.
    public let visibleRect: CGRect
    /// Whether this frame draws shapes as skeletons (`CanvasEditor.drawsSkeletons`): an overlay
    /// that shows what a shape holds (its title's text) draws it simply too, or not at all, and
    /// the shape being edited is drawn in full (`drawsSkeleton(of:)`).
    public let drawsSkeletons: Bool
    /// The frame's tinted outlines, if it has any: what `tintedOutset(of:)` reads.
    let tintedRings: TintedRings?
    public var zoom: CGFloat { shapes.zoom }

    /// Whether this frame draws the shape as a skeleton: `drawsSkeletons`, but for the shape being
    /// edited.
    public func drawsSkeleton(of id: ShapeID) -> Bool { drawsSkeletons && id != editor.editingShapeID }

    /// How far from where it is a shape is drawn (`editor.setDrawingOffset`), in world units: an
    /// overlay that decorates a shape moves its decoration by this, so it stays with the shape.
    public func worldDrawingOffset(of id: ShapeID) -> CGPoint {
        let offset = editor.drawingOffset(of: id)
        return offset == .zero ? .zero : CGPoint(x: offset.x / zoom, y: offset.y / zoom)
    }

    /// The farthest any shape is drawn from where it is now, along either axis, in world units:
    /// zero unless a drawing offset is set. An overlay that culls with `visibleRect` and moves its
    /// decorations by `worldDrawingOffset(of:)` grows the rect by this too, so a shape shaken into
    /// view from just outside it is decorated there. It looks at only the shapes drawn away from
    /// where they are.
    public var worldDrawingReach: CGFloat { editor.worldDrawingReach }

    /// How far, in view points, the outermost ring of tinted outlines (`Outlines.tinted`) the canvas
    /// draws round a closed shape this frame stands beyond ring 0, where the selection's line is:
    /// zero for a shape with none, with one, or open (an arrow's tint is on its line whatever its
    /// ring), else a ring's width and gap (4) for each ring past the first, counting the one further
    /// out of a shape that's outlined in full too. What an overlay that decorates a closed shape
    /// outside its outline adds to its distance, so it stands outside the tint and not over it
    /// (Validation's ring). Worked out when first asked, for every shape the groups name, and not
    /// for a frame that's asked nothing.
    public func tintedOutset(of id: ShapeID) -> CGFloat {
        guard let ring = tintedRings?.outermostRing(of: id), ring > 0, shapes.geometry(of: id)?.isClosed == true else { return 0 }
        return CGFloat(ring) * Style.tintedRingPitch
    }

    /// The farthest `tintedOutset(of:)` could be for any shape this frame, in view points, without
    /// a look at each: an overlay that culls shapes by how far its decoration reaches grows its rect
    /// by it.
    public var greatestTintedOutset: CGFloat {
        CGFloat(tintedRings?.greatestRing ?? 0) * Style.tintedRingPitch
    }
}
