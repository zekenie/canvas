import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Connections
import CoreGraphics
import Foundation
import Locking
import Mentions
import Publishing
import References
import StickyNotes
import Subboards
import TestKit
import Titles
import Topology

// An edge to a shape on another board, as shipped, through `canvas` as built against the command
// server: a note on the root joined to a public note two boards down goes through a reference to it
// beside the note, the arrow into the pill (and `canvas query` reads it as into the original, with
// its `via`); either way round; `via: reference` on one board; a run again; `delete edge`, and
// `delete` of the note, which take the pill; a shape that isn't public, which can't be reached; and
// the run undone, pill and arrow together.

/// A file: on the root, notes Checkout, Ledger and Docs (Docs public) and subboard Payments; on
/// Payments' board, subboard Gateway; on Gateway's board, notes Auth (public) and Vault.
@MainActor private struct Wharf {
    let checkout = ShapeID(), ledger = ShapeID(), docs = ShapeID(), payments = ShapeID(), gateway = ShapeID(), auth = ShapeID(), vault = ShapeID()

    var file: CanvasFile {
        func note(_ id: ShapeID, _ title: String, at point: CGPoint, public isPublic: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title))))
            record[TitleProperty.self] = title
            if isPublic { record[PublicProperty.self] = true }
            return record
        }
        func subboard(_ id: ShapeID, _ title: String, at point: CGPoint) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Subboard(frame: CGRect(origin: point, size: CGSize(width: 240, height: 160)))))
            record[TitleProperty.self] = title
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [note(checkout, "Checkout", at: CGPoint(x: 100, y: 100)), note(ledger, "Ledger", at: CGPoint(x: 100, y: 500)),
                                                        note(docs, "Docs", at: CGPoint(x: 800, y: 100), public: true),
                                                        subboard(payments, "Payments", at: CGPoint(x: 800, y: 500))]),
                          children: [payments: CanvasDocument(shapes: [subboard(gateway, "Gateway", at: CGPoint(x: 0, y: 0))]),
                                     gateway: CanvasDocument(shapes: [note(auth, "Auth", at: CGPoint(x: 0, y: 0), public: true),
                                                                      note(vault, "Vault", at: CGPoint(x: 300, y: 0))])])
    }

    /// A board of the file, in a 1440 × 900 window's size, whose document the caller closes.
    func board() -> BoardDocument {
        let board = windowedBoard()
        board.editor.replaceFile(with: file)
        return board
    }
}

extension CanvasEditor {
    /// The references on a board, in the stack's order.
    fileprivate func references(on board: BoardID = .root) -> [ShapeRecord<Reference>] {
        contents(of: board).shapes.compactMap { $0.typed(as: Reference.self) }
    }

    /// The arrows on a board, by where each starts and ends: a title, or `reference` for a pill.
    fileprivate func arrowEnds(on board: BoardID = .root) -> [String] {
        func name(_ id: ShapeID?) -> String {
            guard let record = id.flatMap({ file.record($0) }) else { return "?" }
            if let reference = record.typed(as: Reference.self) { return "reference to \(reference.props.target?.label ?? "?")" }
            return registry.title(of: record) ?? record.kind.rawValue
        }
        return contents(of: board).shapes.compactMap { record -> String? in
            guard let arrow = record.typed(as: Arrow.self)?.props else { return nil }
            return "\(name(arrow.start.binding?.shapeID)) -> \(name(arrow.end.binding?.shapeID))"
        }
    }
}

