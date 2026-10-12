@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Putting a container down around shapes (`editor.place(_:around:padding:minimumSize:)`, what Frames'
// Create Frame puts a frame down with), with CanvasTesting's corrals standing in for frames: a corral
// framed around boxes, holding them where they are, in the container they're all in, just below the
// lowest of them in the stack; what it lands on settled by the in-or-out rule (in or out, 16 world units
// from an edge, `Style.containerGap`); all or nothing for read-only shapes. The camera is at the origin
// at 100%.

/// What services heard put down (`EditorService.didPlace`), in order.
@MainActor private final class PlacedLog {
    var placed: [ShapeID] = []
}

extension PlacedLog: EditorService {
    func didPlace(_ id: ShapeID, in editor: CanvasEditor) { placed.append(id) }
}

/// Bound to two shapes, as an arrow is, and hanging `sag` below the line between their middles: an
/// arrow bent away from what it joins, whose bounds reach past them.
struct Sling: ShapeProps {
    static let kind: ShapeKind = "sling"
    static let properties = Properties<Sling> {
        Property("from", \.from)
        Property("to", \.to)
        Property("sag", \.sag)
    }
    var from: ShapeID?
    var to: ShapeID?
    var sag: CGFloat
}

extension Sling {
    init() { self.init(from: nil, to: nil, sag: 0) }
}

struct SlingDefinition {}

extension SlingDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sling>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Sling>, in context: ShapeContext) -> ShapeGeometry {
        func middle(_ id: ShapeID?) -> CGPoint? {
            id.flatMap(context.geometry(of:)).map { CGPoint(x: $0.bounds.midX, y: $0.bounds.midY) }
        }
        guard let from = middle(shape.props.from), let to = middle(shape.props.to) else {
            return ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
        }
        let low = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + shape.props.sag)
        return ShapeGeometry(outline: [from, low, to], isClosed: false)
    }
}

extension SlingDefinition: ShapeReferencing {
    func remappingReferences(of shape: ShapeRecord<Sling>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> Sling? {
        Sling(from: shape.props.from.flatMap(map), to: shape.props.to.flatMap(map), sag: shape.props.sag)
    }
}

/// Boxes, corrals, pockets, slings, the freezing flag (refusals in `refusals`) and what's put down.
@MainActor private func enclosingPlugins(_ refusals: RefusalLog) -> [any CanvasPlugin] {
    [FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), FreezingPlugin(log: refusals), Contributor(id: "slings") { $0.shape(SlingDefinition()) },
     Contributor(id: "placed") { $0.service { _ in PlacedLog() } }]
}

@MainActor private func enclosingHarness(_ refusals: RefusalLog = RefusalLog(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: enclosingPlugins(refusals) + more)
}

extension EditorHarness {
    /// A corral put down around shapes, `padding` past them.
    fileprivate func corral(around ids: [ShapeID], padding: CGFloat = 20, minimumSize: CGSize = .zero) -> ShapeID? {
        editor.place(ShapeRecord(Corral()), around: ids, padding: padding, minimumSize: minimumSize)
    }

    fileprivate func box(_ id: ShapeID) -> CGRect? { editor.document[id]?.box }
    fileprivate var stack: [ShapeID] { editor.document.shapes.map(\.id) }
    fileprivate var placed: [ShapeID] { editor.service(PlacedLog.self)?.placed ?? [] }
}

