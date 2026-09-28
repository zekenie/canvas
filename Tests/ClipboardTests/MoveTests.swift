import AppKit
import Canvas
import CanvasTesting
import Clipboard
import ContextMenus
import CoreGraphics
import Foundation
import Keyboard
import Selection
import TestKit

// Cutting and pasting is a move: a paste of what a cut took gives each shape back the id it had, if
// nothing in the file goes by it, so whatever names the shape names it again. Everything else a
// paste puts down is a copy.

private func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }

/// The plugins `harness` has, with pockets and the naming kinds.
@MainActor private func plugins(_ pasteboard: NSPasteboard) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
     FixturesPlugin(), KindsPlugin(), PocketsPlugin(), NamingPlugin()]
}

private let cutType = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.cut")
private let shapesType = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")

@MainActor let moveTests = Suite("Cutting and pasting is a move", [
    test("a cut marks the pasteboard as a cut's, beside the shapes; a copy doesn't") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0))), disc = h.add(Disc(slot(1)))
        h.editor.copy([box])
        expectEqual(pasteboard.types, [shapesType])
        h.editor.cut([disc])
        expectEqual(pasteboard.types, [shapesType, cutType])
        let first = pasteboard.string(forType: cutType)
        h.editor.undo()
        h.editor.cut([disc])
        expect(pasteboard.string(forType: cutType) != first, "each cut's mark is its own")
        h.editor.copy([box])
        expectEqual(pasteboard.types, [shapesType])
    },
    test("⌘C, Delete, ⌘V pastes a copy: only a cut moves") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        expect(h.command("c"))
        h.editor.perform(.delete)
        expectEqual(h.editor.document.shapes, [])
        expect(h.command("v"))
        let copy = try require(h.editor.document.shapes.first)
        expect(copy.id != box)
        expectEqual(copy.copiedFrom, box)
    },
    test("once anything writes over a cut, what's on the pasteboard pastes as copies: a copy of shapes this file doesn't have, or the cut's shapes written again without its mark") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard), other = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        let elsewhere = other.add(Disc(slot(1)))
        h.editor.cut([box])
        other.editor.copy([elsewhere])
        h.editor.paste()
        let copy = try require(h.editor.document.shapes.first)
        expect(copy.id != elsewhere)
        expectEqual(copy.copiedFrom, elsewhere, "a copy, though no shape here has its id")

        let disc = h.add(Disc(slot(2)))
        h.editor.cut([disc])
        let data = try require(pasteboard.data(forType: shapesType))
        pasteboard.clearContents()
        pasteboard.setData(data, forType: shapesType)          // an app that doesn't know the mark
        let before = h.editor.document
        h.editor.paste()
        let again = try require(h.editor.shapes(since: before).first)
        expect(again.id != disc)
        expectEqual(again.copiedFrom, disc)
    },
    test("the cut undone, a paste is copies: the shapes it took are back, with their ids") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.selection = box
        expect(h.command("x"))
        h.editor.undo()
        expectEqual(h.editor.document.shapes.map(\.id), [box])
        let before = h.editor.document
        expect(h.command("v"))
        expectEqual(h.editor.shapes(since: before).map(\.copiedFrom), [box])
    },
    test("cut in one editor and pasted in another on the pasteboard, the shapes keep their ids there; pasted again there, copies") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let source = try harness(pasteboard), target = try harness(pasteboard)
        let box = source.add(Box(slot(0))), disc = source.add(Disc(slot(1)))
        source.editor.cut([box, disc])
        target.editor.paste()
        expectEqual(target.editor.document.shapes.map(\.id), [box, disc])
        expectEqual(target.editor.document.shapes.map(\.copiedFrom), [nil, nil])
        let before = target.editor.document
        target.editor.paste()
        expectEqual(target.editor.shapes(since: before).map(\.copiedFrom), [box, disc])
    },
    test("pasted into a file that uses one of the ids, that shape is a copy and the rest keep theirs; a link and a memo name each as pasted, and the rest as they did") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let source = try EditorHarness(plugins: plugins(pasteboard))
        let a = source.add(Box(slot(0))), b = source.add(Box(slot(1))), outside = source.add(Box(slot(3)))
        let link = source.add(Link(from: a, to: b))
        let memo = source.add(Memo(slot(2), lead: Citation(a), sources: ["b": Citation(b), "out": Citation(outside)]))
        source.editor.cut([a, b, link, memo])
        let target = try EditorHarness(plugins: plugins(pasteboard), file: CanvasFile(root: CanvasDocument(shapes: [record(a, Disc(slot(4)))])))
        let before = target.editor.document
        target.editor.paste()
        let pasted = target.editor.shapes(since: before)
        expectEqual(pasted.map(\.id).dropFirst(), [b, link, memo])
        let copy = try require(pasted.first)
        expect(copy.id != a)
        expectEqual(copy.copiedFrom, a)
        expectEqual(pasted.dropFirst().map(\.copiedFrom), [nil, nil, nil])
        expectEqual(target.editor.document[a]?.kind, Disc.kind, "the file's own shape, as it was")
        expectEqual(target.editor.document[link]?.typed(as: Link.self)?.props, Link(from: copy.id, to: b))
        let pastedMemo = try require(target.editor.document[memo]?.typed(as: Memo.self)?.props)
        expectEqual(pastedMemo.lead, Citation(copy.id))
        expectEqual(pastedMemo.sources, ["b": Citation(b), "out": Citation(outside)])
    },
    test("an id something is kept under (a board whose owner isn't in the file, an entry that isn't a board) isn't given back: that shape pastes as a copy, and what it holds keeps theirs") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pocket = ShapeID(), inside = ShapeID(), box = ShapeID()
        let source = try EditorHarness(plugins: plugins(pasteboard),
                                       file: CanvasFile(root: CanvasDocument(shapes: [record(pocket, Pocket(slot(0))), record(box, Box(slot(1)))]),
                                                        children: [pocket: CanvasDocument(shapes: [record(inside, Box(slot(0)))])]))
        source.editor.cut([pocket, box])
        expectEqual(source.file, CanvasFile())

        // Boards kept under both ids, with no owner.
        let orphans: [ShapeID: CanvasDocument] = [pocket: CanvasDocument(shapes: [record(ShapeID(), Disc(slot(2)))]),
                                                  box: CanvasDocument(shapes: [record(ShapeID(), Disc(slot(3)))])]
        let kept = try EditorHarness(plugins: plugins(pasteboard), file: CanvasFile(children: orphans))
        kept.editor.paste()
        let pasted = kept.editor.document.shapes
        expectEqual(pasted.map(\.copiedFrom), [pocket, box])
        expect(pasted.allSatisfy { $0.id != pocket && $0.id != box })
        expectEqual(kept.file[BoardID(owner: pasted[0].id)].shapes.map(\.id), [inside], "unused here, so kept")
        expectEqual(kept.file[BoardID(owner: pasted[1].id)], CanvasDocument(), "a box's copy takes no board")
        expectEqual(kept.file.children[pocket], orphans[pocket])
        expectEqual(kept.file.children[box], orphans[box])

        // Entries that aren't boards, under both ids.
        let json = #"{ "format" : 4, "shapes" : [], "boards" : { "\#(pocket)" : 7, "\#(box)" : 7 } }"#
        let loaded = try BoardCodec(registry: Registry(plugins: plugins(pasteboard))).decode(Data(json.utf8))
        let unread = try EditorHarness(plugins: plugins(pasteboard), file: loaded.file)
        unread.editor.paste()
        expectEqual(unread.editor.document.shapes.map(\.copiedFrom), [pocket, box])
        expectEqual(unread.file.unreadableBoards, loaded.file.unreadableBoards, "kept as they were")
    },
    test("a copy cut and pasted keeps the CopiedFrom it had: it's the same copy, moved") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.copy([box])
        h.editor.paste()
        let copy = try require(h.editor.selection)
        h.editor.cut([copy])
        h.editor.paste()
        expectEqual(h.editor.selection, copy)
        expectEqual(h.editor.document[copy]?.copiedFrom, box)
    },
    test("a cut whose deletion was refused (a frozen shape) pastes that shape as a copy; what it deleted moves") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [FreezingPlugin()])
        let frozen = h.add(Box(slot(0))), free = h.add(Disc(slot(1)))
        h.editor.freeze([frozen])
        h.editor.cut([frozen, free])
        expectEqual(h.editor.document.shapes.map(\.id), [frozen])
        let before = h.editor.document
        h.editor.paste()
        let pasted = h.editor.shapes(since: before)
        expectEqual(pasted.map(\.copiedFrom), [frozen, nil])
        expectEqual(pasted.last?.id, free)
    },
    test("pasted, deleted and pasted again, what a cut took moves again: nothing in the file goes by its ids") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.editor.cut([box])
        h.editor.paste()
        h.editor.perform(.delete)
        expectEqual(h.editor.document.shapes, [])
        h.editor.paste()
        expectEqual(h.editor.document.shapes.map(\.id), [box])
        expectEqual(h.editor.document.shapes.map(\.copiedFrom), [nil])
    },
    test("a name of a cut shape, left behind, names it again once it's pasted, on another board; a binding to it was let go of at the cut") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let pocket = ShapeID(), box = ShapeID(), memo = ShapeID(), tag = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [record(pocket, Pocket(slot(0))), record(box, Box(slot(1))),
                                                            record(memo, Memo(slot(2), lead: Citation(box))),
                                                            record(tag, CitingTag(target: box, cite: Citation(box)))]))
        let h = try EditorHarness(plugins: plugins(pasteboard), file: file)
        h.editor.cut([box])
        expectEqual(h.file.record(tag)?.typed(as: CitingTag.self)?.props, CitingTag(target: nil, cite: Citation(box)))
        expect(h.enter(pocket))
        h.editor.paste()
        expectEqual(h.file.board(containing: box), BoardID(owner: pocket))
        expectEqual(h.file.record(memo)?.typed(as: Memo.self)?.props.lead, Citation(box), "the memo names it where it is now")
        expectEqual(h.file.record(tag)?.typed(as: CitingTag.self)?.props, CitingTag(target: nil, cite: Citation(box)))
    },
])
