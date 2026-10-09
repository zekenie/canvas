import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import CoreGraphics
import Foundation
import Mentions
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// `@[Title]` in the text of `canvas draw`: a mention of the shape called Title, kept as the stored
// form with the shape's id, so an agent never handles one. As shipped, through `canvas` as built
// against the command server: notes, subboards and type notes, a mention of a shape on a board two
// down, of one the script draws further on, and the run undone.

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

    test("a note drawn mentioning a shape of every shipped kind is as tall as its editor fits it; with a width alone, that wide and as tall as its text there, in one run") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let order = scripted(#"{"title": "Order", "type": "object"}"#)
        let targets = try canvas(server, ["draw", "-"], input: """
            frame "Sprint" size: 640x300
            subboard "Plans" right of "Sprint"
            sticky-note "Q" right of "Plans"
            sticky-note "Order" below "Sprint" schema: "\(order)"
            """)
        expectEqual(targets.status, 0, targets.error)
        // Each kind's symbol is another width; a short name's pill is the most of it.
        let text = String(repeating: "Read @[Sprint], then @[Plans] and @[Q] or @[Order]; ", count: 6)
        let result = try canvas(server, ["draw", "-"], input: """
            sticky-note "Reading" below "Order" text: "\(text)"
            sticky-note "Wide" right of "Reading" size: 320x text: "\(text)"
            """)
        expectEqual(result.status, 0, result.error)
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        let editor = board.editor
        @MainActor func fitted(_ title: String, width: CGFloat) throws -> CGFloat? {
            let note = try require(editor.shapeInFile(titled: title)?.typed(as: StickyNote.self))
            let frame: JSONValue = [[0, 0], [.number(width), 200]]
            let made: AnyShapeRecord = try editor.registry.shape(StickyNote.kind, properties: ["frame": frame, "text": .string(note.props.text.stored)])
            return made.box?.height
        }
        @MainActor func edited(_ title: String) throws -> CGSize? {
            let id = try require(editor.shapeInFile(titled: title)?.id)
            let before = editor.document[id]
            expect(editor.beginEditing(id))
            _ = try require(editor.makeEditingView())
            defer { editor.endEditing() }
            expectEqual(editor.document[id], before, "\(title): editing grows it no taller")
            return editor.document[id]?.box?.size
        }
        let reading = try require(editor.shapeInFile(titled: "Reading"))
        expectEqual(editor.mentionPills(of: reading.id).count, 24)
        expect(editor.mentionPills(of: reading.id).allSatisfy(\.isLive))
        let height = try require(reading.box?.height)
        expect(height > 200, "\(height)")
        expectEqual(try edited("Reading"), CGSize(width: 200, height: height))
        let wide = try require(edited("Wide"))
        expectEqual(wide.width, 320)
        expectEqual(wide.height, try fitted("Wide", width: 320))
        expect(wide.height < height, "fewer lines, wider")
        // Restated with a width alone, it's fitted there; one undo takes it back.
        expectEqual(try canvas(server, ["draw", #"sticky-note "Wide" size: 480x"#]).status, 0)
        let wider = try require(edited("Wide"))
        expectEqual(wider.width, 480)
        expectEqual(wider.height, try fitted("Wide", width: 480))
        editor.undo()
        expectEqual(editor.shapeInFile(titled: "Wide")?.box?.size, wide)
    },

    test("kinds says a note's text takes @[Title], after its type, and its schema is text") {
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
        expectEqual(attributes("sticky-note")?["schema"], "text")
    },
])
