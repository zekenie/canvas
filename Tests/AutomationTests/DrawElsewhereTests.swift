@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// `canvas draw` never names a board: a title names a shape wherever it is in the file (the board
// shown's first), and `in "X"` puts a shape on the board X holds. A run draws on one board, without
// moving the window. `canvas show` moves it.

/// Pockets with nicknames: the names plugin calls a pocket by its nickname.
let namedPockets = Contributor(id: "named-pockets") { $0.optIn(Pocket.self, to: Nickname.self) }

/// The root: tile Hub, pocket P and pocket Q. P's board: tile Deep and tile Hub. Q's: tile Twin. And
/// tile Twin on P's board too.
@MainActor struct Nest {
    let p = ShapeID(), q = ShapeID(), hub = ShapeID(), deep = ShapeID(), pHub = ShapeID(), twin = ShapeID(), pTwin = ShapeID()

    var file: CanvasFile {
        func tile(_ id: ShapeID, _ label: String, x: CGFloat) -> AnyShapeRecord {
            AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: 0, width: 100, height: 60), label: label)))
        }
        func pocket(_ id: ShapeID, _ name: String, x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: x, y: 300, width: 100, height: 100))))
            record[Nickname.self] = name
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [tile(hub, "Hub", x: 0), pocket(p, "P", x: 0), pocket(q, "Q", x: 200)]),
                          children: [p: CanvasDocument(shapes: [tile(deep, "Deep", x: 0), tile(pHub, "Hub", x: 300), tile(pTwin, "Twin", x: 600)]),
                                     q: CanvasDocument(shapes: [tile(twin, "Twin", x: 0)])])
    }

    func editor(_ more: [any CanvasPlugin] = []) throws -> CanvasEditor {
        let editor = try drawEditor([PocketsPlugin(), namedPockets] + more)
        editor.replaceFile(with: file)
        return editor
    }
}

/// The tiles on a board, by label.
@MainActor func labels(on board: BoardID, in editor: CanvasEditor) -> [String] {
    editor.contents(of: board).shapes.compactMap { $0.typed(as: Tile.self)?.props.label }
}

