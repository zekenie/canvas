import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// `canvas draw` and boards that can't change (a locked subboard's, and every board under it, at any
// depth): a script that would put a shape or an edge on one is refused, `read_only`, whether it names
// the subboard (`in`), a shape on its board, or draws on the board shown; changes and deletes of what's
// there are refused as any read-only shape's are; and a restatement that changes nothing goes through.
// CanvasTesting's frozen pocket stands in for a locked subboard.

/// The root: tile Hub, a frozen pocket "Plans" and a pocket "Open". Plans' board: tiles Deep and Side with
/// a link from Deep to Side, and a pocket "Inner", which isn't frozen itself, whose board holds tile
/// Bottom. Open's board: tile Free.
@MainActor private struct Locked {
    let hub = ShapeID(), plans = ShapeID(), open = ShapeID(), deep = ShapeID(), side = ShapeID(), link = ShapeID(), inner = ShapeID(),
        bottom = ShapeID(), free = ShapeID()
    var plansBoard: BoardID { BoardID(owner: plans) }
    var innerBoard: BoardID { BoardID(owner: inner) }
    var openBoard: BoardID { BoardID(owner: open) }

    var file: CanvasFile {
        func tile(_ id: ShapeID, _ label: String, x: CGFloat) -> AnyShapeRecord {
            AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: 0, width: 100, height: 60), label: label)))
        }
        func pocket(_ id: ShapeID, _ name: String, x: CGFloat, frozen: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: 300, width: 100, height: 100))))
            record[Nickname.self] = name
            if frozen { record[Frozen.self] = true }
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [tile(hub, "Hub", x: 0), pocket(plans, "Plans", x: 0, frozen: true), pocket(open, "Open", x: 200)]),
                          children: [plans: CanvasDocument(shapes: [tile(deep, "Deep", x: 0), tile(side, "Side", x: 200),
                                                                    AnyShapeRecord(ShapeRecord(id: link, Link(from: deep, to: side))),
                                                                    pocket(inner, "Inner", x: 400)]),
                                     inner: CanvasDocument(shapes: [tile(bottom, "Bottom", x: 0)]),
                                     open: CanvasDocument(shapes: [tile(free, "Free", x: 0)])])
    }

    func editor(_ log: RefusalLog = RefusalLog()) throws -> CanvasEditor {
        let editor = try drawEditor([PocketsPlugin(), namedPockets, FreezingPlugin(log: log)])
        editor.replaceFile(with: file)
        return editor
    }
}

/// What a refused run left: the file as it was, and no step.
@MainActor private struct Untouched {
    let editor: CanvasEditor
    let file: CanvasFile
    let step: String?

    init(_ editor: CanvasEditor) {
        self.editor = editor
        file = editor.file
        step = editor.undoHistory.undoName
    }

    func holds(_ message: String = "", file: StaticString = #fileID, line: UInt = #line) {
        expectEqual(editor.file, self.file, "nothing committed \(message)", file: file, line: line)
        expectEqual(editor.undoHistory.undoName, step, "and no step \(message)", file: file, line: line)
    }
}

