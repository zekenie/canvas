import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Schemas
import StickyNotes
import Subboards
import TestKit
import Titles

// `@[Title]` in the text of `canvas draw`: a mention of the shape called Title, kept as the stored
// form with the shape's id, so an agent never handles one. As shipped, through `canvas` as built
// against the command server: notes, subboards and schema cards, a mention of a shape on a board
// two down, of one the script draws further on, a schema card's description that names only schema
// cards, and the run undone.

/// A file: on the root, a note Overview and subboard Plans; on Plans' board, subboard Inner; on
/// Inner's board, a note called Deep note.
@MainActor private struct DeepFile {
    let overview = ShapeID(), plans = ShapeID(), inner = ShapeID(), deep = ShapeID()

    var file: CanvasFile {
        func note(_ id: ShapeID, _ title: String, at x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(x: x, y: 0, width: 200, height: 200), text: MentionText(plain: title))))
            record[TitleProperty.self] = title
            return record
        }
        func subboard(_ id: ShapeID, _ title: String, at x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Subboard(frame: CGRect(x: x, y: 0, width: 240, height: 160))))
            record[TitleProperty.self] = title
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [note(overview, "Overview", at: 0), subboard(plans, "Plans", at: 300)]),
                          children: [plans: CanvasDocument(shapes: [subboard(inner, "Inner", at: 0)]),
                                     inner: CanvasDocument(shapes: [note(deep, "Deep note", at: 0)])])
    }

    /// A board of the file, in a 1440 × 900 window's size, whose document the caller closes.
    func board() -> BoardDocument {
        let board = windowedBoard()
        board.editor.replaceFile(with: file)
        return board
    }
}

extension CanvasEditor {
    /// A note's text, on whatever board it is, as stored.
    fileprivate func stored(of title: String) -> String? {
        shapeInFile(titled: title)?.typed(as: StickyNote.self)?.props.text.stored
    }

    /// The shape of the file called this, on any board.
    fileprivate func shapeInFile(titled title: String) -> AnyShapeRecord? {
        var found: AnyShapeRecord?
        var boards: [BoardID] = [.root]
        while found == nil, let board = boards.popLast() {
            for record in file[board].shapes {
                if registry.title(of: record) == title { found = record }
                if file.children[record.id] != nil { boards.append(BoardID(owner: record.id)) }
            }
        }
        return found
    }
}

