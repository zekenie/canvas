import Canvas
import CoreGraphics

/// What part of a shape's content shows in a popover beside it while the pointer rests there (the
/// core's `CanvasPopover`): a type's words, the part of its schema they say. Unlike a face, it
/// answers no click: a press, a drag and a double-click there are the shape's, as anywhere on it. The
/// select tool asks as the pointer moves, with nothing under way, over the shape it would press
/// there, at a point on the shape itself (not on what's drawn for it outside, `DecorationHits`), when
/// no canvas button or handle is under the pointer; never for a shape drawn as a skeleton, which
/// shows none of its content, and the level changing under a still pointer asks again. A list: each
/// plugin's, the last plugin's first.
public enum ShapePopovers {}

extension ShapePopovers: ExtensionPoint {
    public typealias Contribution = ShapePopoverSource
    public static var owner: PluginID { .selection }
}

/// One plugin's popovers: what a point on a shape shows. Only the sugar makes one.
@MainActor
public struct ShapePopoverSource {
    let popover: @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> CanvasPopover?
}

extension PluginRegistrar {
    /// Popovers this plugin shows for parts of shapes' content (see `ShapePopovers`): `at` is given
    /// the shape the select tool would press at a world point, and returns what shows there, or nil.
    /// Asked as the pointer moves over a shape, so keep it cheap: the same popover's text, asked
    /// again, can be what was made the last time.
    public mutating func shapePopovers(at find: @escaping @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> CanvasPopover?) {
        contribute(ShapePopoverSource(popover: find), to: ShapePopovers.self)
    }
}

extension CanvasEditor {
    /// The popover a world point on a shape shows (`ShapePopovers`), the last plugin's first: only on
    /// the shape itself, drawn in full.
    func popoverHit(on hit: SelectableHit, at point: CGPoint) -> CanvasPopover? {
        guard hit.isOnShape, let sources = selectionState?.popoverSources, !sources.isEmpty, !drawsSkeleton(of: hit.id),
              let record = document[hit.id] else { return nil }
        for source in sources {
            if let popover = source.popover(self, record, point) { return popover }
        }
        return nil
    }
}