@MainActor let drawReadOnlyBoardTests = Suite("draw: a read-only board", [
    test("in a locked subboard is refused, as in a locked frame is, and so is in a subboard that isn't locked itself but is on a locked one's board; one that isn't is drawn in") {
        let log = RefusalLog(), l = Locked(), editor = try l.editor(log)
        let untouched = Untouched(editor)
        for (name, on) in [("Plans", l.plansBoard), ("Inner", l.innerBoard)] {
            let error = try refused(#"tile "N" in "\#(name)""#, on: editor)
            expectEqual(error.reason, "read_only", name)
            expectEqual(error.message, #""\#(name)" is read-only (locked, say), so nothing goes in it"#)
            expectEqual(error.hint, #"leave in "\#(name)" out, or ask the user to unlock it"#)
            expectEqual(error.data?["line"], 1)
            let dry = try refused(#"tile "N" in "\#(name)""#, on: editor, ["--dry-run"])
            expectEqual(dry.message, error.message, "a dry run says the same")
            expectEqual(editor.contents(of: on).shapes.count, on == l.plansBoard ? 4 : 1)
        }
        untouched.holds()
        expectEqual(log.refusals, [], "a refused run of an agent shakes nothing")
        let result = try drawn(#"tile "N" in "Open""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        expectEqual(editor.contents(of: l.openBoard).shapes.compactMap { $0.typed(as: Tile.self)?.props.label }, ["Free", "N"])
    },
    test("a shape placed against one on a locked subboard's board would land there: refused, naming the board, and whatever its depth; unnamed shapes too") {
        let l = Locked(), editor = try l.editor()
        let untouched = Untouched(editor)
        let side = try refused(#"tile "N" right of "Side""#, on: editor)
        expectEqual(side.reason, "read_only")
        expectEqual(side.message, #""N" would go on "Plans"'s board, which is read-only (locked, say)"#)
        expectEqual(side.hint, "leave it out of the script, or ask the user to unlock what holds the board")
        expectEqual(try refused(#"tile "N" right of "Side""#, on: editor, ["--dry-run"]).message, side.message)
        let deeper = try refused(#"tile "N" below "Bottom""#, on: editor)
        expectEqual(deeper.reason, "read_only")
        expectEqual(deeper.message, #""N" would go on "Inner"'s board, which is read-only (locked, say)"#, "Inner isn't locked itself")
        let unnamed = try refused("card below \"Deep\"", on: editor)
        expectEqual(unnamed.message, #"the card on line 1 would go on "Plans"'s board, which is read-only (locked, say)"#)
        untouched.holds()
    },
    test("with the window on a locked subboard's board, a shape that names nothing would land there: refused; on the board of one under it, naming that one's") {
        let l = Locked(), editor = try l.editor()
        let untouched = Untouched(editor)
        expect(editor.showBoard(l.plansBoard))
        let error = try refused(#"tile "N""#, on: editor)
        expectEqual(error.reason, "read_only")
        expectEqual(error.message, #""N" would go on "Plans"'s board, which is read-only (locked, say)"#)
        expectEqual(try refused("tile\ncard", on: editor).data?["errors"]?.arrayValue?.count, 2, "each shape its own")
        expect(editor.showBoard(l.innerBoard))
        expectEqual(try refused("tile", on: editor).message, #"the tile on line 1 would go on "Inner"'s board, which is read-only (locked, say)"#)
        untouched.holds()
        let elsewhere = try drawn(#"tile "N" in "Open""#, on: editor)
        expectEqual(rows(elsewhere).map { $0["did"] }, ["created"], "a board that takes shapes, drawn on from one that doesn't")
        expectEqual(editor.board, l.innerBoard, "the window stays")
    },
    test("a new edge on a locked subboard's board is refused, and a dry run says the same; one already drawn restated, unchanged, passes") {
        let l = Locked(), editor = try l.editor()
        let untouched = Untouched(editor)
        let again = try drawn(#"edge "Deep" -> "Side""#, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        let reversed = try refused(#"edge "Side" -> "Deep""#, on: editor)
        expectEqual(reversed.reason, "read_only")
        expectEqual(reversed.message, #"edge "Side" -> "Deep" would go on "Plans"'s board, which is read-only (locked, say)"#)
        expectEqual(reversed.hint, "leave it out of the script, or ask the user to unlock what holds the board")
        expectEqual(try refused(#"edge "Side" -> "Deep""#, on: editor, ["--dry-run"]).message, reversed.message)
        untouched.holds()
    },
    test("what's already on the board is read-only: a change or a deletion is refused, with the messages a locked shape's has; a restatement that changes nothing is fine") {
        let l = Locked(), editor = try l.editor()
        let untouched = Untouched(editor)
        let change = try refused(#"tile "Deep" finish: glossy"#, on: editor)
        expectEqual(change.reason, "read_only")
        expectEqual(change.message, #""Deep" is read-only (locked, say), so it stays as it is"#)
        expectEqual(change.hint, "leave it out of the script, or ask the user to unlock it")
        let moved = try refused(#"tile "Deep" below "Side""#, on: editor)
        expectEqual(moved.message, #""Deep" is read-only (locked, say), so it stays as it is"#)
        let renamed = try refused(#"tile "Deep" title: "Down""#, on: editor)
        expectEqual(renamed.reason, "read_only")
        let removed = try refused(#"delete "Deep""#, on: editor)
        expectEqual(removed.reason, "read_only")
        expectEqual(removed.message, #""Deep" is read-only (locked, say), so it can't be deleted"#)
        let edges = try refused(#"delete edge "Deep" -> "Side""#, on: editor)
        expectEqual(edges.reason, "read_only")
        expectEqual(edges.message, #"one of the connections delete edge "Deep" -> "Side" removes is read-only (locked, say), so it can't be deleted"#)
        let inner = try refused(#"delete "Inner""#, on: editor)
        expectEqual(inner.reason, "read_only", "a subboard on a locked one's board, holding nothing locked itself")
        expectEqual(inner.message, #""Inner" is read-only (locked, say), so it can't be deleted"#)
        untouched.holds()
        let same = try drawn("tile \"Deep\"\ntile \"Side\" finish: matte\nedge \"Deep\" -> \"Side\"", on: editor)
        expectEqual(rows(same).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(messages(same), [])
        let dry = try drawn(#"tile "Deep""#, on: editor, ["--dry-run"])
        expectEqual(dry["dryRun"], true)
        untouched.holds("for restatements")
    },
    test("a run that mixes what changes nothing with what would land is refused whole, and so is one that names a shape on a board below a locked one") {
        let l = Locked(), editor = try l.editor()
        let untouched = Untouched(editor)
        let mixed = try refused("tile \"Deep\"\ntile \"N\" right of \"Deep\"", on: editor)
        expectEqual(mixed.message, #""N" would go on "Plans"'s board, which is read-only (locked, say)"#)
        expectEqual(mixed.data?["line"], 2)
        let below = try refused(#"tile "Bottom" finish: glossy"#, on: editor)
        expectEqual(below.message, #""Bottom" is read-only (locked, say), so it stays as it is"#, "on Inner's board, under Plans'")
        untouched.holds()
    },
    test("unlocked, every board takes shapes again: in, placed against, edges, and changes") {
        let l = Locked(), editor = try l.editor()
        expect(editor.showBoard(.root))
        editor.freeze([l.plans], false)
        expectEqual(rows(try drawn(#"tile "N" in "Plans""#, on: editor)).map { $0["did"] }, ["created"])
        expectEqual(rows(try drawn(#"tile "M" below "Bottom""#, on: editor)).map { $0["did"] }, ["created"])
        expectEqual(rows(try drawn(#"edge "Side" -> "Deep""#, on: editor)).map { $0["did"] }, ["connected"])
        expectEqual(rows(try drawn(#"tile "Deep" finish: glossy"#, on: editor)).map { $0["did"] }, ["updated"])
        expectEqual(rows(try drawn(#"delete "Side""#, on: editor)).map { $0["did"] }.first, "deleted")
    },
])
