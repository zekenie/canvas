import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import ContextMenus
import CoreGraphics
import Foundation
import Keyboard
import Selection
import TestKit

// Copying a container (CanvasTesting's corral, for a frame) copies what it holds, at any depth, each
// copy in its copied container; a paste puts what it pastes down as one by the in-or-out rule where
// it lands; a cut and its paste move a container with what it holds.

/// Corral A (0, 0, 600 × 400) holding box B and corral C (300, 100, 200 × 200), which holds disc D.
@MainActor private struct Nested {
    static let a = CGRect(x: 0, y: 0, width: 600, height: 400)
    static let b = CGRect(x: 50, y: 50, width: 100, height: 100)
    static let c = CGRect(x: 300, y: 100, width: 200, height: 200)
    static let d = CGRect(x: 350, y: 150, width: 50, height: 50)

    let a: ShapeID, b: ShapeID, c: ShapeID, d: ShapeID

    init(_ h: EditorHarness) {
        a = h.add(Corral(Self.a))
        b = h.add(Box(Self.b))
        c = h.add(Corral(Self.c))
        d = h.add(Disc(Self.d))
        h.editor.put([b, c], in: a)
        h.editor.put([d], in: c)
    }

    var ids: [ShapeID] { [a, b, c, d] }
}

/// The format the pasteboard's shapes are written in.
@MainActor private func format(on pasteboard: NSPasteboard) throws -> Int? {
    let data = try require(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")))
    return try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])["format"] as? Int
}

