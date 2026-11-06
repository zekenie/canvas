import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import Foundation
import LanguageModels
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// Deleting a relationship type on the shipped list: through `canvas draw` (what a script's delete takes, refuses and
// leaves), by hand, and cut and pasted.

private let personSchema = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
private let relSchema = scripted(#"{"type": "object", "properties": {"since": {"type": "string"}}}"#)

private func rows(_ result: JSON) -> [JSON] { result["changes"]?.arrayValue ?? [] }

@MainActor private func titled(_ editor: CanvasEditor, _ title: String) -> ShapeID? {
    for document in [editor.file.root] + Array(editor.file.children.values) {
        if let found = document.shapes.first(where: { $0[TitleProperty.self] == title }) { return found.id }
    }
    return nil
}

@MainActor let relationshipDeleteShippedTests = Suite("Deleting a relationship type, on the shipped list", [
    test("canvas draw run on a board that is not shown deletes a relationship type there and draws its notes, and an end drawn on the board shown stays") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        for script in [
            #"subboard "Sub""#,
            "sticky-note \"Employment\" in \"Sub\" relationship: true schema: \"\(relSchema)\"",
            "sticky-note \"Person\" right of \"Sub\" schema: \"\(personSchema)\"",
            #"edge "Person" -> "Employment" text: "employer""#,
        ] {
            let made = try canvas(server, ["draw", script])
            expectEqual(made.status, 0, made.error)
        }
        let employment = try require(titled(editor, "Employment"))
        expect(editor.board == .root && editor.file.board(containing: employment) != .root, "the relationship type is on the subboard's board, the root is shown")
        let arrows = editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(arrows.count, 1, "the end is drawn on the root, into a reference")
        expectEqual(editor.relationships?.endArrows(of: employment), Set(arrows.map(\.id)), "and it is an end of the type")
        let before = editor.file
        // A run on the subboard's board that draws a note there and deletes the relationship type.
        let script = """
        sticky-note "Scratch" in "Sub" text: "drawn in the same run"
        delete "Employment"
        """
        let gone = try canvas(server, ["draw", script])
        let said = gone.status == 0 ? rows(try JSON(text: gone.output)).compactMap { $0["did"]?.stringValue } : []
        let deleted = editor.file.record(employment) == nil
        expectEqual(gone.status, 0, gone.error)
        expectEqual(said, ["created", "deleted"])
        expect(deleted, "a run that says `deleted` deleted the type")
        expect(titled(editor, "Scratch") != nil, "a run that says `created` drew the note")
        expect(editor.file != before)
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.map(\.id), arrows.map(\.id), "the end on the board shown stays")
    },
    test("a script's delete of a relationship type on the board shown takes an end drawn on another board, and one Undo gives it back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        for script in [
            #"subboard "Sub""#,
            "sticky-note \"Employment\" right of \"Sub\" relationship: true schema: \"\(relSchema)\"",
            "sticky-note \"Person\" in \"Sub\" schema: \"\(personSchema)\"",
            #"edge "Person" -> "Employment" text: "employer""#,
        ] {
            let made = try canvas(server, ["draw", script])
            expectEqual(made.status, 0, made.error)
        }
        let employment = try require(titled(editor, "Employment"))
        let ends = try require(editor.relationships?.endArrows(of: employment))
        expectEqual(ends.count, 1)
        expect(ends.allSatisfy { editor.file.board(containing: $0) != .root }, "the end is on the subboard's board")
        let before = editor.file
        let gone = try canvas(server, ["draw", #"delete "Employment""#])
        expectEqual(gone.status, 0, gone.error)
        expect(editor.file.record(employment) == nil)
        expect(ends.allSatisfy { editor.file.record($0) == nil }, "the far end went with it")
        editor.undo()
        expect(editor.file == before, "one Undo")
    },
    test("a script's delete of a relationship type with a locked end arrow is refused and deletes nothing, and by hand the type goes and the locked end stays, orange") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        let made = try canvas(server, ["draw", """
        sticky-note "Person" schema: "\(personSchema)"
        sticky-note "Friendship" right of "Person" relationship: true schema: "\(relSchema)"
        edge "Person" -> "Friendship" text: "friends"
        edge "Friendship" -> "Person" text: "friends"
        """])
        expectEqual(made.status, 0, made.error)
        let friendship = try require(titled(editor, "Friendship"))
        let arrows = editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(arrows.count, 2)
        editor.lock([arrows[0].id])
        let gone = try canvas(server, ["draw", #"delete "Friendship""#])
        expectEqual(gone.status, 1, "refused")
        expect(gone.error.contains("read-only"), gone.error)
        expect(editor.document[friendship] != nil && arrows.allSatisfy { editor.document[$0.id] != nil }, "nothing deleted")
        // By hand, the same board: the type goes and the locked end stays, orange.
        editor.transact("Delete") { $0.delete([friendship]) }
        expect(editor.document[friendship] == nil, "by hand it is not refused")
        expect(editor.document[arrows[0].id] != nil && editor.document[arrows[1].id] == nil)
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: arrows[0].id)?.issues.map(\.message) ?? [], ["This arrow isn’t attached at both ends."])
    },
    test("cutting a relationship type alone deletes its end arrows, and pasting it back brings the type under its id with no ends") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        try m.drag(from: m.feature, to: m.layer)
        editor.closeCard()
        let type = try require(editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        for arrow in m.arrows { editor.transact("Typing") { $0.update(arrow.id, as: Arrow.self) { $0.props.text = MentionText(plain: "named") } } }
        expectEqual(m.arrows.count, 2)
        expectEqual(editor.relationships?.endArrows(of: type).count, 2)
        editor.selectedShapeIDs = [type]
        editor.undoHistory.seal()
        editor.cutSelection()
        let afterCut = m.arrows.count
        editor.paste()
        let back = editor.document[type] != nil
        expectEqual(afterCut, 0, "the cut is a delete: both ends go with the type")
        expectEqual(m.arrows.count, 0, "a paste does not bring them back")
        expect(back, "the type is moved back in under its id")
        expectEqual(editor.relationships?.graph.sides(of: type).from.count, 0, "with no ends")
    },
    test("an end arrow whose two ends are in a locked frame is left when its relationship type outside the frame is deleted") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        try m.drag(from: m.feature, to: m.layer)
        editor.closeCard()
        let type = try require(editor.document.shapes.last { $0[RelationshipProperty.self] == true }).id
        let arrows = m.arrows.map(\.id)
        editor.lock(arrows)
        editor.undoHistory.seal()
        let start = editor.document
        editor.selectedShapeIDs = [type]
        editor.transact("Delete") { $0.delete([type]) }
        expect(editor.document[type] == nil, "not refused")
        expectEqual(m.arrows.map(\.id), arrows, "both locked ends stay")
        editor.undo()
        expectEqual(editor.document, start)
    },
])
