import Canvas
import CoreGraphics

/// Parts of a shape's content that answer a click without taking the shape's press: a mention's pill
/// in a note's text, a link, a checkbox drawn on a card. Unlike a canvas button, a face is the
/// shape's: a press on one selects the shape as any press does, and a drag from one moves the
/// selection; only a click (a press released within the drag threshold) and a double-click are the
/// face's, and the pointer over one hovers the shape the face names. The select tool asks for one
/// only on a plain press (no ⇧, ⌘ or ⌥, and not a Control-click), and only on the shape it would
/// press there, selected or not, where the point is on the shape itself rather than on something
/// drawn for it (`DecorationHits`); canvas buttons and handles still come first. A shape drawn as a
/// skeleton, zoomed out (`editor.drawsSkeleton(of:)`), shows none of its content, so it has no
/// faces: a click, a double-click and the pointer there are the shape's, and a double-click edits an
/// `Editable` one (which then draws in full). A list: each plugin's faces, the last plugin's first.
public enum ShapeFaces {}

extension ShapeFaces: ExtensionPoint {
    public typealias Contribution = ShapeFaceSource
    public static var owner: PluginID { .selection }
}

/// One plugin's faces: where they are on a shape, and what a click, a double-click and the pointer
/// over one do. Only the sugar makes one.
@MainActor
public struct ShapeFaceSource {
    let face: @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> AnyHashable?
    let click: @MainActor (AnyHashable, CanvasEditor) -> Void
    let doubleClick: (@MainActor (AnyHashable, CanvasEditor) -> Void)?
    let hovering: (@MainActor (AnyHashable, CanvasEditor) -> ShapeID?)?
}

extension PluginRegistrar {
    /// Faces this plugin finds in shapes' content (see `ShapeFaces`). `at` finds the one under a
    /// world point on a shape, the front-most if several, as any value the plugin knows it by: it's
    /// given the shape the select tool would press there, and looks at that shape alone. `click`
    /// runs when a plain press on one is released within the drag threshold, once the shape is
    /// selected alone. `doubleClick` runs when a double-click's press lands on one, in place of what
    /// a double-click does to the shape (editing an `Editable` one), once the shape is selected
    /// alone; without it, a double-click there edits an `Editable` shape and is otherwise one more
    /// press on the face. `hovering` names the shape the pointer over one hovers (`editor.hovered`),
    /// in its shape's place (a pill's target); nil, a shape that isn't there or can't be selected,
    /// or no `hovering`, hovers its shape. The select tool asks `at` as the pointer moves over a
    /// shape, whatever keys are held, so keep it cheap; never for a shape drawn as a skeleton.
    public mutating func shapeFaces<Face: Hashable & Sendable>(at find: @escaping @MainActor (CanvasEditor, AnyShapeRecord, CGPoint) -> Face?,
                                                               click: @escaping @MainActor (Face, CanvasEditor) -> Void,
                                                               doubleClick: (@MainActor (Face, CanvasEditor) -> Void)? = nil,
                                                               hovering: (@MainActor (Face, CanvasEditor) -> ShapeID?)? = nil) {
        var erasedDoubleClick: (@MainActor (AnyHashable, CanvasEditor) -> Void)?
        if let doubleClick {
            erasedDoubleClick = { face, editor in
                if let face = face.base as? Face { doubleClick(face, editor) }
            }
        }
        var erasedHovering: (@MainActor (AnyHashable, CanvasEditor) -> ShapeID?)?
        if let hovering {
            erasedHovering = { face, editor in
                guard let face = face.base as? Face else { return nil }
                return hovering(face, editor)
            }
        }
        contribute(ShapeFaceSource(face: { editor, shape, point in find(editor, shape, point).map(AnyHashable.init) },
                                   click: { face, editor in
                                       if let face = face.base as? Face { click(face, editor) }
                                   },
                                   doubleClick: erasedDoubleClick, hovering: erasedHovering),
                   to: ShapeFaces.self)
    }
}

/// A face under the pointer, and the plugin's faces it's one of.
@MainActor
struct FaceHit {
    let source: ShapeFaceSource
    let face: AnyHashable

    func click(in editor: CanvasEditor) { source.click(face, editor) }
}

extension CanvasEditor {
    /// The face under a world point on a shape (`ShapeFaces`), the last plugin's first. Only for a
    /// point on the shape itself, not on something drawn for it (`SelectableHit.isOnShape`), and
    /// only on a shape drawn in full: a skeleton shows no faces.
    func faceHit(on hit: SelectableHit, at point: CGPoint) -> FaceHit? {
        guard hit.isOnShape, let sources = selectionState?.faceSources, !sources.isEmpty, !drawsSkeleton(of: hit.id),
              let record = document[hit.id] else { return nil }
        for source in sources {
            if let face = source.face(self, record, point) { return FaceHit(source: source, face: face) }
        }
        return nil
    }

    /// The shape the pointer at a world point hovers in the select tool, the selectable shape there
    /// (`hit`), or the shape a face there names in its place.
    func shapeToHover(_ hit: SelectableHit?, at point: CGPoint) -> ShapeID? {
        guard let hit else { return nil }
        // A shape in a group past the one the selection is inside is hovered as the group: its faces
        // answer once a click has gone into the group.
        guard selectionUnit(of: hit.id) == [hit.id] else { return hit.id }
        guard let face = faceHit(on: hit, at: point), let named = face.source.hovering?(face.face, self), isSelectable(named) else { return hit.id }
        return named
    }
}