@MainActor let containerTests = Suite("Copying what a container holds", [
    test("copying a corral copies what it holds, at any depth (format 5); pasted in place, each copy is in its copied container, and the copy lies over the original, beside it") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        let n = Nested(h)
        h.editor.selection = n.a
        expect(h.command("c"))
        expectEqual(try format(on: pasteboard), 5)
        let before = h.editor.document
        expect(h.command("v"))
        let pasted = h.editor.shapes(since: before)
        expectEqual(pasted.map(\.copiedFrom), n.ids)
        expectEqual(pasted.map(\.box), [Nested.a, Nested.b, Nested.c, Nested.d], "in place")
        let ids = pasted.map(\.id)
        expectEqual(ids.map { h.editor.holder(of: $0) }, [nil, ids[0], ids[0], ids[2]])
        expectEqual(h.editor.selectedShapeIDs, [ids[0]], "what isn't in another shape pasted with it")
        expectEqual(n.ids.map { h.editor.holder(of: $0) }, [nil, n.a, n.a, n.c], "over all of the original, the copy isn't in it, nor takes what it holds")
    },
    test("pasted where it lands on other shapes, a corral takes in what's mostly inside it, as one put down does") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        let n = Nested(h)
        let loose = h.add(Box(CGRect(x: 1950, y: 1950, width: 100, height: 100)))
        h.editor.copy([n.a])
        h.editor.paste(centeredAt: CGPoint(x: 2000, y: 2000))              // the copy at (1700, 1800)
        let copy = try require(h.editor.selection)
        expectEqual(h.editor.document[copy]?.box, CGRect(x: 1700, y: 1800, width: 600, height: 400))
        expectEqual(h.editor.holder(of: loose), copy)
        expectEqual(h.editor.document.shapes.filter { h.editor.holder(of: $0.id) == copy }.count, 3, "its own box and corral, and the box it landed on")
    },
    test("a locked corral's copy is locked, with copies of what it holds in it, and takes in nothing it lands on") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin(), FreezingPlugin()])
        let n = Nested(h)
        h.editor.freeze([n.a])
        let loose = h.add(Box(CGRect(x: 1950, y: 1950, width: 100, height: 100)))
        h.editor.copy([n.a])
        h.editor.paste(centeredAt: CGPoint(x: 2000, y: 2000))
        let copy = try require(h.editor.selection)
        expect(h.editor.isReadOnly(copy))
        expectEqual(h.editor.document.shapes.filter { h.editor.holder(of: $0.id) == copy }.count, 2, "its own box and corral")
        expectEqual(h.editor.holder(of: loose), nil, "a locked corral takes nothing new")
        expect(!h.editor.isReadOnly(loose))
    },
    test("a shape copied without its container pastes in none (written without one), and settles where it lands: in place, into the container it lies in; elsewhere, out") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        let n = Nested(h)
        expectEqual(h.editor.copy([n.d]), [n.d])
        expect(try require(try format(on: pasteboard)) < 5, "no container copied, none written")
        h.editor.paste()
        let inPlace = try require(h.editor.selection)
        expectEqual(h.editor.holder(of: inPlace), n.c, "over its original, in the corral that holds it")
        expectEqual(h.editor.document[inPlace]?.box, Nested.d)
        expect(!h.editor.isGliding(inPlace), "wholly inside: nothing to nudge")
        h.editor.paste(centeredAt: CGPoint(x: 1000, y: 1000))
        let away = try require(h.editor.selection)
        expectEqual(h.editor.holder(of: away), nil)
    },
    test("pasted across a corral's edge, mostly inside, it goes in, nudged fully in, gliding there, in the paste's step; mostly outside, it's nudged out") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let box = h.add(Box(CGRect(x: 600, y: 0, width: 100, height: 100)))
        h.editor.copy([box])
        let before = h.editor.document
        h.editor.paste(centeredAt: CGPoint(x: 380, y: 150))               // x 330…430: 70% in
        let inside = try require(h.editor.selection)
        expectEqual(h.editor.holder(of: inside), pen)
        expectEqual(h.editor.document[inside]?.box, CGRect(x: 284, y: 100, width: 100, height: 100), "16 in from the edge")
        expectEqual(h.editor.drawingOffset(of: inside), CGPoint(x: 46, y: 0), "drawn where it landed")
        expect(h.editor.isGliding(inside))
        h.wait(256)
        expectEqual(h.editor.drawingOffset(of: inside), .zero)
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        h.editor.undo()
        expectEqual(h.editor.document, before, "one step: undone, as if never pasted")
        h.editor.redo()
        expectEqual(h.editor.holder(of: inside), pen)
        expectEqual(h.editor.document[inside]?.box, CGRect(x: 284, y: 100, width: 100, height: 100))

        h.editor.paste(centeredAt: CGPoint(x: 420, y: 150))               // x 370…470: 30% in
        let outside = try require(h.editor.selection)
        expectEqual(h.editor.holder(of: outside), nil)
        expectEqual(h.editor.document[outside]?.box, CGRect(x: 416, y: 100, width: 100, height: 100), "16 out from the edge")
    },
    test("a paste a read-only corral would take puts nothing down: the corral is refused (it shakes), and no step is left") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let log = RefusalLog()
        let h = try harness(pasteboard, [CorralsPlugin(), FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let box = h.add(Box(CGRect(x: 600, y: 0, width: 100, height: 100)))
        h.editor.freeze([pen])
        h.add(Disc(CGRect(x: 600, y: 400, width: 50, height: 50)))
        h.editor.undo()
        h.editor.copy([box])
        h.editor.selection = box
        let before = h.editor.document
        h.editor.paste(centeredAt: CGPoint(x: 200, y: 150))
        expectEqual(h.editor.document, before)
        expectEqual(log.refusals, [[pen]])
        expectEqual(h.editor.selectedShapeIDs, [box], "the selection as it was")
        expect(h.editor.canRedo, "no step opened: what there was to redo stays")
        h.editor.paste(centeredAt: CGPoint(x: 420, y: 150))               // mostly outside: nudged out, as ever
        let outside = try require(h.editor.selection)
        expectEqual(h.editor.document[outside]?.box, CGRect(x: 416, y: 100, width: 100, height: 100))
        expectEqual(log.refusals, [[pen]])
    },
    test("cut and paste moves a corral with what it holds: every id kept, each in its container again; undone, both steps, the board is as it was") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        let n = Nested(h)
        h.editor.replaceDocument(with: h.editor.document)
        let original = h.editor.document
        h.editor.selection = n.a
        expect(h.command("x"))
        expectEqual(h.editor.document.shapes, [], "what it held went with it")
        expect(h.command("v"))
        expectEqual(h.editor.document.shapes.map(\.id), n.ids)
        expectEqual(h.editor.document.shapes.map(\.copiedFrom), [nil, nil, nil, nil])
        expectEqual(n.ids.map { h.editor.holder(of: $0) }, [nil, n.a, n.a, n.c])
        expectEqual(h.editor.document.shapes.map(\.box), [Nested.a, Nested.b, Nested.c, Nested.d])
        h.editor.undo()
        expectEqual(h.editor.document.shapes, [])
        h.editor.undo()
        expectEqual(h.editor.document, original)
        expectEqual(h.editor.selectedShapeIDs, [n.a])
    },
    test("a cut takes what the corral holds that it copied; what it couldn't copy stays, let go of, and a read-only shape, copied, pastes back as a copy in it") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let log = RefusalLog()
        let h = try harness(pasteboard, [CorralsPlugin(), FreezingPlugin(log: log)])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let ticket = h.add(Ticket(frame: CGRect(x: 50, y: 50, width: 100, height: 100)))
        let frozen = h.add(Box(CGRect(x: 200, y: 50, width: 100, height: 100)))
        let free = h.add(Disc(CGRect(x: 350, y: 50, width: 100, height: 100)))
        h.editor.put([ticket, frozen, free], in: pen)
        h.editor.freeze([frozen])
        h.editor.cut([pen])
        expectEqual(h.editor.document.shapes.map(\.id), [ticket, frozen])
        expectEqual([h.editor.holder(of: ticket), h.editor.holder(of: frozen)], [nil, nil], "let go of, where they were")
        expectEqual(log.refusals, [[frozen]])
        let before = h.editor.document
        h.editor.paste()
        let pasted = h.editor.shapes(since: before)
        expectEqual(pasted.map(\.kind), [Corral.kind, Box.kind, Disc.kind])
        expectEqual([pasted[0].id, pasted[2].id], [pen, free], "moved")
        expectEqual(pasted[1].copiedFrom, frozen, "its id is in use: a copy")
        expectEqual(pasted.dropFirst().map { h.editor.holder(of: $0.id) }, [pen, pen])
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expectEqual(h.editor.holder(of: ticket), pen, "landing on it again, the corral takes back what stayed")
        expectEqual(h.editor.holder(of: frozen), nil, "but not a read-only shape")
    },
    test("a shape in a container on a pocket's board is copied in it, and pastes in its container's copy") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pocket = ShapeID(), pen = ShapeID(), box = ShapeID(), loose = ShapeID()
        var held = AnyShapeRecord(ShapeRecord(id: box, Box(CGRect(x: 10, y: 10, width: 50, height: 50))))
        held = held.copy(as: box, container: pen)
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pen, Corral(CGRect(x: 0, y: 0, width: 200, height: 200)))), held,
                                             AnyShapeRecord(ShapeRecord(id: loose, Disc(CGRect(x: 300, y: 0, width: 50, height: 50))))])
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                              children: [pocket: inside])
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                            FixturesPlugin(), KindsPlugin(), PocketsPlugin(), CorralsPlugin()], file: file)
        expectEqual(h.editor.contents(of: BoardID(owner: pocket)).container(of: box, containingKinds: h.editor.registry.containingKinds), pen)
        h.editor.copy([pocket])
        h.editor.paste()
        let copy = try require(h.editor.selection)
        let board = h.editor.contents(of: BoardID(owner: copy))
        let penCopy = try require(board.shapes.first { $0.copiedFrom == pen }), boxCopy = try require(board.shapes.first { $0.copiedFrom == box })
        expectEqual(board.container(of: boxCopy.id, containingKinds: h.editor.registry.containingKinds), penCopy.id)
        expectEqual(board.container(of: try require(board.shapes.first { $0.copiedFrom == loose }).id, containingKinds: h.editor.registry.containingKinds), nil)
    },
])