@MainActor let drawMentionsTests = Suite("canvas draw: @[Title] in text, as shipped", [
    test("a note mentions a note two boards down by its title: made without an id, its pill live, its mentioners the note; one undo takes the run back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let f = DeepFile()
        let board = f.board()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["draw", #"sticky-note "Reading list" text: "Read @[Deep note] first, and @[Overview], @[Plans]. Not \\@[this].""#])
        expectEqual(result.status, 0, result.error)
        let json = try JSON(text: result.output)
        expectEqual(json["warnings"], [])
        expectEqual(json["on"]?["board"], "root", "the root is shown, and the titles in the text never move the run")
        let plan = try require(board.editor.document.shapes.first { board.editor.registry.title(of: $0) == "Reading list" })
        expectEqual(board.editor.stored(of: "Reading list"),
                    "Read @[Deep note](shape:\(f.deep)) first, and @[Overview](shape:\(f.overview)), @[Plans](shape:\(f.plans)). Not \\@[this].")
        expectEqual(board.editor.mentionPills(of: plan.id).map(\.isLive), [true, true, true])
        expectEqual(board.editor.mentions?.resolve(f.deep).isLive, true)
        expectEqual(board.editor.mentions?.mentioners(of: f.deep), [plan.id])
        expectEqual(board.editor.board, .root)
        // One undo step takes the whole run back, the mention with it; redone, it's as it was.
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expect(board.editor.shapeInFile(titled: "Reading list") == nil)
        expectEqual(board.editor.mentions?.mentioners(of: f.deep), [])
        board.editor.redo()
        expectEqual(board.editor.mentions?.mentioners(of: f.deep), [plan.id])
        expectEqual(board.editor.mentionPills(of: plan.id).map(\.isLive), [true, true, true])
    },

    test("a note mentions a note the same script draws, further down; a title nobody has is refused with the one like it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let result = try canvas(server, ["draw", "-"], input: """
            sticky-note "Plan" text: "After @[Later] comes @[Plan] again"
            sticky-note "Later" right of "Plan" text: "Then this"
            """)
        expectEqual(result.status, 0, result.error)
        let plan = try require(board.editor.shapeInFile(titled: "Plan")), later = try require(board.editor.shapeInFile(titled: "Later"))
        expectEqual(board.editor.stored(of: "Plan"), "After @[Later](shape:\(later.id)) comes @[Plan](shape:\(plan.id)) again")
        expectEqual(board.editor.mentions?.mentioners(of: later.id), [plan.id])
        expectEqual(board.editor.mentionPills(of: plan.id).map(\.isLive), [true, true])
        // Run again, nothing changes: the text it makes is the text the note has.
        let before = board.editor.document
        let again = try canvas(server, ["draw", "-"], input: """
            sticky-note "Plan" text: "After @[Later] comes @[Plan] again"
            sticky-note "Later" right of "Plan" text: "Then this"
            """)
        expectEqual(try JSON(text: again.output)["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(board.editor.document, before)
        let typo = try canvas(server, ["draw", #"sticky-note "Third" text: "see @[Latr]""#])
        expectEqual(typo.status, 1)
        let error = try JSON(text: typo.error)["error"]
        expectEqual(error?["reason"], "unknown_title")
        expectEqual(error?["message"], #""Third": text: there's no shape called "Latr""#)
        expectEqual(error?["hint"], #"did you mean "Later"? to write @[ as text, write \\@["#)
        expectEqual(board.editor.document.shapes.count, 2, "nothing drawn")
    },

    test("a schema card's prompt names schema cards only: the card called Address, not a note called that; any other shape is refused, saying what it is") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let address = scripted(#"{"title": "Address", "type": "object", "properties": {"street": {"type": "string"}}}"#)
        let order = scripted(#"{"title": "Order", "type": "object"}"#)
        expectEqual(try canvas(server, ["draw", #"schema-card schema: "\#(address)""#]).status, 0)
        let card = try require(board.editor.document.shapes.first { $0.typed(as: SchemaCard.self) != nil })
        // A note called the same, put there as a person would (a script can't: its title is taken).
        var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 1000, y: 600, width: 200, height: 200), text: "An address, in words")))
        note[TitleProperty.self] = "Address"
        board.editor.transact { $0.insert(note) }
        // The card is the one the prompt names.
        let result = try canvas(server, ["draw", #"schema-card schema: "\#(order)" prompt: "An order ships to an @[Address]""#])
        expectEqual(result.status, 0, result.error)
        let made = try require(board.editor.document.shapes.first { $0.typed(as: SchemaCard.self) != nil && $0.id != card.id }?.typed(as: SchemaCard.self))
        expectEqual(made.props.prompt.stored, "An order ships to an @[Address](shape:\(card.id))")
        expectEqual(board.editor.mentions?.mentioners(of: card.id), [made.id])
        expectEqual(board.editor.mentions?.mentioners(of: note.id), [])
        // The same script restated says unchanged, though the card is called by its schema's title now.
        let again = try JSON(text: canvas(server, ["draw", #"schema-card "Order" prompt: "An order ships to an @[Address]""#]).output)
        expectEqual(again["changes"]?.arrayValue?.map { $0["did"] }, ["unchanged"])
        // A text that may name any shape can't tell the two Addresses apart.
        let any = try canvas(server, ["draw", #"sticky-note "Plan" text: "see @[Address]""#])
        let ambiguous = try JSON(text: any.error)["error"]
        expectEqual(ambiguous?["reason"], "ambiguous_title")
        expect(ambiguous?["message"]?.stringValue?.hasPrefix(#""Plan": text: the board has 2 shapes called "Address": a "#) == true, "\(any.error)")
        expectEqual(ambiguous?["hint"], "titles name shapes here, so each needs its own: ask the user to rename one", "meant as a mention: no hint about writing the characters")
        // A note is no card, to a text that names cards only.
        expectEqual(try canvas(server, ["draw", #"sticky-note "Ingest" text: "Pull the files""#]).status, 0)
        let refused = try canvas(server, ["draw", #"schema-card prompt: "Fed by @[Ingest]""#])
        expectEqual(refused.status, 1)
        let error = try JSON(text: refused.error)["error"]
        expectEqual(error?["reason"], "invalid_value")
        expectEqual(error?["message"], #"the schema-card on line 1: prompt: "Ingest" is a sticky-note, which this text can't mention: it mentions only schema-card shapes"#)
        expectEqual(error?["hint"], nil, "meant as a mention: no hint about writing the characters")
        // Its text, though, is a note's, which names notes.
        expectEqual(try canvas(server, ["draw", #"sticky-note "Reader" text: "Reads @[Ingest]" right of "Ingest""#]).status, 0)
    },

    test("kinds says a note's text and a schema card's prompt take @[Title], after their type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let kinds = try JSON(text: canvas(server, ["kinds"]).output).arrayValue ?? []
        func attributes(_ kind: String) -> JSON? { kinds.first { $0["kind"]?.stringValue == kind }?["attributes"] }
        expectEqual(attributes("sticky-note")?["text"], "text (@[Title] mentions)")
        expectEqual(attributes("schema-card")?["prompt"], "text (@[Title] mentions)")
        expectEqual(attributes("schema-card")?["schema"], "text")
    },
])
