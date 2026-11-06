import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Chrome
import Connections
import CoreGraphics
import Foundation
import Frames
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
// its `via`); either way round; `share:` between several notes' edges to one; `via: reference` on one board; a run again; `delete edge`, and
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
        // Auth's title is its alone, and its reference still says where Auth is, over its name: every pill does.
        _ = renderBitmap(editor, size: CGSize(width: 1440, height: 900))
        let place = try require(editor.service(ReferenceState.self)?.drawnPlaceSteps(of: pill.id))
        expectEqual(place.map(\.name), ["Payments", "Gateway"])
        expectEqual(pill.props.frame.width, ReferenceEdits.width(of: pill.props, place: place), "fitted to its label and its place")
        expectEqual(pill.props.frame.height, 40, "a pill is 40 tall")
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

    test("canvas kinds says a reference can stand for a note, a subboard or a frame once it's public, and for no pill or arrow") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = Wharf().board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["kinds"])
        expectEqual(result.status, 0, result.error)
        let kinds = try JSON(text: result.output)
        func via(_ kind: String) -> JSON? { kinds.arrayValue?.first { $0["kind"]?.stringValue == kind }?["via"] }
        for kind in ["sticky-note", "subboard", "frame"] {
            expectEqual(via(kind), [["kind": "reference", "needs": "public"]], kind)
        }
        expectEqual(via("reference"), nil, "a pill stands for no pill")
        expectEqual(via("arrow"), nil, "an arrow is never public")
    },
    test("a public note whose title another note has, or has not: its reference says where it is over the name and is as wide as that, which measure says too") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let editor = board.editor
        var other = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 1100, y: 100, width: 200, height: 200), text: MentionText(plain: "Auth"))))
        other[TitleProperty.self] = "Auth"
        editor.transact { $0.insert(other) }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let edge = #"edge "Checkout" -> "Payments" > "Gateway" > "Auth""#
        let result = try canvas(server, ["draw", edge])
        expectEqual(result.status, 0, result.error)
        let pill = try require(editor.references().first)
        expectEqual(pill.props.target, ReferenceTarget(id: wharf.auth, label: "Auth"))
        _ = renderBitmap(editor, size: CGSize(width: 1440, height: 900))
        let references = try require(editor.service(ReferenceState.self))
        let place = try require(references.drawnPlaceSteps(of: pill.id))
        expectEqual(place.map(\.name), ["Payments", "Gateway"])
        expectEqual(pill.props.frame.width, ReferenceEdits.width(of: pill.props, place: place), "fitted to where Auth is, from the root")
        expect(pill.props.frame.width > ReferenceEdits.width(of: pill.props), "wider than its name")
        let checkout = try require(editor.file.record(wharf.checkout)?.box)
        expectEqual(pill.frame.minX, checkout.maxX + 80, "right of Checkout, as any")
        expectEqual(references.drawnPlace(of: pill.id)?.text, "Payments › Gateway", "what it was fitted for is what it says")
        let measured = try canvas(server, ["measure", "-"], input: edge + " via: reference\n")
        expectEqual(measured.status, 0, measured.error)
        let size = try JSON(text: measured.output)["references"]?.arrayValue?.first?["size"]?.arrayValue?.compactMap(\.numberValue)
        expectEqual(size, [Double(pill.props.frame.width), Double(pill.props.frame.height)], "measure says the size draw made")
        // With the title Auth's alone again, a reference to it says where Auth is as well, and is as wide as that.
        editor.transact { $0.delete([other.id]) }
        _ = try canvas(server, ["draw", #"edge "Ledger" -> "Auth""#])
        let plain = try require(editor.references().first { $0.id != pill.id })
        expectEqual(plain.props.frame.width, pill.props.frame.width, "as wide as the one for the same place, whether the title is its alone or not")
        expect(plain.props.frame.width > ReferenceEdits.width(of: plain.props), "wider than its name")
    },
    test("the references beside a note are a column of their own, 16 apart; a later run's joins it, 16 below its end, in line with it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let wharf = Wharf()
        let board = wharf.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let both = try canvas(server, ["draw", "-"], input: """
            edge "Checkout" -> "Auth"
            edge "Checkout" -> "Docs" via: reference
            """)
        expectEqual(both.status, 0, both.error)
        let editor = board.editor
        let checkout = try require(editor.file.record(wharf.checkout)?.box)
        expectEqual(editor.references().map(\.frame.minX), [checkout.maxX + 80, checkout.maxX + 80], "in line, right of Checkout")
        expectEqual(editor.references().map(\.frame.minY), [checkout.midY - 48, checkout.midY + 8], "40 tall, 16 apart, centered on it as one")
        expectEqual(try JSON(text: both.output)["changes"]?.arrayValue?.compactMap { $0["pushedPast"] }, [])
        editor.undo()
        expectEqual(editor.references().count, 0)
        _ = try canvas(server, ["draw", #"edge "Checkout" -> "Auth""#])
        let later = try canvas(server, ["draw", #"edge "Checkout" -> "Docs" via: reference"#])
        expectEqual(later.status, 0, later.error)
        let pills = editor.references().map(\.frame)
        expectEqual(pills.map(\.minY), [checkout.midY - 20, checkout.midY + 36], "the first where it was, the next 16 below it")
        expectEqual(pills.map(\.minX), [checkout.maxX + 80, checkout.maxX + 80])
        expectEqual(try JSON(text: later.output)["warnings"]?.arrayValue ?? [], [])
    },

    test("share: three notes joined to Auth have one reference between them, and a query reads each as into Auth; deleting an edge keeps it till the last") {
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
        // A host that has no reference yet is refused, naming it and the end, and nothing is drawn.
        let early = try canvas(server, ["draw", "-"], input: """
            edge "Docs" -> "Auth" share: "Ledger"
            edge "Ledger" -> "Auth"
            """)
        expectEqual(early.status, 1)
        let refusal = try JSON(text: early.error)["error"]
        expectEqual(refusal?["reason"], "invalid_value")
        expectEqual(refusal?["message"], #"edge "Docs" -> "Auth": share: "Ledger" has no reference to "Auth" beside it"#)
        expectEqual(refusal?["line"], 1)
        expectEqual(editor.file, before)
        let result = try canvas(server, ["draw", "-"], input: """
            edge "Checkout" -> "Auth"
            edge "Ledger" -> "Auth" share: true
            edge "Docs" -> "Auth" share: "Checkout"
            """)
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        let pill = try require(editor.references().first)
        expectEqual(editor.references().count, 1)
        expectEqual(editor.arrowEnds(), ["Checkout -> reference to Auth", "Ledger -> reference to Auth", "Docs -> reference to Auth"])
        expectEqual(json["changes"]?.arrayValue?.map { $0["did"] }, ["created", "connected", "connected", "connected"])
        expectEqual(json["changes"]?.arrayValue?.map { $0["shared"] }, [nil, nil, true, true])
        expectEqual(json["changes"]?.arrayValue?.map { $0["sharedWith"] }, [nil, nil, nil, "Checkout"])
        expectEqual(json["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [])
        let asked = try canvas(server, ["query", #"sticky-note:edge-to("Auth")"#, "--brief", "--board", "\(board.number)"])
        expectEqual(Set(try require(JSON(text: asked.output)["rows"]?.arrayValue).compactMap { $0["title"]?.stringValue }), ["Checkout", "Ledger", "Docs"])
        expectEqual(editor.topology?.standIns(for: wharf.auth), [pill.id])
        // A run again: nothing changes, and each row says what it said.
        let file = editor.file
        let again = try canvas(server, ["draw", "-"], input: """
            edge "Checkout" -> "Auth"
            edge "Ledger" -> "Auth" share: true
            edge "Docs" -> "Auth" share: "Checkout"
            """)
        expectEqual(try JSON(text: again.output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(try JSON(text: again.output)["changes"]?.arrayValue?.map { $0["shared"] }, [nil, true, true])
        expectEqual(editor.file, file)
        // The pill goes with the last arrow, not before.
        _ = try canvas(server, ["draw", #"delete edge "Checkout" -> "Auth""#])
        _ = try canvas(server, ["draw", #"delete "Ledger""#])
        expectEqual(editor.references().count, 1)
        expectEqual(editor.arrowEnds(), ["Docs -> reference to Auth"])
        let last = try canvas(server, ["draw", #"delete edge "Docs" -> "Auth""#])
        expectEqual(try JSON(text: last.output)["changes"]?.arrayValue?.map { $0["kind"] }, ["arrow", "reference"])
        expectEqual(editor.references().count, 0)
        editor.undo()
        expectEqual(editor.references().count, 1)
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

    test("a column of references beside a card clears itself: each pill a pill's height and the gap below the one above, however many, and kept together over a frame's edge") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        let names = ["Auth", "Billing", "Catalog", "Search", "Mail", "Queue", "Cache", "Logging", "Metrics", "Storage", "Payments", "Reports"]
        for frames in ["frame \"Library\" size: 2600x200\nframe \"Work\" below \"Library\" size: 1500x1100\n"] {
            expectEqual(try canvas(server, ["draw", "-"], input: frames).status, 0)
        }
        var notes = ""
        for (n, name) in names.enumerated() { notes += "sticky-note \"\(name)\" in \"Library\" public: true size: 120x70 \(n == 0 ? "" : "right of \"\(names[n - 1])\"")\n" }
        let placed = try canvas(server, ["draw", "-"], input: notes)
        expectEqual(placed.status, 0, placed.error)
        let made = try canvas(server, ["draw", "-"], input: "subboard \"Checkout\" in \"Work\" inside \"Work\" left size: 170x80\nsubboard \"Top\" in \"Work\" size: 170x80\n")
        expectEqual(made.status, 0, made.error)
        let edges = try canvas(server, ["draw", "-"], input: names.prefix(8).map { "edge \"Checkout\" -> \"\($0)\" via: reference" }.joined(separator: "\n")
                               + "\n" + names.prefix(4).map { "edge \"Top\" -> \"\($0)\" via: reference" }.joined(separator: "\n"))
        expectEqual(edges.status, 0, edges.error)
        let pills = editor.references().map(\.frame)
        expectEqual(pills.count, 12)
        expect(pills.allSatisfy { $0.height == 40 }, "a pill is 40 tall")
        for (a, b) in pills.enumerated().flatMap({ a in pills.enumerated().filter { $0.offset > a.offset }.map { (a.element, $0.element) } }) {
            expect(!a.intersects(b), "\(a) and \(b) overlap")
        }
        // A column's pills are a pill's height and the gap apart, one after another: each is 16 clear below the one above, and the
        // column is the card's own, which the frame's top, over the first pill, leaves whole.
        for column in [Array(pills.prefix(8)), Array(pills.suffix(4))] {
            let ordered = column.sorted { $0.minY < $1.minY }
            for (above, below) in zip(ordered, ordered.dropFirst()) { expectEqual(below.minY, above.maxY + 16, "16 below the pill above") }
        }
        let work = try require(editor.contents(of: .root).shapes.first { $0.kind == Frame.kind && editor.registry.title(of: $0) == "Work" }?.box)
        expect(pills.suffix(4).allSatisfy { work.contains($0) }, "the column beside a card at the top of a frame goes in the frame, whole")
    },

    test("two cards of one title in two frames: each one's references are a column of its own, settled in its own frame") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        let frames = try canvas(server, ["draw", "-"], input: "frame \"Library\" size: 1200x200\nframe \"web\" below \"Library\" size: 700x500\n"
                                + "frame \"api\" right of \"web\" size: 700x500\n")
        expectEqual(frames.status, 0, frames.error)
        let notes = try canvas(server, ["draw", "-"], input: "sticky-note \"Auth\" in \"Library\" public: true size: 120x70\n"
                               + "sticky-note \"Billing\" in \"Library\" public: true size: 120x70 right of \"Auth\"\n")
        expectEqual(notes.status, 0, notes.error)
        let cards = try canvas(server, ["draw", "-"], input: "subboard \"index.ts\" in \"web\" size: 170x80\nsubboard \"index.ts\" in \"api\" size: 170x80\n")
        expectEqual(cards.status, 0, cards.error)
        // One run: the pills beside the two index.ts are placed by clauses that read alike, and are two columns all the same.
        let edges = ["web", "api"].flatMap { frame in ["Auth", "Billing"].map { "edge \"\(frame)\" > \"index.ts\" -> \"\($0)\" via: reference" } }
        let drew = try canvas(server, ["draw", "-"], input: edges.joined(separator: "\n"))
        expectEqual(drew.status, 0, drew.error)
        let pills = editor.references().map(\.frame)
        expectEqual(pills.count, 4)
        @MainActor func frame(_ title: String) throws -> CGRect {
            try require(editor.contents(of: .root).shapes.first { $0.kind == Frame.kind && editor.registry.title(of: $0) == title }?.box)
        }
        let web = try frame("web"), api = try frame("api")
        expectEqual(pills.filter { web.contains($0) }.count, 2, "web's index.ts has its two, in web")
        expectEqual(pills.filter { api.contains($0) }.count, 2, "api's has its two, in api")
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
