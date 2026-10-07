import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Publishing
import References
import SwiftUI
import TableOfContents
import TestKit
import Titles

// The reference's row in the table of contents: what it stands for, under the symbol of its kind and
// in its tint, with the list's stand-in arrow; what stands for nothing is the stored text, dimmed; a
// change to the shape it names, on any board, remakes its row and no other, and a move remakes none.

@MainActor private func row(_ h: EditorHarness, _ id: ShapeID) throws -> ContentsEntry {
    try require(try require(h.editor.tableOfContents).entries.first { $0.id == id }, "a row for the reference")
}

@MainActor private func text(_ h: EditorHarness, _ id: ShapeID) throws -> String {
    try require(try row(h, id).label).text
}

@MainActor let rowTests = Suite("The reference's row in the table of contents", [
    test("what it stands for under the symbol of its kind, in its tint, with a stand-in's arrow; the stored text dimmed where it stands for nothing") {
        let h = try referenceHarness()
        let live = h.addReference(to: h.addBox("shapes"), label: "shapes")
        let label = try require(try row(h, live).label)
        expectEqual(label.text, "shapes")
        expectEqual(label.systemImage, "shippingbox")
        expect(!label.isPlaceholder)
        expect(label.color != nil, "in the kind's tint")
        expect(label.standsIn, "a pointer to the shape, not the shape")
        let gone = h.addReference(to: ShapeID(), label: "Old roadmap", at: CGPoint(x: 400, y: 400))
        let missing = try require(try row(h, gone).label)
        expectEqual(missing.text, "Old roadmap")
        expect(missing.isPlaceholder, "dimmed")
        expectEqual(missing.systemImage, "square.dashed")
        expect(!missing.standsIn, "no shape's symbol to mark")
        let hidden = h.addBox("Secret", public: false, at: CGRect(x: 100, y: 400, width: 100, height: 100))
        let notPublic = try require(try row(h, h.addReference(to: hidden, label: "Secret", at: CGPoint(x: 400, y: 500))).label)
        expectEqual(notPublic.text, "Secret")
        expect(notPublic.isPlaceholder, "not public: dimmed")
        expect(notPublic.standsIn, "still under the shape's symbol")
        let words = try require(try row(h, h.addReference(words: "blocked work", at: CGPoint(x: 400, y: 600))).label)
        expectEqual(words.text, "blocked work")
        expectEqual(words.systemImage, "magnifyingglass")
        expect(words.isPlaceholder, "not interpreted: stands for nothing")
        expect(!words.standsIn, "the magnifier says it")
        let query = try require(try row(h, h.addReference(words: "payment notes", query: "box", at: CGPoint(x: 400, y: 650))).label)
        expect(!query.isPlaceholder, "asking, not nothing")
        expect(!query.standsIn)
        let empty = try require(try row(h, h.addEmptyReference(at: CGPoint(x: 600, y: 650))).label)
        expectEqual(empty.text, "Reference")
        expect(empty.isPlaceholder)
        expect(!empty.standsIn)
    },
    test("a rename, a change of publicness and a deletion of the shape it names remake its row, and no other, as they happen") {
        let h = try referenceHarness()
        let box = h.addBox("shapes"), other = h.addBox("other", at: CGRect(x: 100, y: 400, width: 100, height: 100))
        let id = h.addReference(to: box, label: "shapes")
        let aside = h.addReference(to: other, label: "other", at: CGPoint(x: 400, y: 400))
        _ = try require(h.editor.tableOfContents).entries
        let contents = try require(h.editor.tableOfContents)
        let made = contents.rowsMade
        h.editor.transact { $0.update(box) { $0[TitleProperty.self] = "things" } }
        expectEqual(try text(h, id), "things")
        expectEqual(contents.rowsMade - made, 1, "the reference to it, and not the other reference")
        expectEqual(try text(h, aside), "other")
        h.editor.transact { $0.update(box) { $0[PublicProperty.self] = nil } }
        expect(try require(try row(h, id).label).isPlaceholder, "no longer public: dimmed")
        expect(try require(try row(h, id).label).standsIn, "with its arrow")
        h.editor.undo()
        expect(!(try require(try row(h, id).label).isPlaceholder), "undone")
        h.editor.transact { $0.delete([box]) }
        expectEqual(try require(try row(h, id).label).systemImage, "square.dashed", "deleted")
        expect(!(try require(try row(h, id).label).standsIn), "and no arrow")
        expectEqual(try text(h, id), "shapes", "the name it was picked as")
        h.editor.undo()
        expectEqual(try text(h, id), "things")
    },
    test("a move of the shape it names remakes nothing: a drag costs the list no row") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        let contents = try require(h.editor.tableOfContents)
        _ = contents.entries
        let made = contents.rowsMade
        h.editor.transact { $0.moveBox(box, to: CGPoint(x: 300, y: 300)) }
        h.editor.transact { $0.moveBox(id, to: CGPoint(x: 500, y: 500)) }
        _ = contents.entries
        expectEqual(contents.rowsMade, made, "no row was made")
    },
    test("across boards: what it names is renamed on another board, which isn't shown, and its row says so when the commit comes back") {
        let pocketNames = Contributor(id: "pocket-titles") { $0.title(Pocket.self, pill: false, contents: false) }
        let h = try referenceHarness([PocketsPlugin(), pocketNames])
        let pocket = h.add(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
        expect(h.enter(pocket))
        let box = h.addBox("inside")
        expect(h.editor.showBoard(.root))
        let id = h.addReference(to: box, label: "inside")
        expectEqual(try text(h, id), "inside")
        h.editor.transact(on: BoardID(owner: pocket)) { $0.update(box) { $0[TitleProperty.self] = "renamed" } }
        expectEqual(try text(h, id), "renamed", "a write to a board that isn't shown remakes the row")
        h.editor.transact(on: BoardID(owner: pocket)) { $0.delete([box]) }
        expectEqual(try require(try row(h, id).label).systemImage, "square.dashed")
    },
])
