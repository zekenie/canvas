import CoreGraphics

/// A drag that resizes a shape's box (Selection's resize handles), as it begins: what the plugin that
/// adjusts it is given (`registrar.resizeAdjuster`).
public struct ResizeStart: Sendable {
    /// The shape it resizes.
    public let id: ShapeID
    /// Its frame as the drag began, in world units: what each drag event resizes (the one it's laid out
    /// in, its box for most kinds).
    public let box: CGRect
    /// The smallest it goes either way, in world units (its kind's).
    public let minimum: CGSize
    /// Where it may reach, in world units (a shape in a container stays inside the container's edge);
    /// nil where it may reach anywhere.
    public let room: CGRect?

    public init(id: ShapeID, box: CGRect, minimum: CGSize, room: CGRect?) {
        self.id = id
        self.box = box
        self.minimum = minimum
        self.room = room
    }
}

/// How a drag that resizes a box changes it on one event (`ResizeAdjuster`): the point of the box as
/// the drag began that stays put, which ways it changes, and whether they change together.
public struct ResizeScaling: Equatable, Sendable {
    /// What stays put, in world units: along a way it changes, the side opposite the one dragged, or
    /// its middle (resized from its center, or across a side kept in proportion).
    public var anchor: CGPoint
    /// Whether its width changes.
    public var changesWidth: Bool
    /// Whether its height changes.
    public var changesHeight: Bool
    /// Whether its width and height change together, keeping its proportions (both change then).
    public var keepsProportions: Bool

    public init(anchor: CGPoint, changesWidth: Bool, changesHeight: Bool, keepsProportions: Bool) {
        self.anchor = anchor
        self.changesWidth = changesWidth
        self.changesHeight = changesHeight
        self.keepsProportions = keepsProportions
    }
}

/// What box a drag that resizes a shape gives it, if not the one the pointer gives it: made as the
/// drag begins by the plugin that claims it (`registrar.resizeAdjuster`; Snapping's, which snaps the
/// sides that move to other shapes), and kept for as long as the drag lasts. The core runs no resize:
/// the plugin that does (Selection, for its resize handles) asks for one (`editor.resizeAdjuster(for:)`),
/// so the two never know each other, as the translation adjuster keeps Snapping from knowing who drags.
@MainActor
public protocol ResizeAdjuster: AnyObject {
    /// The box to give the shape on this drag event, in world units, given the one the pointer gives it
    /// (`resized`: the box as the drag began, resized as `scaling` says, no smaller than the minimum and
    /// within the room): `resized` itself to leave it following the pointer. What it gives back keeps to
    /// `scaling` (the anchor where it is, only the ways that change changed, in proportion when
    /// they're kept), to the minimum and to the room. Asked again, with the same pointer, when held
    /// keys change.
    func adjust(_ resized: CGRect, scaling: ResizeScaling, for pointer: Pointer, in editor: CanvasEditor) -> CGRect
    /// Draws what it shows while the drag runs (guides), in world units, above the world overlays.
    func draw(in context: OverlayContext)
}

extension CanvasEditor {
    /// What adjusts the box a drag that resizes a shape gives it (`registrar.resizeAdjuster`), for a
    /// drag beginning now: ask once as the drag begins, and keep it for the drag. Nil when no plugin
    /// claims it, or the one that does declines.
    public func resizeAdjuster(for start: ResizeStart) -> (any ResizeAdjuster)? {
        registry.resizeAdjuster?(self, start)
    }
}
