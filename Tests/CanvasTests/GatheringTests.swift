@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Putting a shape that owns a board down where shapes are, taking them onto its board
// (`editor.place(_:taking:)`, what Subboards' Create Subboard puts a subboard down with), with
// CanvasTesting's pockets standing in for subboards and corrals for frames: the pocket at its own size,
// its top-left corner at theirs, in the container they're all in, where the lowest of them was in the
// stack; they go onto its board where they are, with what they hold and the links between them; all or
// nothing for read-only shapes. The camera is at the origin at 100%.

/// Boxes, corrals, pockets, links, the freezing flag (refusals in `refusals`) and what's put down (EnclosingTests' `PlacedLog`).
@MainActor private func gatheringPlugins(_ refusals: RefusalLog) -> [any CanvasPlugin] {
    [FixturesPlugin(), CorralsPlugin(), PocketsPlugin(), LinksPlugin(), FreezingPlugin(log: refusals),
     Contributor(id: "placed") { $0.service { _ in PlacedLog() } }]
}

@MainActor private func gatheringHarness(_ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    try EditorHarness(plugins: gatheringPlugins(refusals))
}

/// A subboard's size.
private let card = CGSize(width: 240, height: 160)

extension EditorHarness {
    /// A pocket of a subboard's size put down taking shapes onto its board.
    fileprivate func pocket(taking ids: [ShapeID]) -> ShapeID? {
        editor.place(ShapeRecord(Pocket(CGRect(origin: .zero, size: card))), taking: ids)
    }

    fileprivate func box(_ id: ShapeID) -> CGRect? { editor.document[id]?.box }
    fileprivate var stack: [ShapeID] { editor.document.shapes.map(\.id) }
    /// What a pocket's board holds, back to front.
    fileprivate func inside(_ pocket: ShapeID) -> [ShapeID] { file[BoardID(owner: pocket)].shapes.map(\.id) }
    fileprivate func record(_ id: ShapeID, on pocket: ShapeID) -> AnyShapeRecord? { file[BoardID(owner: pocket)][id] }
    fileprivate var placed: [ShapeID] { editor.service(PlacedLog.self)?.placed ?? [] }
}

