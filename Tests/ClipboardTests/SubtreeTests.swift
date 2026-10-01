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

// Copying a shape that owns a board (CanvasTesting's pocket) copies what it holds, all the way
// down; pasting a copy gives every shape on every board a new id, and pasting a cut gives each back
// the id it had, if the file doesn't use it.

private func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }
private func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// Pocket P on the root, holding box B, pocket Q and a link from B to Q; Q holds disc D.
private struct Nest {
    let p = ShapeID(), b = ShapeID(), q = ShapeID(), link = ShapeID(), d = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(record(p, Pocket(slot(0)))),
                   children: [p: board(record(b, Box(slot(0))), record(q, Pocket(slot(1))), record(link, Link(from: b, to: q))),
                              q: board(record(d, Disc(slot(2))))])
    }
    var ids: Set<ShapeID> { [p, b, q, link, d] }
}

/// Keyboard, Selection, ContextMenus and Clipboard (on `pasteboard`), the CanvasTesting kinds, the
/// local ones and pockets, then `more`, on `file`.
@MainActor private func pockets(_ pasteboard: NSPasteboard, _ file: CanvasFile = CanvasFile(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                FixturesPlugin(), KindsPlugin(), PocketsPlugin()] + more, file: file)
}

/// A shape and what's under it, by kind: "pocket[box, pocket[disc], link]".
private func outline(_ record: AnyShapeRecord, in file: CanvasFile) -> String {
    let under = file[BoardID(owner: record.id)].shapes
    return record.kind.description + (under.isEmpty ? "" : "[" + under.map { outline($0, in: file) }.joined(separator: ", ") + "]")
}