@MainActor let drawStandInsTests = Suite("canvas draw: an edge to a shape on another board goes through a reference, as shipped", [
    test("a note joined to a public note two boards down: a reference to it beside the note, the arrow into the pill, which a query reads as into the original") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["draw", #"edge "Checkout" -> "Auth""#])
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        let editor = board.editor
        let pill = try require(editor.references().first)
        expectEqual(editor.references().count, 1)
        expectEqual(pill.props.target, ReferenceTarget(id: wharf.auth, label: "Auth"), "a direct reference to Auth, called as draw folds its title")
        expectEqual(pill.props.frame.width, ReferenceEdits.width(of: pill.props), "fitted to its label")
        let checkout = try require(editor.file.record(wharf.checkout)?.box)
        expectEqual(pill.frame.minX, checkout.maxX + 80, "right of Checkout")
        expectEqual(pill.frame.midY, checkout.midY)
        expectEqual(editor.arrowEnds(), ["Checkout -> reference to Auth"])
        let arrow = try require(editor.document.shapes.first { $0.kind == Arrow.kind })
        expectEqual(arrow[ChannelProperty.self], NoteLink.id, "the channel a note takes: a pill for a note takes it")
        expectEqual(editor.topology?.standIns(for: wharf.auth), [pill.id])
        expectEqual(json["changes"]?.arrayValue?.map { $0["did"] }, ["created", "connected"])
        expectEqual(json["changes"]?.arrayValue?.first?["kind"], "reference")
        expectEqual(json["changes"]?.arrayValue?.last, ["line": 1, "did": "connected", "kind": "arrow", "from": "Checkout", "to": "Auth", "channel": "note-link", "via": "reference"])
        expectEqual(json["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [], "the row says it went through a reference")
        expectEqual(json["on"]?["board"], "root")
        expectEqual(editor.board, .root)

        // A query reads the arrow as into Auth, through the pill.
        let asked = try canvas(server, ["query", #"sticky-note:edge-to("Auth")"#, "--brief", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        let answer = try JSON(text: asked.output)
        let rows = try require(answer["rows"]?.arrayValue)
        expectEqual(rows.map { $0["title"] }, ["Checkout"])
        let connected = try canvas(server, ["query", #"arrow:ends-at("Auth")"#, "--brief", "--board", "\(board.number)"])
        let connection = try require(JSON(text: connected.output)["rows"]?.arrayValue?.first?["connection"])
        expectEqual(connection["from"]?["title"], "Checkout")
        expectEqual(connection["to"]?["title"], "Auth")
        expectEqual(connection["via"]?["to"]?["id"], .string(pill.id.description), "through the pill")
    },

    test("the far note may be the start: the reference is left of the note, and the arrow runs out of it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["draw", #"edge "Auth" -> "Ledger""#])
        expectEqual(result.status, 0, result.error)
        let editor = board.editor
        let pill = try require(editor.references().first)
        let ledger = try require(editor.file.record(wharf.ledger)?.box)
        expectEqual(pill.frame.maxX, ledger.minX - 80, "left of Ledger")
        expectEqual(editor.arrowEnds(), ["reference to Auth -> Ledger"])
        let json = try JSON(text: result.output)
        expectEqual(json["changes"]?.arrayValue?.last?["via"], "reference")
        expectEqual(json["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [])
        let asked = try canvas(server, ["query", #"sticky-note:edge-from("Auth")"#, "--brief", "--board", "\(board.number)"])
        expectEqual(try JSON(text: asked.output)["rows"]?.arrayValue?.map { $0["title"] }, ["Ledger"])
    },

    test("via: reference puts one beside the start on one board too; a run again draws nothing, and an edge written without via is the one drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let first = try canvas(server, ["draw", #"edge "Checkout" -> "Docs" via: reference"#])
        expectEqual(first.status, 0, first.error)
        let editor = board.editor
        expectEqual(editor.references().first?.props.target, ReferenceTarget(id: wharf.docs, label: "Docs"))
        expectEqual(editor.arrowEnds(), ["Checkout -> reference to Docs"])
        let json = try JSON(text: first.output)
        expectEqual(json["changes"]?.arrayValue?.last?["via"], "reference")
        expectEqual(json["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [])
        // Again: nothing changes, the row says it went through the pill, and so does the edge without via.
        let file = editor.file, undoName = editor.undoHistory.undoName
        for script in [#"edge "Checkout" -> "Docs" via: reference"#, #"edge "Checkout" -> "Docs""#] {
            let again = try canvas(server, ["draw", script])
            expectEqual(again.status, 0, again.error)
            expectEqual(try JSON(text: again.output)["changes"]?.arrayValue,
                        [["line": 1, "did": "unchanged", "kind": "arrow", "from": "Checkout", "to": "Docs", "channel": "note-link", "via": "reference"]])
            expectEqual(editor.file, file)
        }
        expectEqual(editor.undoHistory.undoName, undoName)
        // A straight arrow is another edge: via over it is refused, saying how to redraw it.
        let straight = try canvas(server, ["draw", #"edge "Ledger" -> "Docs""#])
        expectEqual(straight.status, 0, straight.error)
        expectEqual(editor.arrowEnds().last, "Ledger -> Docs", "on one board, with no via: straight")
        let refused = try canvas(server, ["draw", #"edge "Ledger" -> "Docs" via: reference"#])
        expectEqual(refused.status, 1)
        let error = try JSON(text: refused.error)["error"]
        expectEqual(error?["reason"], "invalid_value")
        expectEqual(error?["message"], #"the edge "Ledger" -> "Docs" is drawn straight to "Docs""#)
        expectEqual(error?["hint"], #"write delete edge "Ledger" -> "Docs" above this line to draw it through a reference"#)
    },

    test("delete edge takes the arrow, and the pill it leaves with none, and so does delete of the note it starts from, unless the pill is locked; one undo brings both back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try canvas(server, ["draw", #"edge "Checkout" -> "Auth""#]).status, 0)
        let editor = board.editor
        let drawn = editor.file
        let deleted = try canvas(server, ["draw", #"delete edge "Checkout" -> "Auth""#])
        expectEqual(deleted.status, 0, deleted.error)
        expectEqual(try JSON(text: deleted.output)["changes"]?.arrayValue,
                    [["line": 1, "did": "deleted", "kind": "arrow", "from": "Checkout", "to": "Auth", "via": "reference"],
                     ["line": 1, "did": "deleted", "kind": "reference"]])
        expectEqual(editor.references().count, 0)
        expectEqual(editor.arrowEnds(), [])
        expect(editor.file.record(wharf.auth) != nil && editor.file.record(wharf.checkout) != nil, "the notes stay")
        editor.undo()
        expectEqual(editor.file, drawn)
        // delete "Checkout" takes its arrow, and the pill it leaves with none, the arrow's row naming Auth.
        let gone = try canvas(server, ["draw", #"delete "Checkout""#])
        expectEqual(gone.status, 0, gone.error)
        expectEqual(try JSON(text: gone.output)["changes"]?.arrayValue,
                    [["line": 1, "did": "deleted", "kind": "sticky-note", "title": "Checkout"],
                     ["line": 1, "did": "deleted", "kind": "arrow", "from": "Checkout", "to": "Auth", "via": "reference"],
                     ["line": 1, "did": "deleted", "kind": "reference"]])
        expectEqual(editor.references().count, 0)
        expectEqual(editor.arrowEnds(), [])
        expect(editor.file.record(wharf.auth) != nil, "Auth stays")
        editor.undo()
        expectEqual(editor.file, drawn, "one step")
        // A locked pill can't go with it: read_only, and nothing is deleted.
        let pill = try require(editor.references().first)
        editor.transact { $0.update(pill.id) { $0[LockedProperty.self] = true } }
        let locked = editor.file
        let refused = try canvas(server, ["draw", #"delete "Checkout""#])
        expectEqual(refused.status, 1)
        let error = try JSON(text: refused.error)["error"]
        expectEqual(error?["reason"], "read_only")
        expectEqual(error?["message"], #"the reference that delete "Checkout" leaves with no arrow is read-only (locked, say), so it can't be deleted"#)
        expectEqual(editor.file, locked)
    },

    test("a shape that isn't public can't be reached: several_boards, asking the user; and with the other end public, the run is the private one's board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let before = board.editor.file
        let refused = try canvas(server, ["draw", #"edge "Checkout" -> "Vault""#])
        expectEqual(refused.status, 1)
        let error = try JSON(text: refused.error)["error"]
        expectEqual(error?["reason"], "several_boards")
        expectEqual(error?["message"], #"this script draws on the root board ("Checkout", line 1) and on "Gateway"'s board ("Vault")"#)
        expectEqual(error?["hint"], #"an arrow can't leave its board: it goes into a reference standing for the shape on the other board, and only a public shape can be stood for; ask the user to make "Checkout" or "Vault" public, or split the script into a run for each board"#)
        expectEqual(board.editor.file, before)
        // Docs is public, Vault isn't: the run draws on Gateway's board, with a reference to Docs beside Vault.
        let result = try canvas(server, ["draw", #"edge "Docs" -> "Vault""#])
        expectEqual(result.status, 0, result.error)
        expectEqual(try JSON(text: result.output)["on"]?["board"], .string(wharf.gateway.description))
        expectEqual(board.editor.arrowEnds(on: BoardID(owner: wharf.gateway)), ["reference to Docs -> Vault"])
        expectEqual(board.editor.board, .root, "the window stays")
    },

    test("one undo takes the pill and the arrow back together; a dry run says the same and changes nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        let before = editor.file
        let dry = try canvas(server, ["draw", "--dry-run", #"edge "Checkout" -> "Auth""#])
        expectEqual(dry.status, 0, dry.error)
        let preview = try JSON(text: dry.output)
        expectEqual(preview["dryRun"], true)
        expectEqual(preview["changes"]?.arrayValue?.map { $0["did"] }, ["created", "connected"])
        expectEqual(editor.file, before)
        expect(!editor.canUndo)
        let real = try canvas(server, ["draw", #"edge "Checkout" -> "Auth""#])
        expectEqual(real.status, 0, real.error)
        expectEqual(try JSON(text: real.output)["warnings"], preview["warnings"])
        expectEqual(editor.undoHistory.undoName, "Draw")
        let made = editor.file
        editor.undo()
        expectEqual(editor.file, before, "the pill and the arrow, together")
        expect(!editor.canUndo, "one step")
        editor.redo()
        expectEqual(editor.file, made)
    },

    test("a run again finds the edge where its reference is, though it would draw on the start's board: unchanged, one reference, and delete edge takes it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor, gateway = BoardID(owner: wharf.gateway)
        // Docs and Auth are both public. Restating Auth puts the run on Gateway's board, where the
        // reference for Docs goes, left of it.
        let first = try canvas(server, ["draw", "-"], input: """
            sticky-note "Auth"
            edge "Docs" -> "Auth"
            """)
        expectEqual(first.status, 0, first.error)
        expectEqual(editor.arrowEnds(on: gateway), ["reference to Docs -> Auth"])
        let drawn = editor.file
        // Alone, nothing says which board, and the start's, Docs's, is where a second reference would go.
        let again = try canvas(server, ["draw", #"edge "Docs" -> "Auth""#])
        expectEqual(again.status, 0, again.error)
        let json = try JSON(text: again.output)
        expectEqual(json["changes"]?.arrayValue,
                    [["line": 1, "did": "unchanged", "kind": "arrow", "from": "Docs", "to": "Auth", "channel": "note-link", "via": "reference"]])
        expectEqual(json["on"]?["board"], .string(wharf.gateway.description), "where the reference is")
        expectEqual(editor.file, drawn)
        expectEqual(editor.references().count + editor.references(on: gateway).count, 1)
        // delete edge goes there too.
        let deleted = try canvas(server, ["draw", #"delete edge "Docs" -> "Auth""#])
        expectEqual(deleted.status, 0, deleted.error)
        expectEqual(try JSON(text: deleted.output)["changes"]?.arrayValue,
                    [["line": 1, "did": "deleted", "kind": "arrow", "from": "Docs", "to": "Auth", "via": "reference"],
                     ["line": 1, "did": "deleted", "kind": "reference"]])
        expectEqual(editor.references(on: gateway).count, 0)
        expectEqual(editor.arrowEnds(on: gateway), [])
        editor.undo()
        expectEqual(editor.file, drawn)
    },

    test("and the other way round: the reference for the start is on the end's board, and a run again goes there") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        // Restating Docs puts the run on the root, where the reference for Auth goes, left of Docs.
        let first = try canvas(server, ["draw", "-"], input: """
            sticky-note "Docs"
            edge "Auth" -> "Docs"
            """)
        expectEqual(first.status, 0, first.error)
        expectEqual(editor.arrowEnds(), ["reference to Auth -> Docs"])
        let drawn = editor.file
        // Alone it would draw on Auth's board, the start's, and make a reference for Docs there.
        let again = try canvas(server, ["draw", #"edge "Auth" -> "Docs""#])
        expectEqual(again.status, 0, again.error)
        let json = try JSON(text: again.output)
        expectEqual(json["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"])
        expectEqual(json["on"]?["board"], "root")
        expectEqual(editor.file, drawn)
        expectEqual(editor.references(on: BoardID(owner: wharf.gateway)).count, 0)
    },

    test("a shape the script draws is on the board the run draws on: joined to a public note elsewhere it gets a reference beside it there, and with nothing else to say the edge is straight on that note's board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor, payments = BoardID(owner: wharf.payments), gateway = BoardID(owner: wharf.gateway)
        // Refund goes on Payments' board, and Docs, a public note, is on the root.
        let result = try canvas(server, ["draw", "-"], input: """
            sticky-note "Refund" in "Payments" text: "Money back"
            edge "Refund" -> "Docs"
            """)
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual(json["on"]?["board"], .string(wharf.payments.description))
        expectEqual(editor.references(on: payments).first?.props.target, ReferenceTarget(id: wharf.docs, label: "Docs"))
        expectEqual(editor.arrowEnds(on: payments), ["Refund -> reference to Docs"])
        expectEqual(editor.references().count, 0)
        expectEqual(json["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [])
        // Vault isn't public, so it can't be reached from there: refused, and the user is asked.
        let before = editor.file
        let refused = try canvas(server, ["draw", "-"], input: """
            sticky-note "Chargeback" in "Payments"
            edge "Chargeback" -> "Vault"
            """)
        expectEqual(refused.status, 1)
        let error = try JSON(text: refused.error)["error"]
        expectEqual(error?["reason"], "several_boards")
        expectEqual(error?["message"], #"this script draws on "Payments"'s board (in "Payments", line 1) and on "Gateway"'s board ("Vault")"#)
        expectEqual(error?["hint"], #"an arrow can't leave its board: it goes into a reference standing for the shape on the other board, and only a public shape can be stood for; ask the user to make "Vault" public, or split the script into a run for each board"#)
        expectEqual(editor.file, before)
        // With nothing else to say, the run is on the board of the public note it joins, and the edge is straight.
        let plain = try canvas(server, ["draw", "-"], input: """
            sticky-note "Receipt" text: "Sent"
            edge "Receipt" -> "Auth"
            """)
        expectEqual(plain.status, 0, plain.error)
        expectEqual(try JSON(text: plain.output)["on"]?["board"], .string(wharf.gateway.description))
        expectEqual(editor.arrowEnds(on: gateway), ["Receipt -> Auth"])
        expectEqual(editor.references(on: gateway).count, 0)
    },
])
