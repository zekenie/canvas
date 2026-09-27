@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

@MainActor let translateTests = Suite("Translate", [
    test("a drag of a multi-selection moves them all, one commit per drag event; the release commits nothing") {
        let (h, a, b, c) = try threeBoxes()
        h.editor.selectedShapeIDs = [a, b]
        let revision = h.editor.revision
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 60, y: 70))
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 10, y: 20))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 210, y: 20))
        h.drag(to: CGPoint(x: 75, y: 45))
        expectEqual(h.editor.revision, revision + 2)
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 25, y: -5))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 225, y: -5))
        h.release()
        expectEqual(h.editor.revision, revision + 2)
        expectEqual(h.editor.document[c]?.box?.origin, CGPoint(x: 400, y: 0))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expectEqual(h.editor.document.shapes.map(\.id), [a, b, c])
    },
    test("Escape mid-translation reverts every shape (the deliberate change); later drags do nothing") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let before = h.editor.document
        h.editor.selectedShapeIDs = [a, b]
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 80, y: 90)); h.drag(to: CGPoint(x: 120, y: 30))
        let revision = h.editor.revision
        h.escape()
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.document, before)
        expect(h.editor.session == nil)
        h.drag(to: CGPoint(x: 150, y: 150)); h.release()
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },
    test("Escape reverts a lone box's move, and puts a just-placed shape back where it was placed") {
        let h = try EditorHarness(plugins: [Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", shortcut: "d", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
            }
        }])
        let box = h.add(Disc(CGRect(x: 0, y: 0, width: 100, height: 100)))   // this Disc's geometry is its frame
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 70, y: 60))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 20, y: 10))
        h.escape(); h.release()
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expectEqual(h.editor.selection, box)

        h.key("d")
        h.press(at: CGPoint(x: 300, y: 300))
        let disc = try require(h.editor.selection)
        h.drag(to: CGPoint(x: 330, y: 310))
        expectEqual(h.editor.document[disc]?.box?.origin, CGPoint(x: 310, y: 290))
        h.escape(); h.release()
        expectEqual(h.editor.document[disc]?.box?.origin, CGPoint(x: 280, y: 280))
        expectEqual(h.editor.currentToolID, .select)
    },
    test("a CustomTranslation kind: begin runs once for each shape, all in one commit before the first move; its move gets the delta and sees this event's boxes already moved") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PinsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let p = h.add(Pin(point: CGPoint(x: 300, y: 50), follows: box))
        let q = h.add(Pin(point: CGPoint(x: 500, y: 50), follows: nil))
        h.editor.selectedShapeIDs = [box, p, q]
        let revision = h.editor.revision
        h.press(at: CGPoint(x: 300, y: 50))                               // on P
        expectEqual(h.editor.revision, revision)
        h.drag(to: CGPoint(x: 310, y: 70))
        expectEqual(h.editor.revision, revision + 2, "the begins, then the move")
        let pin = try require(h.editor.document[p]?.typed(as: Pin.self)?.props)
        expectEqual(pin.begins, 1)
        expectEqual(pin.moving, [box, p, q])
        expectEqual(pin.point, CGPoint(x: 310, y: 70))
        expectEqual(pin.seen, CGPoint(x: 10, y: 20), "the box had already moved in this event")
        h.drag(to: CGPoint(x: 290, y: 40))
        expectEqual(h.editor.revision, revision + 3)
        expectEqual(h.editor.document[p]?.typed(as: Pin.self)?.props.begins, 1)
        expectEqual(h.editor.document[p]?.typed(as: Pin.self)?.props.seen, CGPoint(x: -10, y: -10))
        expectEqual(h.editor.document[q]?.typed(as: Pin.self)?.props.begins, 1)
        expectEqual(h.editor.document[q]?.typed(as: Pin.self)?.props.point, CGPoint(x: 490, y: 40))
        h.release()
    },
    test("Escape puts a CustomTranslation kind back as it was before its begin") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), PinsPlugin()])
        let p = h.add(Pin(point: CGPoint(x: 300, y: 50), follows: nil))
        let before = h.editor.document
        h.press(at: CGPoint(x: 300, y: 50)); h.drag(to: CGPoint(x: 340, y: 90))
        expectEqual(h.editor.document[p]?.typed(as: Pin.self)?.props.begins, 1)
        h.escape(); h.release()
        expectEqual(h.editor.document, before)
    },
    test("a kind with neither a box nor a custom translation stays put while the rest move") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let tag = h.add(Tag(target: box))
        let before = h.editor.document[tag]
        h.editor.selectedShapeIDs = [box, tag]
        let revision = h.editor.revision
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 60, y: 70)); h.drag(to: CGPoint(x: 70, y: 70))
        expectEqual(h.editor.revision, revision + 2)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 20, y: 20))
        expectEqual(h.editor.document[tag], before)
        h.release()
    },
    test("the lone-box fast path and a multi-selection member end at the same place for the same drag") {
        let frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        let press = CGPoint(x: 101.25, y: 99.5)
        let points = [CGPoint(x: 143.7, y: 151.3), CGPoint(x: 157.9, y: 172.1), CGPoint(x: 0.1, y: 0.7)]
        let lone = try EditorHarness(plugins: [FixturesPlugin()])
        let loneBox = lone.add(Box(frame))
        let multi = try EditorHarness(plugins: [FixturesPlugin()])
        let multiBox = multi.add(Box(frame))
        let other = multi.add(Box(CGRect(x: 900, y: 900, width: 10, height: 10)))
        multi.editor.selectedShapeIDs = [multiBox, other]
        for h in [lone, multi] {
            h.editor.camera = Camera(origin: .zero, zoom: 0.6)
            h.press(at: press)
        }
        expect(lone.editor.session != nil && multi.editor.session != nil)
        for point in points {
            lone.drag(to: point)
            multi.drag(to: point)
            expectEqual(multi.editor.document[multiBox]?.box, lone.editor.document[loneBox]?.box)
        }
        lone.release(); multi.release()
    },
])

/// A kind with no box that moves by its own rules, for the CustomTranslation contract. `follows`
/// names a box whose origin each move records in `seen`.
struct Pin: ShapeProps {
    static let kind: ShapeKind = "pin"
    var point: CGPoint
    var follows: ShapeID?
    var begins = 0
    var moving: Set<ShapeID> = []
    var seen: CGPoint?
}

struct PinDefinition {}

extension PinDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pin>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Pin>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: CGRect(center: shape.props.point, size: CGSize(width: 20, height: 20)).polygon)
    }
}

extension PinDefinition: CustomTranslation {
    func beginTranslation(of shape: ShapeRecord<Pin>, movingWith moving: Set<ShapeID>,
                          in transaction: inout Transaction) -> ShapeTranslation<Pin> {
        transaction.update(shape.id, as: Pin.self) {
            $0.props.begins += 1
            $0.props.moving = moving
        }
        let start = shape.props.point
        return ShapeTranslation { delta, shape, shapes in
            shape.props.point = start + delta
            shape.props.seen = shape.props.follows.flatMap { shapes.geometry(of: $0)?.bounds.origin }
        }
    }
}

struct PinsPlugin: CanvasPlugin {
    var id: PluginID { "pins" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(PinDefinition()) }
}
