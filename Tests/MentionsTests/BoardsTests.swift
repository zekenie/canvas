import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Mentions
import Selection
import TableOfContents
import TestKit
import Titles

// Mentions in a file of several boards, with CanvasTesting's pockets: a mention names a shape
// anywhere in the file, and shows it as it's called now, on the canvas, in the rows and in the
// state; a double-click on its pill shows its board first; a board deleted with its owner takes
// its shapes' names with it until undo brings them back. The index and the picker are the board
// shown's.

/// A file whose root holds a pocket, holding plate "Groceries" on its board, and a jot at (20, 20)
/// whose text mentions the plate (by the name "Old name") and token "Milk", on the root, far off;
/// and on the pocket's board, a jot mentioning the token. The view is 800 × 600 at zoom 1.
@MainActor private final class PocketBoard {
    let h: EditorHarness
    let pocket = ShapeID(), groceries = ShapeID(), milk = ShapeID(), jot = ShapeID(), inner = ShapeID()
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }
    var pocketBoard: BoardID { BoardID(owner: pocket) }

    /// `holdsGroceries` false leaves the plate out of the file.
    init(holdsGroceries: Bool = true, groceriesOnRoot: Bool = false) throws {
        var plate = ShapeRecord(id: groceries, Plate(CGRect(x: 1000, y: 1000, width: 120, height: 80)))
        plate[TitleProperty.self] = "Groceries"
        let text = mentioning([.text("Ask "), .mention(groceries, label: "Old name"), .text(" and "), .mention(milk, label: "Milk")])
        var root: [AnyShapeRecord] = [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 1200, y: 1200, width: 100, height: 100)))),
                                      AnyShapeRecord(ShapeRecord(id: jot, Jot(CGRect(x: 20, y: 20, width: 200, height: 200), text: text))),
                                      AnyShapeRecord(ShapeRecord(id: milk, Token(CGRect(x: 1400, y: 1000, width: 60, height: 60), caption: "Milk")))]
        var inside: [AnyShapeRecord] = [AnyShapeRecord(ShapeRecord(id: inner, Jot(CGRect(x: 20, y: 20, width: 200, height: 200),
                                                                                   text: mentioning([.mention(milk, label: "Milk")]))))]
        if holdsGroceries {
            if groceriesOnRoot { root.append(AnyShapeRecord(plate)) } else { inside.append(AnyShapeRecord(plate)) }
        }
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                              file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: inside)]))
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    }

    /// The jot's row in the table of contents, as it reads now.
    func row(_ id: ShapeID) -> String? { editor.tableOfContents?.entries.first { $0.id == id }?.label?.text }

    /// What a mention of the plate shows now.
    var groceriesLabel: String? { state.resolve(groceries).appearance?.label }

    func picture() -> NSBitmapImageRep { renderBitmap(editor, size: CGSize(width: 240, height: 240), scale: 2) }
}