@MainActor let drawElsewhereTests = Suite("draw: a board other than the one shown", [
    test("in \"P\" draws on P's board, and the window stays where it is: one step there, whose undo shows it") {
        let n = Nest(), editor = try n.editor()
        let result = try drawn(#"tile "Cache" in "P""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        expectEqual(result["on"], ["board": .string(n.p.description), "title": "P", "shown": false])
        expectEqual(editor.board, .root, "the window didn't move")
        expectEqual(labels(on: BoardID(owner: n.p), in: editor), ["Deep", "Hub", "Twin", "Cache"])
        expectEqual(labels(on: .root, in: editor), ["Hub"])
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.board, BoardID(owner: n.p), "undoing it shows its board")
        expectEqual(labels(on: BoardID(owner: n.p), in: editor), ["Deep", "Hub", "Twin"])
    },
    test("a title on another board names that shape there: restated, or placed against") {
        let n = Nest(), editor = try n.editor()
        let restated = try drawn(#"tile "Deep" finish: glossy"#, on: editor)
        expectEqual(rows(restated).map { $0["did"] }, ["updated"])
        expectEqual(restated["on"]?["board"], .string(n.p.description))
        expectEqual(editor.file.record(n.deep)?.typed(as: Tile.self)?.props.finish, .glossy)
        _ = try drawn(#"tile "Below" below "Deep""#, on: editor)
        expectEqual(labels(on: BoardID(owner: n.p), in: editor), ["Deep", "Hub", "Twin", "Below"])
        expectEqual(editor.board, .root)
    },
    test("a title on the board shown and on another is the board shown's; in \"P\" says the other") {
        let n = Nest(), editor = try n.editor()
        _ = try drawn(#"tile "Hub" finish: glossy"#, on: editor)
        expectEqual(editor.file.record(n.hub)?.typed(as: Tile.self)?.props.finish, .glossy)
        expectEqual(editor.file.record(n.pHub)?.typed(as: Tile.self)?.props.finish, .matte)
        _ = try drawn(#"tile "Hub" in "P" finish: glossy"#, on: editor)
        expectEqual(editor.file.record(n.pHub)?.typed(as: Tile.self)?.props.finish, .glossy)
    },
    test("a title on two boards, neither shown, is ambiguous until in says which") {
        let n = Nest(), editor = try n.editor()
        let twice = try refused(#"tile "Twin" finish: glossy"#, on: editor)
        expectEqual(twice.reason, "ambiguous_title")
        expectEqual(twice.message, #""Twin" is on 2 boards: "P"'s board and "Q"'s board"#)
        _ = try drawn(#"tile "Twin" in "Q" finish: glossy"#, on: editor)
        expectEqual(editor.file.record(n.twin)?.typed(as: Tile.self)?.props.finish, .glossy)
        expectEqual(editor.file.record(n.pTwin)?.typed(as: Tile.self)?.props.finish, .matte)
    },
    test("a title on two boards is settled by the rest of the script, and goes with it") {
        let n = Nest(), editor = try n.editor()
        _ = try drawn(#"tile "Deep" finish: glossy"# + "\n" + #"tile "Near" below "Twin""#, on: editor)
        expectEqual(labels(on: BoardID(owner: n.p), in: editor), ["Deep", "Hub", "Twin", "Near"], "Twin is P's, where Deep is")
        _ = try drawn(#"tile "Deep" finish: matte"# + "\n" + #"tile "Legend" inside view top-right"#, on: editor)
        expectEqual(labels(on: BoardID(owner: n.p), in: editor).last, "Legend", "one with no title to go by goes with the rest")
    },
    test("in passes over a shape that holds no board for the one that does, and needs names") {
        let n = Nest()
        let editor = try n.editor()
        editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Tile(CGRect(x: 600, y: 0, width: 100, height: 60), label: "Q")))) }
        _ = try drawn(#"tile "Cache" in "Q""#, on: editor)
        expectEqual(labels(on: BoardID(owner: n.q), in: editor), ["Twin", "Cache"])
        _ = try run(["show", "Q"], on: editor).get()
        expectEqual(editor.board, BoardID(owner: n.q))
        let nameless = try makeEditor([PocketsPlugin(), namedPockets])
        nameless.replaceFile(with: n.file)
        expectEqual(try refused(#"tile in "P""#, on: nameless).reason, "no_names")
    },
    test("a run draws on one board: one that names shapes on two is refused, and so is an edge between them") {
        let n = Nest(), editor = try n.editor()
        let two = try refused(#"tile "Deep" finish: glossy"# + "\n" + #"tile "Hub" finish: glossy"#, on: editor)
        expectEqual(two.reason, "several_boards")
        expectEqual(two.hint, "a run draws on one board: split the script into a run for each")
        expectEqual(try refused(#"edge "Hub" -> "Deep""#, on: editor).reason, "several_boards")
        let placed = try refused(#"tile "New" in "P" below "Hub" and "Q""#, on: editor)
        expectEqual(placed.reason, "several_boards", "Q is on the root, and the run draws on P's board")
        expectEqual(editor.file.record(n.deep)?.typed(as: Tile.self)?.props.finish, .matte, "nothing changed")
        expect(!editor.canUndo)
    },
    test("in names a shape that holds a board, on the file, not one the script draws") {
        let editor = try Nest().editor()
        expectEqual(try refused(#"tile "New" in "Hub""#, on: editor).reason, "cannot_contain")
        expectEqual(try refused(#"tile "New" in "Nowhere""#, on: editor).reason, "unknown_title")
        let drawn = try refused(#"tile "T"\#ntile "U" in "T""#, on: editor)
        expectEqual(drawn.reason, "unsupported")
        expectEqual(drawn.data?["line"], 2)
    },
    test("a dry run on another board changes nothing, and makes no step") {
        let n = Nest(), editor = try n.editor()
        let result = try drawn(#"tile "Cache" in "P""#, on: editor, ["--dry-run"])
        expectEqual(rows(result).map { $0["did"] }, ["created"])
        expectEqual(labels(on: BoardID(owner: n.p), in: editor), ["Deep", "Hub", "Twin"])
        expect(!editor.canUndo)
    },
    test("an unplaced shape on another board lands in the view that board is shown with") {
        let n = Nest(), editor = try n.editor()
        expect(editor.showBoard(BoardID(owner: n.p)))
        editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))
        expect(editor.showBoard(.root))
        let result = try drawn(#"tile "Far" in "P""#, on: editor)
        expectEqual(rows(result).first?["inView"], true)
        let far = try require(editor.contents(of: BoardID(owner: n.p)).shapes.first { $0.typed(as: Tile.self)?.props.label == "Far" })
        expect(CGRect(x: 5000, y: 5000, width: 800, height: 600).contains(try require(far.box)), "\(String(describing: far.box))")
    },
    test("a script on the board above can't delete the shape holding the board shown") {
        let n = Nest(), editor = try n.editor()
        expect(editor.showBoard(BoardID(owner: n.p)))
        let held = try refused(#"delete "P""#, on: editor)
        expectEqual(held.reason, "board_shown")
        expectEqual(held.message, #""P" holds the board the window shows, so it can't be deleted"#)
        _ = try drawn(#"delete "Q""#, on: editor)
        expectEqual(editor.file.record(n.q), nil)
        expectEqual(editor.board, BoardID(owner: n.p))
    },
    test("--reveal shows the board it drew on") {
        let n = Nest(), editor = try n.editor()
        let result = try drawn(#"tile "Cache" in "P""#, on: editor, ["--reveal"])
        expectEqual(editor.board, BoardID(owner: n.p))
        expectEqual(result["on"]?["shown"], true)
    },
    test("a run on another board goes on while a press is held on the board shown") {
        let still = Contributor(id: "still") { $0.tool(ToolDescriptor(id: "still", label: "Still", systemImage: "hand.raised")) { _ in StillTool() } }
        let n = Nest()
        let h = try EditorHarness { _ in
            let editor = try drawEditor([PocketsPlugin(), namedPockets, still])
            editor.replaceFile(with: n.file)
            return editor
        }
        h.editor.setTool("still")
        h.press(at: CGPoint(x: 10, y: 10))
        expectEqual(try refused("tile", on: h.editor).reason, "busy")
        expectEqual(rows(try drawn(#"tile "Cache" in "P""#, on: h.editor)).map { $0["did"] }, ["created"])
        h.release()
    },
])

@MainActor let showTests = Suite("show", [
    test("it shows the board a shape holds, by title, and the root; its result says where the window is") {
        let n = Nest(), editor = try n.editor()
        let shown = try run(["show", "P"], on: editor).get()
        expectEqual(editor.board, BoardID(owner: n.p))
        expectEqual(shown, ["board": ["shows": .string(n.p.description), "showsPath": ["root", .string(n.p.description)]], "title": "P"])
        _ = try run(["show", "--root"], on: editor).get()
        expectEqual(editor.board, .root)
        expect(!editor.canUndo, "showing a board is no step")
    },
    test("it waits for a press held, as a draw does") {
        let still = Contributor(id: "still") { $0.tool(ToolDescriptor(id: "still", label: "Still", systemImage: "hand.raised")) { _ in StillTool() } }
        let n = Nest()
        let h = try EditorHarness { _ in
            let editor = try drawEditor([PocketsPlugin(), namedPockets, still])
            editor.replaceFile(with: n.file)
            return editor
        }
        h.editor.setTool("still")
        h.press(at: CGPoint(x: 10, y: 10))
        guard case .failure(let error) = try run(["show", "P"], on: h.editor) else { return expect(false, "it showed P mid-press") }
        expectEqual(error.reason, "busy")
        expectEqual(h.editor.board, .root)
        h.release()
    },
    test("it refuses what holds no board, a title nothing has, and a title with --root") {
        let editor = try Nest().editor()
        @MainActor func reason(_ line: [String]) throws -> String? {
            guard case .failure(let error) = try run(line, on: editor) else { return nil }
            return error.reason
        }
        expectEqual(try reason(["show", "Hub"]), "cannot_contain")
        expectEqual(try reason(["show", "Nowhere"]), "unknown_title")
        expectEqual(try reason(["show", "P", "--root"]), "invalid_params")
        expectEqual(try reason(["show"]), "invalid_params")
        expectEqual(editor.board, .root)
    },
])