@MainActor let gatheringTests = Suite("Putting a shape that owns a board down, taking shapes onto it", [
    test("at its own size, its top-left at theirs, where the lowest of them was; they go onto its board where they are: one step, named as a placement's, put down as one is, undone and redone whole") {
        let h = try gatheringHarness()
        let under = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 80)))
        let between = h.add(Box(CGRect(x: 900, y: 900, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 300, y: 150, width: 100, height: 80)))
        let before = h.file
        let pocket = try require(h.pocket(taking: [b, a]))
        expectEqual(h.box(pocket), CGRect(origin: CGPoint(x: 100, y: 100), size: card), "at the top-left of the two, its own size")
        expectEqual(h.stack, [under, pocket, between], "where the lowest of them was: what was above it stays above it")
        expectEqual(h.inside(pocket), [a, b], "on its board, in their order")
        expectEqual(h.record(a, on: pocket)?.box, CGRect(x: 100, y: 100, width: 100, height: 80), "where it was")
        expectEqual(h.record(b, on: pocket)?.box, CGRect(x: 300, y: 150, width: 100, height: 80))
        expectEqual(h.placed, [pocket], "put down: the selection would select it")
        expectEqual(h.editor.undoHistory.undoName, "Add pocket")
        let after = h.file
        h.editor.undo()
        expectEqual(h.file, before, "both boards as they were")
        h.editor.redo()
        expectEqual(h.file, after)
    },

    test("in the container they're all in, kept the gap inside its edge where it fits, as a turned shape is: in from an edge they were nearer than that, and back from its far edges") {
        let h = try gatheringHarness()
        let outer = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.add(Box(CGRect(x: 10, y: 30, width: 100, height: 80)))      // 10 in from the left edge
        let b = h.add(Box(CGRect(x: 200, y: 100, width: 100, height: 80)))
        h.editor.put([a, b], in: outer)
        let pocket = try require(h.pocket(taking: [a, b]))
        expectEqual(h.box(pocket), CGRect(origin: CGPoint(x: 16, y: 30), size: card), "16 in from the left edge")
        expectEqual(h.editor.holder(of: pocket), outer)
        expectEqual(h.stack, [outer, pocket])
        expectEqual(h.record(a, on: pocket)?.container, nil, "in no container on its board: the corral stayed")

        let corner = h.add(Box(CGRect(x: 500, y: 300, width: 50, height: 40)))
        h.editor.put([corner], in: outer)
        let far = try require(h.pocket(taking: [corner]))
        expectEqual(h.box(far), CGRect(origin: CGPoint(x: 344, y: 224), size: card), "16 inside the right and bottom edges")
        expectEqual(h.editor.holder(of: far), outer)
    },

    test("too big for the container they're in, it goes as the in-or-out rule says: out of it, nudged clear, gliding there") {
        let h = try gatheringHarness()
        let small = h.add(Corral(CGRect(x: 0, y: 0, width: 200, height: 150)))
        let a = h.add(Box(CGRect(x: 20, y: 20, width: 40, height: 30)))
        h.editor.put([a], in: small)
        let pocket = try require(h.pocket(taking: [a]))
        expectEqual(h.editor.holder(of: pocket), nil, "a shape too big for a container can't be in it")
        let box = try require(h.box(pocket))
        expect(!box.intersects(CGRect(x: 0, y: 0, width: 200, height: 150)), "clear of it: \(box)")
        expect(h.editor.isGliding(pocket), "gliding there")
        expectEqual(h.inside(pocket), [a])
    },

    test("shapes from two containers: it goes in the innermost holding both, or on the board, nudged out of another it reaches into") {
        let h = try gatheringHarness()
        let small = h.add(Corral(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let a = h.add(Box(CGRect(x: 120, y: 120, width: 60, height: 60)))
        h.editor.put([a], in: small)
        let b = h.add(Box(CGRect(x: 300, y: 120, width: 60, height: 60)))
        let pocket = try require(h.pocket(taking: [a, b]))
        expectEqual(h.editor.holder(of: pocket), nil, "on the board, where the corral is")
        let box = try require(h.box(pocket))
        expect(!box.intersects(CGRect(x: 100, y: 100, width: 100, height: 100)), "mostly outside the corral it reached into, nudged out of it: \(box)")
        expectEqual(Set(h.inside(pocket)), [a, b])
        expect(h.editor.document.shapes.contains { $0.id == small }, "the corral a left stays, empty")
    },

    test("a container among them goes with what it holds, and one of them a container among them holds goes with it, still in it there") {
        let h = try gatheringHarness()
        let inner = h.add(Corral(CGRect(x: 100, y: 100, width: 200, height: 150)))
        let x = h.add(Box(CGRect(x: 120, y: 120, width: 50, height: 50)))
        h.editor.put([x], in: inner)
        let y = h.add(Box(CGRect(x: 400, y: 100, width: 50, height: 50)))
        let pocket = try require(h.pocket(taking: [x, inner, y]))
        expectEqual(h.box(pocket), CGRect(origin: CGPoint(x: 100, y: 100), size: card))
        expectEqual(h.inside(pocket), [inner, x, y])
        expectEqual(h.record(x, on: pocket)?.container, inner, "still in the corral it was in")
        expectEqual(h.record(inner, on: pocket)?.box, CGRect(x: 100, y: 100, width: 200, height: 150))
    },

    test("a link between two of them goes along; one to a shape left out lets go of what moves, where it's drawn") {
        let h = try gatheringHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        let c = h.add(Box(CGRect(x: 600, y: 100, width: 60, height: 60)))
        let between = h.add(Link(from: a, to: b))
        let across = h.add(Link(from: b, to: c))
        let pocket = try require(h.pocket(taking: [a, b]))
        expectEqual(Set(h.inside(pocket)), [a, b, between], "the link between them with them")
        let left = try require(h.editor.document[across]?.typed(as: Link.self))
        expectEqual(left.props.from, nil, "let go of b")
        expectEqual(left.props.to, c)
    },

    test("taking the shape being edited, it goes onto the pocket's board, its editing over and its text kept") {
        let h = try EditorHarness(plugins: gatheringPlugins(RefusalLog()) + [CardsPlugin()])
        let note = h.add(Card(CGRect(x: 100, y: 100, width: 120, height: 80), text: "keep"))
        expect(h.editor.beginEditing(note))
        let pocket = try require(h.pocket(taking: [note]))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.inside(pocket), [note])
        expectEqual(h.record(note, on: pocket)?.typed(as: Card.self)?.props.text, "keep")
        expectEqual(h.placed, [pocket])
    },

    test("nothing it can take, no shape at all, or a kind that owns no board: nothing is put down, and no step") {
        let h = try gatheringHarness()
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        let between = h.add(Link(from: a, to: b))
        let steps = h.editor.undoHistory.undoName, shapes = h.stack
        expectEqual(h.pocket(taking: [between]), nil, "a link alone has no box")
        expectEqual(h.pocket(taking: []), nil)
        expectEqual(h.editor.place(ShapeRecord(Corral(CGRect(origin: .zero, size: card))), taking: [a, b]), nil, "a corral owns no board")
        expectEqual(h.stack, shapes)
        expectEqual(h.editor.undoHistory.undoName, steps)
        expectEqual(h.placed, [])
    },

    test("a read-only shape a container among them holds refuses it all too, and is heard: the move takes what a container holds") {
        let refusals = RefusalLog()
        let h = try gatheringHarness(refusals)
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 200)))
        let held = h.add(Box(CGRect(x: 20, y: 20, width: 50, height: 50)))
        h.editor.put([held], in: pen)
        h.editor.freeze([held])
        let steps = h.editor.undoHistory.undoName, shapes = h.stack
        expectEqual(h.pocket(taking: [pen]), nil)
        expectEqual(h.stack, shapes, "all as it was")
        expectEqual(h.editor.holder(of: held), pen)
        expectEqual(refusals.refusals, [[held]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
    },

    test("all or nothing: a read-only one among them, one in a read-only container, a read-only link between two of them, or shapes on a read-only board leave it all as it was, with no step, and are heard refused") {
        let refusals = RefusalLog()
        let h = try gatheringHarness(refusals)
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 60, height: 60)))
        let b = h.add(Box(CGRect(x: 300, y: 100, width: 60, height: 60)))
        h.editor.freeze([b])
        let steps = h.editor.undoHistory.undoName
        expectEqual(h.pocket(taking: [a, b]), nil)
        expectEqual(h.stack, [a, b])
        expectEqual(refusals.refusals, [[b]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        expectEqual(h.placed, [])
        h.editor.freeze([b], false)

        let held = h.add(Corral(CGRect(x: 0, y: 300, width: 200, height: 200)))
        let c = h.add(Box(CGRect(x: 20, y: 320, width: 50, height: 50)))
        h.editor.put([c], in: held)
        h.editor.freeze([held])
        expectEqual(h.pocket(taking: [a, c]), nil)
        expectEqual(refusals.refusals.last, [c])
        expectEqual(h.editor.holder(of: c), held)
        h.editor.freeze([held], false)

        let link = h.add(Link(from: a, to: b))
        h.editor.freeze([link])
        let shapes = h.stack
        expectEqual(h.pocket(taking: [a, b]), nil, "the move would leave it behind, let go of both ends")
        expectEqual(refusals.refusals.last, [link])
        expectEqual(h.stack, shapes)
        expectEqual(h.editor.document[link]?.typed(as: Link.self)?.props.from, a, "still bound")

        let owner = ShapeID(), x = ShapeID(), y = ShapeID()
        var frozen = AnyShapeRecord(ShapeRecord(id: owner, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        frozen[Frozen.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [frozen]), children: [owner: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: x, Box(CGRect(x: 0, y: 0, width: 40, height: 30)))),
            AnyShapeRecord(ShapeRecord(id: y, Box(CGRect(x: 100, y: 0, width: 40, height: 30)))),
        ])])
        let onBoard = RefusalLog()
        let inside = try EditorHarness(plugins: gatheringPlugins(onBoard), file: file)
        expect(inside.enter(owner))
        expectEqual(inside.pocket(taking: [x, y]), nil)
        expectEqual(inside.editor.document.shapes.map(\.id), [x, y])
        expectEqual(onBoard.refusals, [[x, y]], "every shape on a read-only board is")
    },
])
