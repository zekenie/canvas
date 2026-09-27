import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

/// A box whose geometry has no outline: only its box says where it is.
struct Stamp: BoxShapeProps {
    static let kind: ShapeKind = "stamp"
    var frame: CGRect
}

struct StampDefinition {}

extension StampDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Stamp>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Stamp>, in context: ShapeContext) -> ShapeGeometry { ShapeGeometry(outline: []) }
}

/// What a test outlines, as a plugin's outlines would.
@MainActor final class Outlined {
    var shapes: [ShapeID] = []
    var rects: [CGRect] = []
    var faint: [ShapeID] = []
}

@MainActor private func pictureEditor(log: IndexLog = IndexLog(), outlined: Outlined = Outlined()) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), IndexKinds(log: log), Contributor(id: "pictures") {
        $0.shape(StampDefinition())
        $0.outlines { _ in Outlines(shapes: outlined.shapes, rects: outlined.rects, faintShapes: outlined.faint) }
    }])
}

/// Where every shape is, worked out afresh: what `shapeBounds` must always be. A shape is its
/// outline, its geometry's bounds and its box; with no outline, just its box, and with neither, it
/// could be anywhere, so it doesn't count.
@MainActor private func boundsAfresh(_ editor: CanvasEditor) -> CGRect {
    let fresh = CanvasEditor(registry: editor.registry, document: editor.document, scheduler: ManualScheduler())
    return fresh.paintOrder().reduce(CGRect.null) { bounds, record in
        guard let geometry = fresh.shapeContext.geometry(of: record.id) else { return bounds }
        guard !geometry.outline.isEmpty else { return bounds.union(record.box ?? .null) }
        return bounds.union(CGRect(enclosing: geometry.outline)).union(geometry.bounds).union(record.box ?? .null)
    }
}