@MainActor let boardsTests = Suite("Across boards", [
    test("a mention of a shape on another board of the file shows it live, as it's called now: resolved, in the row, the pills and the picture") {
        let b = try PocketBoard()
        expectEqual(b.groceriesLabel, "Groceries")
        expectEqual(b.state.mentions(in: b.jot), [b.groceries, b.milk])
        expectEqual(b.row(b.jot), "Ask @Groceries and @Milk")
        expectEqual(b.editor.mentionPills(of: b.jot).map(\.isLive), [true, true])
        let picture = b.picture()
        expectEqual(largestDifference(picture, try PocketBoard(groceriesOnRoot: true).picture(), in: CGRect(x: 0, y: 0, width: 240, height: 240)), 0,
                    "drawn as a mention of a shape on the board shown is")
        let missing = try PocketBoard(holdsGroceries: false)
        expectEqual(missing.editor.mentionPills(of: missing.jot).map(\.isLive), [false, true])
        expect(changedPixels(picture, missing.picture(), in: CGRect(x: 0, y: 0, width: 240, height: 240)) > 0, "not as a missing one")

        // And from inside the pocket, a mention of a shape on the root.
        expect(b.editor.showBoard(b.pocketBoard))
        expectEqual(b.state.mentions(in: b.inner), [b.milk])
        expectEqual(b.state.resolve(b.milk).appearance?.label, "Milk")
        expectEqual(b.editor.mentionPills(of: b.inner).map(\.isLive), [true])
        expectEqual(b.row(b.inner), "@Milk")
    },

    test("a rename on the target's board shows on going back to the mention's; a write to the target's board from elsewhere shows at once; and so do their undo") {
        let b = try PocketBoard()
        var heard: [Set<ShapeID>] = []
        let observation = b.state.observe([b.groceries]) { heard.append($0) }
        defer { observation.cancel() }
        let revision = b.state.labelRevision(of: b.groceries)
        expectEqual(b.row(b.jot), "Ask @Groceries and @Milk")

        expect(b.editor.showBoard(b.pocketBoard))
        b.editor.rename(b.groceries, "Errands")
        expect(b.editor.showBoard(.root))
        expectEqual(b.groceriesLabel, "Errands")
        expectEqual(b.row(b.jot), "Ask @Errands and @Milk", "the row taken back is made again")
        let renamed = b.state.labelRevision(of: b.groceries)
        expect(renamed > revision, "its revision is bumped")
        expectEqual(heard.last, [b.groceries], "its observers are told")
        expectEqual(b.editor.mentionPills(of: b.jot).map(\.isLive), [true, true])

        // Undone from the root: its board is shown, and on going back the name is as it was.
        b.editor.undo()
        expectEqual(b.editor.board, b.pocketBoard)
        expect(b.editor.showBoard(.root))
        expectEqual(b.groceriesLabel, "Groceries")
        expectEqual(b.row(b.jot), "Ask @Groceries and @Milk")
        expect(b.state.labelRevision(of: b.groceries) > renamed)

        // Written while the root is shown: at once.
        heard = []
        b.editor.transact(on: b.pocketBoard, "Rename") { $0.update(b.groceries) { $0[TitleProperty.self] = "Chores" } }
        expectEqual(b.editor.board, .root)
        expectEqual(b.groceriesLabel, "Chores")
        expectEqual(b.row(b.jot), "Ask @Chores and @Milk")
        expectEqual(heard, [[b.groceries]])
        b.editor.undo()
        expect(b.editor.showBoard(.root))
        expectEqual(b.row(b.jot), "Ask @Groceries and @Milk")
    },

    test("deleting the pocket that holds it shows it missing, by the name the text holds; undo brings it back live, and redo missing again") {
        let b = try PocketBoard()
        var heard: [Set<ShapeID>] = []
        let observation = b.state.observe([b.groceries]) { heard.append($0) }
        defer { observation.cancel() }
        expectEqual(b.row(b.jot), "Ask @Groceries and @Milk")
        b.editor.delete(b.pocket)
        expectEqual(b.state.resolve(b.groceries), .missing)
        expectEqual(b.row(b.jot), "Ask @Old name and @Milk")
        expectEqual(b.editor.mentionPills(of: b.jot).map(\.isLive), [false, true])
        expectEqual(heard, [[b.groceries]])
        b.editor.undo()
        expectEqual(b.groceriesLabel, "Groceries")
        expectEqual(b.row(b.jot), "Ask @Groceries and @Milk")
        expectEqual(b.editor.mentionPills(of: b.jot).map(\.isLive), [true, true])
        b.editor.redo()
        expectEqual(b.state.resolve(b.groceries), .missing)
        expectEqual(b.row(b.jot), "Ask @Old name and @Milk")
        expectEqual(heard.count, 3)
    },

    test("a double-click on a pill naming a shape on another board shows that board and selects it there, one step back; the pointer on it hovers the jot") {
        let b = try PocketBoard()
        let pill = try require(b.editor.mentionPills(of: b.jot).first)
        let onPill = b.h.view(CGPoint(x: pill.frame.midX, y: pill.frame.midY))
        b.h.move(to: onPill)
        expectEqual(b.editor.hovered, b.jot, "nothing on the board shown to outline")
        b.h.click(at: onPill, clickCount: 2)
        expectEqual(b.editor.board, b.pocketBoard)
        expectEqual(b.editor.selection, b.groceries)
        let shown = b.editor.cameraTarget.toWorld(CGRect(origin: .zero, size: b.editor.viewportSize))
        expect(shown.contains(CGRect(x: 1000, y: 1000, width: 120, height: 80)), "brought into view: \(shown)")
        b.editor.goBack()
        expectEqual(b.editor.board, .root, "Back returns to the board left")
        expectEqual(b.editor.selection, b.jot, "with what was selected there: the jot the press selected")

        // Following it from the text, as a double-click on the pill there does.
        b.state.follow(b.groceries)
        b.h.wait(10)
        expectEqual(b.editor.board, b.pocketBoard)
        expectEqual(b.editor.selection, b.groceries)
    },

    test("a mention of a shape on a board the app can't show (its owner not in the file, or of a kind that owns none) is unavailable: not live, not followed, drawn as missing") {
        let hidden = ShapeID(), held = ShapeID(), token = ShapeID(), jot = ShapeID(), orphanBoard = ShapeID()
        @MainActor func plate(_ id: ShapeID, _ title: String) -> AnyShapeRecord {
            var plate = ShapeRecord(id: id, Plate(CGRect(x: 0, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = title
            return AnyShapeRecord(plate)
        }
        let text = mentioning([.mention(hidden, label: "Old"), .text(" "), .mention(held, label: "Older")])
        let root = [AnyShapeRecord(ShapeRecord(id: jot, Jot(CGRect(x: 20, y: 20, width: 200, height: 200), text: text))),
                    AnyShapeRecord(ShapeRecord(id: token, Token(CGRect(x: 1400, y: 1000, width: 60, height: 60), caption: "Keeper")))]
        @MainActor func harness(holding: Bool) throws -> EditorHarness {
            let children = holding ? [orphanBoard: CanvasDocument(shapes: [plate(hidden, "Hidden")]), token: CanvasDocument(shapes: [plate(held, "Held")])] : [:]
            let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]), file: CanvasFile(root: CanvasDocument(shapes: root), children: children))
            h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
            return h
        }
        let h = try harness(holding: true)
        let state = h.editor.mentionState
        expect(h.editor.file.record(hidden) != nil && h.editor.file.record(held) != nil, "both are in the file")
        expect(!h.editor.canShow(BoardID(owner: orphanBoard)) && !h.editor.canShow(BoardID(owner: token)))
        expectEqual(h.editor.shape(inFile: hidden), nil)
        expectEqual(state.resolve(hidden), .unavailable)
        expectEqual(state.resolve(held), .unavailable)
        expectEqual(h.editor.mentionPills(of: jot).map(\.isLive), [false, false])
        expectEqual(h.editor.tableOfContents?.entries.first { $0.id == jot }?.label?.text, "@Old @Older", "by the names the text holds")
        let size = CGSize(width: 240, height: 240)
        expectEqual(largestDifference(renderBitmap(h.editor, size: size, scale: 2), renderBitmap(try harness(holding: false).editor, size: size, scale: 2),
                                      in: CGRect(origin: .zero, size: size)), 0, "drawn as a mention of a shape that isn't in the file")

        // A double-click on its pill goes nowhere: the jot is selected, on the root.
        let pill = try require(h.editor.mentionPills(of: jot).first)
        h.click(at: h.view(CGPoint(x: pill.frame.midX, y: pill.frame.midY)), clickCount: 2)
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [jot])
    },

    test("entering a board for the first time reads its mention text at once, and its catalog on the scheduler's next turn, or at the first @ if that comes first") {
        #if DEBUG
        let b = try PocketBoard()
        let entries = b.state.entriesRead, texts = b.state.textsRead
        expect(b.editor.showBoard(b.pocketBoard))
        expect(b.state.textsRead > texts, "the mention text is read on the way in")
        expectEqual(b.state.mentions(in: b.inner), [b.milk])
        expectEqual(b.row(b.inner), "@Milk")
        expectEqual(b.state.entriesRead, entries, "no catalog entry is read on the way in")
        b.h.wait(0)
        let read = b.state.entriesRead
        expect(read > entries, "read on the scheduler's next turn")
        expectEqual(b.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: b.inner).all.map(\.id), [b.groceries])
        expectEqual(b.state.entriesRead, read, "and not again at the first @")
        expect(b.editor.showBoard(.root))
        expect(b.editor.showBoard(b.pocketBoard))
        b.h.wait(0)
        expectEqual(b.state.entriesRead, read, "nor on going back to it")

        // The first @ before that turn reads it then, and the turn reads nothing more.
        let c = try PocketBoard()
        let before = c.state.entriesRead
        expect(c.editor.showBoard(c.pocketBoard))
        expectEqual(c.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: c.inner).all.map(\.id), [c.groceries])
        let queried = c.state.entriesRead
        expectEqual(queried - before, read - entries, "the same catalog, read at the query")
        c.h.wait(0)
        expectEqual(c.state.entriesRead, queried)

        // Left before that turn, it's kept unread, and read at the first @ on going back.
        let d = try PocketBoard()
        expect(d.editor.showBoard(d.pocketBoard))
        expect(d.editor.showBoard(.root))
        expectEqual(d.state.candidates(matching: "Milk", in: AnyMentionable.self, for: d.jot).all.map(\.id), [d.milk], "the root's catalog, as it was kept")
        expect(d.editor.showBoard(d.pocketBoard))
        expectEqual(d.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: d.inner).all.map(\.id), [d.groceries])
        #endif
    },

    test("the @ picker lists the shapes on the board shown, not those on other boards") {
        let b = try PocketBoard()
        let root = b.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: b.jot).all.map(\.id)
        expect(!root.contains(b.groceries), "\(root)")
        expect(b.editor.showBoard(b.pocketBoard))
        let inside = b.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: b.inner).all.map(\.id)
        expectEqual(inside, [b.groceries])
        let milk = b.state.candidates(matching: "Milk", in: AnyMentionable.self, for: b.inner).all.map(\.id)
        expect(!milk.contains(b.milk), "the token is on the root: \(milk)")
    },
])