@MainActor let enclosingTests = Suite("Putting a container down around shapes", [
    test("around boxes on the board, it holds them where they are, padded, just below the lowest of them: one step, named as a placement's, put down as one is") {
        let h = try enclosingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 80)))
        let b = h.add(Box(CGRect(x: 300, y: 150, width: 100, height: 80)))
        let far = h.add(Box(CGRect(x: 900, y: 600, width: 50, height: 50)))
        let pen = try require(h.corral(around: [a, b]))
        expectEqual(h.box(pen), CGRect(x: 80, y: 80, width: 340, height: 170), "around both, 20 past them")
        expectEqual(h.editor.holder(of: a), pen)
        expectEqual(h.editor.holder(of: b), pen)
        expectEqual(h.editor.holder(of: far), nil)
        expectEqual(h.box(a), CGRect(x: 100, y: 100, width: 100, height: 80), "where it was")
        expectEqual(h.box(b), CGRect(x: 300, y: 150, width: 100, height: 80))
        expectEqual(h.stack, [pen, a, b, far], "just below them, what it holds where it was in the stack")
        expectEqual(h.placed, [pen], "put down: the selection would select it")
        expectEqual(h.editor.undoHistory.undoName, "Add corral")
        h.editor.undo()
        expectEqual(h.stack, [a, b, far])
        expectEqual(h.editor.holder(of: a), nil)
        h.editor.redo()
        expectEqual(h.stack, [pen, a, b, far])
        expectEqual(h.editor.holder(of: b), pen)
    },

    test("around a stretch it holds the frame it is laid out in, padded, and not the box it stores") {
        let h = try enclosingHarness(RefusalLog(), [StretchesPlugin()])
        let gauge = h.add(StretchGauge(CGRect(x: 900, y: 900, width: 60, height: 40), width: 300, height: 200))
        let stretch = h.add(Stretch(CGRect(x: 100, y: 100, width: 100, height: 80), gauge: gauge))
        let box = h.add(Box(CGRect(x: 450, y: 150, width: 50, height: 50)))
        let pen = try require(h.corral(around: [stretch, box]))
        expectEqual(h.box(pen), CGRect(x: 80, y: 80, width: 440, height: 240), "its 300 by 200, the box beside it, 20 past them")
        expectEqual(h.editor.holder(of: stretch), pen)
        expectEqual(h.box(stretch), CGRect(x: 100, y: 100, width: 100, height: 80), "the stretch stores what it did")
    },

    test("never under the minimum size, grown about its middle") {
        let h = try enclosingHarness()
        let a = h.add(Box(CGRect(x: 200, y: 200, width: 10, height: 10)))
        let pen = try require(h.corral(around: [a], minimumSize: CGSize(width: 96, height: 64)))
        expectEqual(h.box(pen), CGRect(x: 157, y: 173, width: 96, height: 64))
        expectEqual(h.editor.holder(of: a), pen)
    },

    test("in the container they're all in: in it, just above it, kept the gap inside its edge, unless what it holds is nearer the edge") {
        let h = try enclosingHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 10, y: 30, width: 100, height: 80)))     // 10 in from the left edge
        let b = h.add(Box(CGRect(x: 200, y: 100, width: 100, height: 80)))
        h.editor.put([a, b], in: outer)
        let pen = try require(h.corral(around: [a, b]))
        // 20 past them but on the left, where a is nearer the edge than the gap, and the top, 16 in.
        expectEqual(h.box(pen), CGRect(x: 10, y: 16, width: 310, height: 184))
        expectEqual(h.editor.holder(of: pen), outer)
        expectEqual(h.editor.holder(of: a), pen)
        expectEqual(h.editor.holder(of: b), pen)
        expectEqual(h.stack, [outer, pen, a, b], "just above the container it's in")
    },

    test("a container asked for with what it holds goes in whole, what it holds with it") {
        let h = try enclosingHarness()
        let inner = h.add(Corral(CGRect(x: 100, y: 100, width: 200, height: 150)))
        let x = h.add(Box(CGRect(x: 120, y: 120, width: 50, height: 50)))
        h.editor.put([x], in: inner)
        let y = h.add(Box(CGRect(x: 400, y: 100, width: 50, height: 50)))
        let pen = try require(h.corral(around: [x, inner, y]))
        expectEqual(h.box(pen), CGRect(x: 80, y: 80, width: 390, height: 190))
        expectEqual(h.editor.holder(of: inner), pen)
        expectEqual(h.editor.holder(of: x), inner)
        expectEqual(h.editor.holder(of: y), pen)
    },

    test("what it lands on beside them is settled: mostly inside comes in, nudged in; mostly outside is nudged out; gliding there; a read-only one stays, above it") {
        let h = try enclosingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let inside = h.add(Box(CGRect(x: 200, y: 180, width: 60, height: 60)))     // two thirds inside its bottom edge
        let outside = h.add(Box(CGRect(x: 400, y: 150, width: 60, height: 40)))    // a third inside its right edge
        let frozen = h.add(Box(CGRect(x: 100, y: 200, width: 60, height: 60)))     // a third inside its bottom edge
        h.editor.freeze([frozen])
        let pen = try require(h.corral(around: [a, b]))
        expectEqual(h.box(pen), CGRect(x: 80, y: 80, width: 340, height: 140))
        expectEqual(h.editor.holder(of: inside), pen)
        expectEqual(h.box(inside), CGRect(x: 200, y: 144, width: 60, height: 60), "nudged in, 16 inside its edge")
        expectEqual(h.editor.holder(of: outside), nil)
        expectEqual(h.box(outside), CGRect(x: 436, y: 150, width: 60, height: 40), "nudged out, 16 outside it")
        expect(h.editor.isGliding(inside) && h.editor.isGliding(outside), "gliding there")
        expect(!h.editor.isGliding(a) && !h.editor.isGliding(b), "what it holds stays where it was")
        expectEqual(h.editor.holder(of: frozen), nil)
        expectEqual(h.box(frozen), CGRect(x: 100, y: 200, width: 60, height: 60), "read-only: where it was")
        expect(try require(h.stack.firstIndex(of: pen)) < require(h.stack.firstIndex(of: frozen)), "painted above it, not hidden under it")
        h.wait(300)
        expect(!h.editor.isGliding(inside) && !h.editor.isGliding(outside))
    },

    test("shapes from two containers: it goes in the innermost holding both, or on the board, taking them out; one it took out of a container it then takes in goes back in, above it") {
        let h = try enclosingHarness()
        let small = h.add(Corral(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let a = h.add(Box(CGRect(x: 120, y: 120, width: 60, height: 60)))
        h.editor.put([a], in: small)
        let b = h.add(Box(CGRect(x: 300, y: 120, width: 60, height: 60)))
        let pen = try require(h.corral(around: [a, b]))
        expectEqual(h.box(pen), CGRect(x: 100, y: 100, width: 280, height: 100))
        expectEqual(h.editor.holder(of: pen), nil)
        expectEqual(h.editor.holder(of: small), pen, "the corral a came out of is wholly inside it: it comes in")
        expectEqual(h.editor.holder(of: a), small, "and a goes back into that one, not left under it")
        expectEqual(h.editor.holder(of: b), pen)
        expect(try require(h.stack.firstIndex(of: small)) < require(h.stack.firstIndex(of: a)), "a paints above the corral it's in")

        let other = try enclosingHarness()
        let big = other.add(Corral(CGRect(x: 100, y: 100, width: 200, height: 300)))
        let c = other.add(Box(CGRect(x: 120, y: 120, width: 60, height: 60)))
        other.editor.put([c], in: big)
        let d = other.add(Box(CGRect(x: 400, y: 120, width: 60, height: 60)))
        let around = try require(other.corral(around: [c, d]))
        expectEqual(other.box(around), CGRect(x: 100, y: 100, width: 380, height: 100))
        expectEqual(other.editor.holder(of: c), around, "taken out of the corral it was in")
        expectEqual(other.editor.holder(of: big), nil, "a third of that one is inside it: it's nudged out, the shortest way")
        expectEqual(other.box(big), CGRect(x: 100, y: 216, width: 200, height: 300))
    },

    test("shapes taken out of containers it can't take in or move clear stay in it, though a container they leave is deeper than it: none goes back, leaving it empty") {
        let h = try enclosingHarness()
        let board = h.add(Corral(CGRect(x: 0, y: 0, width: 640, height: 300)))
        let left = h.add(Corral(CGRect(x: 16, y: 16, width: 300, height: 268)))
        let right = h.add(Corral(CGRect(x: 324, y: 16, width: 300, height: 268)))
        h.editor.put([left, right], in: board)
        let inner = h.add(Corral(CGRect(x: 40, y: 40, width: 250, height: 220)))
        h.editor.put([inner], in: left)
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        h.editor.put([a], in: inner)
        let b = h.add(Box(CGRect(x: 400, y: 100, width: 60, height: 60)))
        h.editor.put([b], in: right)
        let pen = try require(h.corral(around: [a, b]))
        expectEqual(h.editor.holder(of: pen), board)
        expectEqual(h.editor.holder(of: left), board, "two thirds outside it, with no room in the board to move clear: where it was")
        expectEqual(h.editor.holder(of: inner), left)
        expectEqual(h.editor.holder(of: a), pen, "not back in the corral it left, which is deeper than the new one and holds all of it")
        expectEqual(h.editor.holder(of: b), pen)
    },

    test("near its container's far corner: kept the gap inside its far edges, and grown to the minimum toward the room it has there") {
        let h = try enclosingHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 500, y: 300, width: 50, height: 40)))
        h.editor.put([a], in: outer)
        let pen = try require(h.corral(around: [a], padding: 50))
        expectEqual(h.box(pen), CGRect(x: 450, y: 250, width: 134, height: 134), "50 past it, but 16 inside the right and bottom edges")
        let small = h.add(Box(CGRect(x: 570, y: 375, width: 20, height: 10)))      // nearer those edges than the gap
        h.editor.put([small], in: outer)
        let around = try require(h.corral(around: [small], padding: 32, minimumSize: CGSize(width: 96, height: 64)))
        expectEqual(h.box(around), CGRect(x: 494, y: 321, width: 96, height: 64), "flush with it on the far sides, grown back toward the room")
        expectEqual(h.editor.holder(of: small), around)
    },

    test("in a small container, near its corner: grown to the minimum inside it, shifted into its room, around what it holds") {
        let h = try enclosingHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 10, y: 30, width: 20, height: 10)))
        h.editor.put([a], in: outer)
        let pen = try require(h.corral(around: [a], padding: 32, minimumSize: CGSize(width: 96, height: 64)))
        expectEqual(h.box(pen), CGRect(x: 10, y: 16, width: 96, height: 64))
        expectEqual(h.editor.holder(of: a), pen)
        expectEqual(h.box(a), CGRect(x: 10, y: 30, width: 20, height: 10))
    },

    test("flush with what it holds, as near its container's edge, it holds it whole to the last bit: nothing it holds is nudged") {
        let h = try enclosingHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        // Coordinates a drag at another zoom leaves, whose far edge an origin plus a size rounds short of.
        let a = h.add(Box(CGRect(x: 42.9118712399266, y: 100, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 502.066335160474, y: 100, width: 92.05238584377098, height: 50)))
        h.editor.put([a, b], in: outer)
        let pen = try require(h.corral(around: [a, b]))
        let frame = try require(h.box(pen)), held = try require(h.box(b))
        expect(frame.contains(held), "\(frame) holds \(held)")
        expectEqual(h.box(b), CGRect(x: 502.066335160474, y: 100, width: 92.05238584377098, height: 50), "where it was")
        expect(!h.editor.isGliding(b))
        expectEqual(h.editor.holder(of: b), pen)
    },

    test("in the stack, just below the lowest of them: what was under them all is under it, a large shape under them too, so it shows on that") {
        let h = try enclosingHarness()
        let under = h.add(Box(CGRect(x: 0, y: 0, width: 1000, height: 800)))
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 80)))
        let between = h.add(Box(CGRect(x: 600, y: 600, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 300, y: 150, width: 100, height: 80)))
        let pen = try require(h.corral(around: [a, b]))
        expectEqual(h.stack, [under, pen, a, between, b])
        expectEqual(h.editor.holder(of: under), nil, "over all of it: beside it, neither in it nor across its edge")
        expectEqual(h.box(under), CGRect(x: 0, y: 0, width: 1000, height: 800))
    },

    test("one that comes naming a container goes in the one they're all in, or on the board") {
        let h = try enclosingHarness()
        let elsewhere = h.add(Corral(CGRect(x: 1000, y: 0, width: 300, height: 300)))
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let pen = try require(h.editor.place(AnyShapeRecord(ShapeRecord(Corral())).copy(as: ShapeID(), container: elsewhere), around: [a],
                                             padding: 20))
        expectEqual(h.editor.holder(of: pen), nil)
        expectEqual(h.editor.holder(of: a), pen)
    },

    test("an arrow between two of them counts toward its size, and one bound to a shape left out doesn't; neither is held") {
        let h = try enclosingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        let c = h.add(Box(CGRect(x: 600, y: 100, width: 60, height: 60)))
        let between = h.add(Sling(from: a, to: b, sag: 150))                      // its low point at (230, 280)
        let across = h.add(Sling(from: b, to: c, sag: 300))
        let pen = try require(h.corral(around: [a, b, between, across]))
        expectEqual(h.box(pen), CGRect(x: 80, y: 80, width: 300, height: 220), "around the boxes and the sling between them")
        expectEqual(h.editor.holder(of: between), nil, "in no container: it follows what it's bound to")
        expectEqual(h.editor.holder(of: c), nil)
    },

    test("nothing it can hold, no shape at all, or a kind that holds nothing: nothing is put down, and no step") {
        let h = try enclosingHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        let between = h.add(Sling(from: a, to: b, sag: 0))
        let steps = h.editor.undoHistory.undoName, shapes = h.stack
        expectEqual(h.corral(around: [between]), nil, "a sling alone has no box")
        expectEqual(h.corral(around: []), nil)
        expectEqual(h.editor.place(ShapeRecord(Box()), around: [a, b]), nil, "a box holds nothing")
        expectEqual(h.stack, shapes)
        expectEqual(h.editor.undoHistory.undoName, steps)
        expectEqual(h.placed, [])
    },

    test("all or nothing: a read-only one among them, one in a read-only container, or shapes on a read-only board leave it all as it was, with no step, and are heard refused") {
        let refusals = RefusalLog()
        let h = try enclosingHarness(refusals)
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        h.editor.freeze([b])
        let steps = h.editor.undoHistory.undoName
        expectEqual(h.corral(around: [a, b]), nil)
        expectEqual(h.stack, [a, b])
        expectEqual(h.editor.holder(of: a), nil)
        expectEqual(refusals.refusals, [[b]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        expectEqual(h.placed, [])

        let held = h.add(Corral(CGRect(x: 0, y: 300, width: 200, height: 200)))
        let c = h.add(Box(CGRect(x: 20, y: 320, width: 50, height: 50)))
        h.editor.put([c], in: held)
        h.editor.freeze([held])
        expectEqual(h.corral(around: [a, c]), nil)
        expectEqual(refusals.refusals.last, [c])
        expectEqual(h.editor.holder(of: c), held)

        let pocket = ShapeID(), x = ShapeID(), y = ShapeID()
        var owner = AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        owner[Frozen.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [owner]), children: [pocket: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: x, Box(CGRect(x: 0, y: 0, width: 40, height: 30)))),
            AnyShapeRecord(ShapeRecord(id: y, Box(CGRect(x: 100, y: 0, width: 40, height: 30)))),
        ])])
        let onBoard = RefusalLog()
        let inside = try EditorHarness(plugins: enclosingPlugins(onBoard), file: file)
        expect(inside.enter(pocket))
        expectEqual(inside.corral(around: [x, y]), nil)
        expectEqual(inside.editor.document.shapes.map(\.id), [x, y])
        expectEqual(onBoard.refusals, [[x, y]], "every shape on a read-only board is")
    },
])