// What a picture of the board kept from frame to frame (the minimap's) goes by: the board's bounds,
// where shapes moved or changed shape since it last drew (damage), and what the canvas outlines.
@MainActor let pictureTests = Suite("Pictures", [
    test("the board's bounds take in every shape where it is, and follow them as they grow, move in and go") {
        let h = try pictureEditor()
        expect(h.editor.shapeBounds.isNull, "no shapes, no bounds")
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 100, height: 100))
        let far = h.add(Box(CGRect(x: 900, y: 400, width: 100, height: 100)))
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 1000, height: 500))
        _ = h.add(Tag(target: a))
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 1000, height: 500), "a shape that could be anywhere doesn't count")
        let stamp = h.add(Stamp(frame: CGRect(x: -100, y: 0, width: 50, height: 50)))
        expectEqual(h.editor.shapeBounds, CGRect(x: -100, y: 0, width: 1100, height: 500), "with no outline, a shape counts by its box")
        h.editor.transact { $0.delete([stamp]) }
        let inner = h.add(Box(CGRect(x: 400, y: 200, width: 10, height: 10)))
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 1000, height: 500))
        h.editor.transact { $0.update(inner, as: Box.self) { $0.frame.size = CGSize(width: 10, height: 900) } }
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 1000, height: 1100), "grown past them from inside, a shape grows them")
        for step in 1...3 {
            h.editor.transact { $0.update(inner, as: Box.self) { $0.frame.origin.y += 100 } }
            expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 1000, height: 1100 + CGFloat(step) * 100),
                        "dragged on past the edge it holds, it takes them along")
        }
        h.editor.transact { $0.update(inner, as: Box.self) { $0.frame = CGRect(x: 400, y: 200, width: 10, height: 10) } }
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 1000, height: 500), "back in from the edge, they shrink")
        h.editor.transact { $0.update(far, as: Box.self) { $0.frame.origin = CGPoint(x: 300, y: 50) } }
        expectEqual(h.editor.shapeBounds, CGRect(x: 0, y: 0, width: 410, height: 210))
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 100, y: 100) } }
        expectEqual(h.editor.shapeBounds, boundsAfresh(h.editor))
        h.editor.transact { $0.delete([far, inner]) }
        expectEqual(h.editor.shapeBounds, CGRect(x: 100, y: 100, width: 100, height: 100))
        _ = h.add(Marker(host: a))
        expectEqual(h.editor.shapeBounds, boundsAfresh(h.editor))
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: -500, y: 0) } }
        expectEqual(h.editor.shapeBounds, boundsAfresh(h.editor), "a marker follows its host, and the bounds follow the marker")
        h.editor.transact { $0.delete([a]) }
        expectEqual(h.editor.shapeBounds, CGRect(x: -5, y: -5, width: 10, height: 10), "the marker on its own, at the origin")
    },
    test("shapes kept aside don't count in the board's bounds") {
        let json = #"{ "format" : 1, "schema" : { "box" : 0 }, "shapes" : [ { "id" : "00000000-0000-0000-0000-000000000001", "index" : "a0", "kind" : "gadget", "props" : { "frame" : [[5000, 5000], [10, 10]] } }, { "id" : "00000000-0000-0000-0000-000000000002", "index" : "a1", "kind" : "box", "props" : { "frame" : [[0, 0], [10, 10]] } } ] }"#
        let registry = try Registry(plugins: [FixturesPlugin()])
        let loaded = try BoardCodec(registry: registry).decode(Data(json.utf8))
        let editor = CanvasEditor(registry: registry, document: loaded.document, scheduler: ManualScheduler())
        expectEqual(editor.shapeBounds, CGRect(x: 0, y: 0, width: 10, height: 10))
    },
    test("damage since a mark is where the shapes a commit touched were and are now; nothing, until one does") {
        let h = try pictureEditor()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        _ = h.add(Box(CGRect(x: 500, y: 0, width: 100, height: 100)))
        let mark = h.editor.damageMark
        expect(h.editor.damage(since: mark).isNull)
        h.editor.camera = Camera(origin: CGPoint(x: 40, y: 40), zoom: 2)
        expect(h.editor.damage(since: mark).isNull, "the camera moves no shape")
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 200, y: 50) } }
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 300, height: 150))
        let later = h.editor.damageMark
        expect(h.editor.damage(since: later).isNull)
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 200, y: 300) } }
        expectEqual(h.editor.damage(since: later), CGRect(x: 200, y: 50, width: 100, height: 350))
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 300, height: 400), "since the first mark, every place it's been")
    },
    test("where a picture last drew a shape stays in the damage through commits nobody drew between") {
        let h = try pictureEditor()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let mark = h.editor.damageMark
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 1000, y: 1000) } }
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 200, y: 0) } }
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 300, height: 100), "where it was drawn, and where it is")
    },
    test("damage takes in shapes added, removed and moved in the stack") {
        let h = try pictureEditor()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 50, width: 100, height: 100)))
        var mark = h.editor.damageMark
        let c = h.add(Box(CGRect(x: 300, y: 300, width: 10, height: 10)))
        expectEqual(h.editor.damage(since: mark), CGRect(x: 300, y: 300, width: 10, height: 10))
        mark = h.editor.damageMark
        h.editor.transact { $0.bringToFront(a) }
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 100, height: 100))
        mark = h.editor.damageMark
        h.editor.transact { $0.delete([b, c]) }
        expectEqual(h.editor.damage(since: mark), CGRect(x: 50, y: 50, width: 260, height: 260))
    },
    test("damage takes in a whole other document put in place") {
        let h = try pictureEditor()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        _ = h.add(Box(CGRect(x: 500, y: 0, width: 100, height: 100)))
        let mark = h.editor.damageMark
        let other = CanvasEditor(registry: h.editor.registry, document: h.editor.document, scheduler: ManualScheduler())
        other.transact { $0.update(a, as: Box.self) { $0.frame.origin.y = 800 } }
        h.editor.replaceDocument(with: other.document)
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 100, height: 900))
    },
    test("damage follows a shape whose geometry looked up the one that changed, where it was and where it went") {
        let h = try pictureEditor()
        let host = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        _ = h.add(Marker(host: host))                   // a 10 × 10 square on the host's top-right corner
        let mark = h.editor.damageMark
        h.editor.transact { $0.update(host, as: Box.self) { $0.frame.origin = CGPoint(x: 500, y: 300) } }
        // The marker was at (95, -5), above the host, and went to (595, 295), right of it: each
        // place widens the damage past the host's two.
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: -5, width: 605, height: 405))
    },
    test("damage takes in a shape whose geometry follows the camera, as the camera moves") {
        let h = try pictureEditor()
        _ = h.add(Badge())                               // 20 view points a side, at the origin
        let mark = h.editor.damageMark
        h.editor.camera = Camera(zoom: 0.5)
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 40, height: 40))
    },
    test("damage is everywhere when a shape that could be anywhere changes") {
        let h = try pictureEditor()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let tag = h.add(Tag(target: nil))
        let mark = h.editor.damageMark
        h.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = a } }
        expect(h.editor.damage(since: mark).isInfinite)
    },
    test("damage reaches back 512 commits; further back, it's everywhere") {
        let h = try pictureEditor()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let mark = h.editor.damageMark
        for x in 1...512 { h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = CGFloat(x) } } }
        expectEqual(h.editor.damage(since: mark), CGRect(x: 0, y: 0, width: 522, height: 10))
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin.x = 0 } }
        expect(h.editor.damage(since: mark).isInfinite, "513 commits back")
    },
    test("what the canvas outlines is every plugin's outlines and the hint, and a faint shape only if it isn't outlined in full") {
        let outlined = Outlined()
        let h = try pictureEditor(outlined: outlined)
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let b = h.add(Box(CGRect(x: 20, y: 0, width: 10, height: 10)))
        let c = h.add(Box(CGRect(x: 40, y: 0, width: 10, height: 10)))
        outlined.shapes = [a]
        outlined.faint = [a, b]
        outlined.rects = [CGRect(x: 0, y: 0, width: 30, height: 10)]
        h.editor.hintedShapeID = c
        expectEqual(h.editor.outlines.shapes, [a, c])
        expectEqual(h.editor.outlines.faintShapes, [b])
        expectEqual(h.editor.outlines.rects, [CGRect(x: 0, y: 0, width: 30, height: 10)])
    },
])
