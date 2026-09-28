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
// its shapes' names with it until undo brings them back. The index is the board shown's; the
// picker's catalog is the file's.

/// A file whose root holds a pocket, holding plate "Groceries" on its board, and a jot at (20, 20)
/// whose text mentions the plate (by the name "Old name") and token "Milk", on the root, far off;
/// and on the pocket's board, a jot mentioning the token. The view is 800 × 600 at zoom 1.
@MainActor private final class PocketBoard {
    let h: EditorHarness
    let pocket = ShapeID(), groceries = ShapeID(), milk = ShapeID(), jot = ShapeID(), inner = ShapeID()
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }
    var pocketBoard: BoardID { BoardID(owner: pocket) }

    /// `holdsGroceries` false leaves the plate out of the file; `more` are plugins after the
    /// standard list and pockets.
    init(holdsGroceries: Bool = true, groceriesOnRoot: Bool = false, more: [any CanvasPlugin] = []) throws {
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
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()] + more),
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

    test("a mention of a kind followed by opening it goes into it: a double-click on its pill, or following it from the text, shows its board, one step back") {
        let pocket = ShapeID(), jot = ShapeID()
        let entered = Contributor(id: "entered-pockets") { r in
            r.opens(Pocket.self, "Open") { pocket, editor in editor.showBoard(BoardID(owner: pocket.id)) }
            r.mentionable(Pocket.self, following: .opens)
        }
        let root = [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 1200, y: 1200, width: 100, height: 100)))),
                    AnyShapeRecord(ShapeRecord(id: jot, Jot(CGRect(x: 20, y: 20, width: 200, height: 200),
                                                            text: mentioning([.text("See "), .mention(pocket, label: "Pocket")]))))]
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin(), entered]), file: CanvasFile(root: CanvasDocument(shapes: root)))
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let pill = try require(h.editor.mentionPills(of: jot).first)
        expect(pill.isLive)
        h.click(at: h.view(CGPoint(x: pill.frame.midX, y: pill.frame.midY)), clickCount: 2)
        expectEqual(h.editor.board, BoardID(owner: pocket))
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
        expectEqual(h.editor.selection, jot, "to the jot the press selected, not the pocket going into it passed through")

        let mentions = try require(h.editor.mentions)
        mentions.follow(pocket)
        h.wait(10)
        expectEqual(h.editor.board, BoardID(owner: pocket))
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selection, jot)
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

    test("the catalog is the file's, read as the editor opens: entering a board reads its mention text and none of the catalog, nor does the turn after, the first @, or going back") {
        #if DEBUG
        let b = try PocketBoard()
        let entries = b.state.entriesRead, texts = b.state.textsRead
        expectEqual(entries, 3, "every shape of the file with a name, on either board: the root's jot, the token and the plate (the pocket's jot holds only a mention, so it has none)")
        expect(b.editor.showBoard(b.pocketBoard))
        expect(b.state.textsRead > texts, "the mention text is read on the way in")
        expectEqual(b.state.mentions(in: b.inner), [b.milk])
        expectEqual(b.row(b.inner), "@Milk")
        b.h.wait(0)
        expectEqual(b.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: b.inner).all.map(\.id), [b.groceries])
        expect(b.editor.showBoard(.root))
        expect(b.editor.showBoard(b.pocketBoard))
        b.h.wait(0)
        expectEqual(b.state.entriesRead, entries, "no entry read again")
        #endif
    },

    test("the @ picker lists the mentionable shapes on every board of the file it can show, the board shown's first; not those on a board it can't show") {
        let b = try PocketBoard()
        let fromRoot = { (query: String) in b.state.candidates(matching: query, in: AnyMentionable.self, for: b.jot).matches.map(\.id) }
        expectEqual(fromRoot("Groceries"), [b.groceries], "on the pocket's board")
        expect(b.editor.showBoard(b.pocketBoard))
        expectEqual(b.state.candidates(matching: "Milk", in: AnyMentionable.self, for: b.inner).matches.map(\.id), [b.milk], "on the root")
        expect(b.editor.showBoard(.root))

        // Another "Groceries" on the root, far off: the root's comes first there, the pocket's inside.
        var far = ShapeRecord(Plate(CGRect(x: 9000, y: 9000, width: 120, height: 80)))
        far[TitleProperty.self] = "Groceries"
        b.editor.transact { $0.insert(far) }
        expectEqual(fromRoot("Groceries"), [far.id, b.groceries])
        expect(b.editor.showBoard(b.pocketBoard))
        expectEqual(b.state.candidates(matching: "Groceries", in: AnyMentionable.self, for: b.inner).matches.map(\.id), [b.groceries, far.id])

        // Not a shape on a board the app can't show: one whose owner isn't in the file.
        let orphan = ShapeID(), hidden = ShapeID()
        var plate = ShapeRecord(id: hidden, Plate(CGRect(x: 0, y: 0, width: 120, height: 80)))
        plate[TitleProperty.self] = "Hidden"
        let root = [AnyShapeRecord(ShapeRecord(id: b.jot, Jot(CGRect(x: 20, y: 20, width: 200, height: 200))))]
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                                  file: CanvasFile(root: CanvasDocument(shapes: root), children: [orphan: CanvasDocument(shapes: [AnyShapeRecord(plate)])]))
        expectEqual(h.editor.mentionState.candidates(matching: "Hidden", in: AnyMentionable.self, for: b.jot).matches.map(\.id), [])
    },

    test("an empty @ lists what's nearby on the board shown, then the boards it's inside, the board shown's own first") {
        let mentionablePockets = Contributor(id: "mentionable-pockets") { $0.mentionable(Pocket.self, label: { _ in "Pouch" }) }
        let b = try PocketBoard(more: [mentionablePockets])
        expect(b.editor.showBoard(b.pocketBoard))
        let found = b.state.candidates(matching: "", in: AnyMentionable.self, for: b.inner)
        expectEqual(found.nearby.map(\.id), [b.groceries, b.pocket], "the plate beside it, then the pocket it's in")
    },

    test("a file put in place takes the catalog afresh, whether the board shown stays or the file can't show it") {
        @MainActor func plate(_ title: String) -> ShapeRecord<Plate> {
            var plate = ShapeRecord(Plate(CGRect(x: 0, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = title
            return plate
        }
        let chores = plate("Chores"), laundry = plate("Laundry"), sack = ShapeRecord(Pocket(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let other = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(chores), AnyShapeRecord(sack)]),
                               children: [sack.id: CanvasDocument(shapes: [AnyShapeRecord(laundry)])])
        let find = { (b: PocketBoard, query: String) in b.state.candidates(matching: query, in: AnyMentionable.self, for: nil).matches.map(\.id) }

        // On the root, which the new file shows too.
        let b = try PocketBoard()
        b.editor.replaceFile(with: other)
        expectEqual(b.editor.board, .root)
        expectEqual(find(b, "Groceries"), [], "the old file's shapes are gone")
        expectEqual(find(b, "Milk"), [])
        expectEqual(find(b, "Chores"), [chores.id])
        expectEqual(find(b, "Laundry"), [laundry.id], "and the new file's other boards are in")

        // Inside the pocket, which the new file doesn't have: it goes to the root with the file.
        let c = try PocketBoard()
        expect(c.editor.showBoard(c.pocketBoard))
        c.editor.replaceFile(with: other)
        expectEqual(c.editor.board, .root)
        expectEqual(find(c, "Groceries"), [])
        expectEqual(find(c, "Laundry"), [laundry.id])
    },

    test("the catalog follows commits on every board: a rename written to another board is found by its new name, a board deleted with its owner takes its shapes out, and undo brings them back") {
        let b = try PocketBoard()
        let find = { (query: String) in b.state.candidates(matching: query, in: AnyMentionable.self, for: b.jot).matches.map(\.id) }
        b.editor.transact(on: b.pocketBoard, "Rename") { $0.update(b.groceries) { $0[TitleProperty.self] = "Errands" } }
        expectEqual(find("Errands"), [b.groceries])
        expectEqual(find("Groceries"), [])
        b.editor.transact { $0.delete([b.pocket]) }
        expectEqual(find("Errands"), [])
        b.editor.undo()
        expectEqual(find("Errands"), [b.groceries])
        b.editor.redo()
        expectEqual(find("Errands"), [])
    },
])