/// The pasteboard's shapes, as JSON.
@MainActor private func payload(_ pasteboard: NSPasteboard) throws -> [String: Any] {
    let data = try require(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")))
    return try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Every shape id on every board of the file.
private func allIDs(_ file: CanvasFile) -> Set<ShapeID> {
    var ids = Set(file.root.shapes.map(\.id))
    for board in file.children.values { ids.formUnion(board.shapes.map(\.id)) }
    return ids
}

/// The kind "pocket", owning no board: what an app whose pockets hold nothing reads a copied pocket as.
private struct FlatPocket: BoxShapeProps {
    static let kind: ShapeKind = Pocket.kind
    static let properties = Properties<FlatPocket> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension FlatPocket {
    init() { self.init(frame: .zero) }
}

private struct FlatPocketDefinition {}

extension FlatPocketDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<FlatPocket>, in context: RenderContext) {}
}

@MainActor let subtreeTests = Suite("Copying what a shape holds", [
    test("copying a pocket puts what it holds on the pasteboard (format 4); a copy with nothing under it is written as before") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        expectEqual(h.editor.copy([nest.p]), [nest.p])
        let json = try payload(pasteboard)
        expectEqual(json["format"] as? Int, 4)
        let boards = try require(json["boards"] as? [String: Any])
        expectEqual(Set(boards.keys), [nest.p.description, nest.q.description])
        let empty = h.add(Pocket(slot(3)))
        expectEqual(h.editor.copy([empty]), [empty])
        let flat = try payload(pasteboard)
        expect((flat["format"] as? Int ?? 99) < 4)
        expect(flat["boards"] == nil)
    },
    test("a paste gives every shape on every board a new id, each board going under its owner's copy, each copy naming its original") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        h.editor.selection = nest.p
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let pocket = try require(h.editor.shapes(since: before).first)
        expectEqual(h.editor.shapes(since: before).count, 1)
        expectEqual(h.editor.selectedShapeIDs, [pocket.id])
        expectEqual(pocket.copiedFrom, nest.p)
        expectEqual(outline(pocket, in: h.file), "pocket[box, pocket[disc], link]")
        let held = h.file[BoardID(owner: pocket.id)].shapes
        expectEqual(held.map(\.copiedFrom), [nest.b, nest.q, nest.link])
        expectEqual(h.file[BoardID(owner: held[1].id)].shapes.map(\.copiedFrom), [nest.d])
        expect(allIDs(h.file).subtracting(nest.ids).count == 5, "five new ids")
        expectEqual(h.file[BoardID(owner: nest.p)].shapes.map(\.id), [nest.b, nest.q, nest.link], "the original is untouched")
        expectEqual(h.file.path(to: BoardID(owner: held[1].id)), [.root, BoardID(owner: pocket.id), BoardID(owner: held[1].id)])
    },
    test("a link inside names the copies of the shapes it named") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        h.editor.copy([nest.p])
        h.editor.paste()
        let pocket = try require(h.editor.selection)
        let held = h.file[BoardID(owner: pocket)].shapes
        expectEqual(held[2].typed(as: Link.self)?.props, Link(from: held[0].id, to: held[1].id))
    },
    test("names across the tree name the copies: a name of a shape pasted with it, on any board, is renamed, a name of anything else kept; bindings stay on their board") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest(), memo = ShapeID(), inside = ShapeID(), tag = ShapeID(), outside = ShapeID()
        var file = nest.file
        // A memo on the root naming D, two boards down, and a box that isn't copied; in P, a citing
        // tag bound to B and citing P, its board's owner, and a memo naming the root's memo.
        let root = CanvasDocument(shapes: file.root.shapes + [
            record(memo, Memo(slot(4), lead: Citation(nest.d), sources: ["out": Citation(outside)])),
            record(outside, Box(slot(5))),
        ])
        let inP = CanvasDocument(shapes: file[BoardID(owner: nest.p)].shapes + [
            record(tag, CitingTag(target: nest.b, cite: Citation(nest.p))),
            record(inside, Memo(slot(3), lead: Citation(memo))),
        ])
        file = CanvasFile(root: root, children: [nest.p: inP, nest.q: file[BoardID(owner: nest.q)]])
        let h = try pockets(pasteboard, file, [NamingPlugin()])
        h.editor.copy([nest.p, memo])
        let before = h.editor.document
        h.editor.paste()
        let pasted = h.editor.shapes(since: before)
        let pocket = try require(pasted.first { $0.copiedFrom == nest.p }), memoCopy = try require(pasted.first { $0.copiedFrom == memo })
        let held = h.file[BoardID(owner: pocket.id)].shapes
        let q = try require(held.first { $0.copiedFrom == nest.q }), b = try require(held.first { $0.copiedFrom == nest.b })
        let d = try require(h.file[BoardID(owner: q.id)].shapes.first)
        expectEqual(memoCopy.typed(as: Memo.self)?.props.lead, Citation(d.id), "D's copy, two boards down")
        expectEqual(memoCopy.typed(as: Memo.self)?.props.sources, ["out": Citation(outside)], "a shape not copied is still named")
        let tagCopy = try require(held.first { $0.copiedFrom == tag }?.typed(as: CitingTag.self)?.props)
        expectEqual(tagCopy, CitingTag(target: b.id, cite: Citation(pocket.id)), "bound to B's copy, on its board; citing P's copy, the board's owner")
        expectEqual(held.first { $0.copiedFrom == inside }?.typed(as: Memo.self)?.props.lead, Citation(memoCopy.id), "the root's memo's copy, a board up")
        expectEqual(h.file[BoardID(owner: nest.p)], inP, "the originals name what they named")
    },
    test("⌘X takes the pocket and the boards under it in one transaction; ⌘V brings the tree back, every id as it was, no copy") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        h.editor.selection = nest.p
        let revision = h.editor.revision
        expect(h.command("x"))
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.file, CanvasFile())
        expect(h.command("v"))
        let pocket = try require(h.editor.document.shapes.first)
        expectEqual(pocket.id, nest.p)
        expectEqual(outline(pocket, in: h.file), "pocket[box, pocket[disc], link]")
        expectEqual(allIDs(h.file), nest.ids)
        expectEqual(h.file.path(to: BoardID(owner: nest.q)), [.root, BoardID(owner: nest.p), BoardID(owner: nest.q)])
        let held = h.file[BoardID(owner: nest.p)].shapes
        expectEqual(held.last?.typed(as: Link.self)?.props, Link(from: nest.b, to: nest.q), "still bound to B and Q")
        expect((held + [pocket] + h.file[BoardID(owner: nest.q)].shapes).allSatisfy { $0.copiedFrom == nil })
    },
    test("⌘Z after ⌘X brings the pocket back with every board under it, every id, selected; after ⌘V, it takes the pasted boards out") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        let original = h.file
        h.editor.selection = nest.p
        expect(h.command("x"))
        expectEqual(h.editor.undoHistory.undoName, "Cut")
        expect(h.command("z"))
        expectEqual(h.file, original, "every board, every id")
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
        h.editor.redo()
        expectEqual(h.file, CanvasFile())

        expect(h.command("v"))
        expectEqual(h.editor.undoHistory.undoName, "Paste")
        let pasted = h.file
        expectEqual(allIDs(pasted), nest.ids, "moved back")
        let pocket = try require(h.editor.selection)
        expect(h.command("z"))
        expectEqual(h.file, CanvasFile(), "no board left behind without its owner")
        h.editor.redo()
        expectEqual(h.file, pasted, "the same ids, on every board")
        expectEqual(h.editor.selectedShapeIDs, [pocket])
        expectEqual(outline(try require(h.file.record(pocket)), in: h.file), "pocket[box, pocket[disc], link]")
    },
    test("cut keeps a pocket holding a shape that can't be copied, anywhere under it, and copies the rest; a shape copied whole beside it goes, and pastes back as itself, the pocket as a copy") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest(), box = ShapeID()
        var children = nest.file.children
        children[nest.q] = board(record(nest.d, Disc(slot(2))), record(ShapeID(), Ticket(frame: slot(3))))
        let file = CanvasFile(root: board(record(nest.p, Pocket(slot(0))), record(box, Box(slot(1)))), children: children)
        let h = try pockets(pasteboard, file)
        h.editor.selectedShapeIDs = file.root.shapes.map(\.id)
        h.editor.cutSelection()
        expectEqual(h.editor.document.shapes.map(\.id), [nest.p])
        expectEqual(h.file.children, file.children, "everything under the pocket stays")
        let before = h.editor.document
        h.editor.paste()
        let pasted = h.editor.shapes(since: before)
        expectEqual(pasted.map { outline($0, in: h.file) }, ["pocket[box, pocket[disc], link]", "box"])
        expectEqual(pasted.map(\.copiedFrom), [nest.p, nil])
        expectEqual(pasted.last?.id, box, "moved back")
        let held = h.file[BoardID(owner: pasted[0].id)].shapes
        expectEqual(held.map(\.copiedFrom), [nest.b, nest.q, nest.link], "under the copy, copies all the way down: every id is in use")
        expectEqual(held[2].typed(as: Link.self)?.props, Link(from: held[0].id, to: held[1].id))
    },
    test("a shape on a board that's left out of a copy takes the boards under it, and its owner isn't cut") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let q = nest.q
        let h = try pockets(pasteboard, nest.file, [Contributor(id: "sealed") { $0.contribute({ $0.id != q }, to: ShapeCopyability.self, for: .kind(Pocket.kind)) }])
        h.editor.cut([nest.p])
        expectEqual(h.file, nest.file)
        let json = try payload(pasteboard)
        expectEqual(Set(try require(json["boards"] as? [String: Any]).keys), [nest.p.description])
        h.editor.paste()
        let pocket = try require(h.editor.document.shapes.last)
        expectEqual(outline(pocket, in: h.file), "pocket[box, link]")
        expectEqual(h.file[BoardID(owner: pocket.id)].shapes.last?.typed(as: Link.self)?.props.to, nil, "the link lets go of Q")
    },
    test("pasting a pocket into its own board makes a new tree there") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        h.editor.copy([nest.p])
        expect(h.enter(nest.p))
        h.editor.paste()
        let pocket = try require(h.editor.selection)
        expectEqual(h.file.board(containing: pocket), BoardID(owner: nest.p))
        expectEqual(outline(try require(h.file.record(pocket)), in: h.file), "pocket[box, pocket[disc], link]")
        expectEqual(h.file.path(to: BoardID(owner: pocket)), [.root, BoardID(owner: nest.p), BoardID(owner: pocket)])
        expectEqual(h.file.shapeCount, 10)
    },
    test("another editor on the pasteboard pastes the whole tree") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let source = try pockets(pasteboard, nest.file)
        let target = try pockets(pasteboard)
        source.editor.copy([nest.p])
        target.editor.paste()
        let pocket = try require(target.editor.document.shapes.first)
        expectEqual(outline(pocket, in: target.file), "pocket[box, pocket[disc], link]")
    },
    test("an app without pockets pastes the rest, and no boards; on a board, a kind this app can't read is left out, with what can't do without it") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let card = ShapeID()
        var children = nest.file.children
        children[nest.p] = board(record(card, Card(slot(0))), record(ShapeID(), Tether(to: card)), record(nest.b, Box(slot(1))))
        let file = CanvasFile(root: board(record(nest.p, Pocket(slot(0))), record(ShapeID(), Box(slot(1)))), children: children)
        let source = try pockets(pasteboard, file, [CardsPlugin()])
        source.editor.copy(file.root.shapes.map(\.id))
        let bare = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                               FixturesPlugin(), KindsPlugin()])
        bare.editor.paste()
        expectEqual(bare.editor.document.shapes.map(\.kind), [Box.kind])
        expectEqual(bare.file.children, [:])
        let target = try pockets(pasteboard)
        target.editor.paste()
        let pocket = try require(target.editor.document.shapes.first)
        expectEqual(outline(pocket, in: target.file), "pocket[box]")
        source.editor.copy([nest.p])
        expect(!bare.editor.canPaste, "the pocket alone: nothing to paste")
    },
    test("in an app whose pockets own no board, a pasted pocket gets none") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let source = try pockets(pasteboard, nest.file)
        source.editor.copy([nest.p])
        let flat = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                               FixturesPlugin(), KindsPlugin(),
                                               Contributor(id: "flat-pockets") { $0.shape(FlatPocketDefinition()) }])
        flat.editor.paste()
        expectEqual(flat.editor.document.shapes.map(\.kind), [Pocket.kind])
        expectEqual(flat.file.children, [:])
    },
    test("a payload in a newer format (6) is nothing to paste: ⌘V passes the key on") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let nest = Nest()
        let h = try pockets(pasteboard, nest.file)
        h.editor.copy([nest.p])
        let type = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.shapes")
        let json = try require(pasteboard.data(forType: type).flatMap { String(data: $0, encoding: .utf8) })
        expect(json.contains(#""format" : 4"#))
        pasteboard.clearContents()
        pasteboard.setData(Data(json.replacingOccurrences(of: #""format" : 4"#, with: #""format" : 6"#).utf8), forType: type)
        expect(!h.editor.canPaste)
        expect(!h.command("v"))
        expectEqual(h.file, nest.file)
    },
])
