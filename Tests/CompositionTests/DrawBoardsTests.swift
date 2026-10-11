import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Foundation
import HostSlots
import LanguageModels
import Locking
import Mentions
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// `canvas draw` with what main's shipped kinds and boards bring: a run as one undo step, a subboard
// deleted with its board, and type notes (a note drawn with `schema:`), whose sides an agent writes
// without the model being asked.

/// A schema's text as a script's string writes it: each quote escaped.
func scripted(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "\\\"") }

/// A file whose root holds subboard Payments, whose board holds two notes and subboard Refunds,
/// whose board holds one more.
@MainActor private struct PaymentsFile {
    let payments = ShapeID(), refunds = ShapeID(), invoice = ShapeID(), receipt = ShapeID(), chargeback = ShapeID()

    func file(locking locked: ShapeID? = nil) -> CanvasFile {
        func subboard(_ id: ShapeID, _ title: String, at x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Subboard(frame: CGRect(x: x, y: 0, width: 240, height: 160))))
            record[TitleProperty.self] = title
            return record
        }
        func note(_ id: ShapeID, _ text: String, at x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(x: x, y: 0, width: 200, height: 200), text: MentionText(plain: text))))
            if id == locked { record[LockedProperty.self] = true }
            return record
        }
        return CanvasFile(root: CanvasDocument(shapes: [subboard(payments, "Payments", at: 0)]),
                          children: [payments: CanvasDocument(shapes: [note(invoice, "Invoice", at: 0), note(receipt, "Receipt", at: 300),
                                                                       subboard(refunds, "Refunds", at: 600)]),
                                     refunds: CanvasDocument(shapes: [note(chargeback, "Chargeback", at: 0)])])
    }
}

@MainActor let drawBoardsTests = Suite("canvas draw with boards, undo and types", [
    test("a draw is one undo step, Draw: the board is edited, and undone it isn't; a dry run makes none") {
        try configureBoards()
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        expectEqual(try canvas(server, ["draw", "--dry-run", #"sticky-note "Idea" text: "Try a cache""#]).status, 0)
        expect(!board.isDocumentEdited, "a dry run changes nothing")
        expect(!board.editor.canUndo)
        let result = try canvas(server, ["draw", "-"], input: """
            sticky-note "Idea" text: "Try a cache"
            sticky-note "Plan" right of "Idea" text: "Measure first"
            edge "Idea" -> "Plan"
            """)
        expectEqual(result.status, 0, result.error)
        expectEqual(board.editor.document.shapes.count, 3)
        expect(board.isDocumentEdited)
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 0, "one undo takes the whole run back")
        expect(!board.isDocumentEdited)
        expect(!board.editor.canUndo)
        board.editor.redo()
        expectEqual(board.editor.document.shapes.count, 3)
    },
    test("deleting a subboard deletes its board and every board under it, and says so; one holding a locked shape isn't deleted") {
        let f = PaymentsFile()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        editor.replaceFile(with: f.file(locking: f.chargeback))
        let locked = try refusedInProcess(#"delete "Payments""#, on: editor)
        expectEqual(locked.reason, "read_only")
        expectEqual(locked.message, #""Payments" holds a read-only shape (locked, say) on its board, so it can't be deleted"#)
        expectEqual(editor.file.subtree(ownedBy: [f.payments]).count, 2, "nothing went")

        editor.replaceFile(with: f.file())
        let dry = try drawnInProcess(#"delete "Payments""#, on: editor, dryRun: true)
        let said = #""Payments" held a board, and 1 more under it: the 4 shapes on them are deleted with it"#
        expectEqual(dry["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [said], "a dry run says it too")
        let result = try drawnInProcess(#"delete "Payments""#, on: editor)
        expectEqual(result["changes"]?.arrayValue?.map { $0["did"] }, ["deleted"])
        expectEqual(result["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, [said])
        expectEqual(editor.file.record(f.chargeback), nil)
        expectEqual(editor.file.subtree(ownedBy: [f.payments]), [])
        editor.undo()
        expect(editor.file.record(f.chargeback) != nil, "one undo brings the boards back")
    },
    test("a subboard is drawn and named as a note is; inside it places over its card, on the board shown") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let result = try drawnInProcess(#"""
            subboard "Payments" size: 600x400
            sticky-note "Todo" inside "Payments" top-left text: "Refunds"
            """#, on: editor)
        expectEqual(result["changes"]?.arrayValue?.map { $0["did"] }, ["created", "created"])
        let card = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Payments" })
        let todo = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Todo" })
        expect(try require(card.box).contains(try require(todo.box)), "over its card")
        expectEqual(editor.document.shapes.count, 2, "both on the board shown")
        expectEqual(editor.file.subtree(ownedBy: [card.id]), [], "its board holds nothing")
        let renamed = try drawnInProcess(#"subboard "Payments" title: "Billing""#, on: editor)
        expectEqual(renamed["changes"]?.arrayValue?.first?["was"], "Payments")
    },
    test("a type is a note drawn with schema:, named by its title as any note is; a root title in its schema names nothing") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let person = #"{"type": "object", "properties": {"name": {"type": "string"}, "email": {"type": "string"}}}"#
        _ = try drawnInProcess(#"sticky-note "Person" schema: "\#(scripted(person))" text: "A person: name and email""#, on: editor)
        let note = try require(editor.document.shapes.first)
        expectEqual(editor.registry.title(of: note), "Person")
        expectEqual(note[TypeSchemaProperty.self]?.text, person)
        expect(editor.types?.isType(note.id) == true)
        // Restated with another schema, it's the same type; a root "title" in it is the schema's own.
        let titled = #"{"title": "Human", "type": "object", "properties": {"name": {"type": "string"}}}"#
        let updated = try drawnInProcess(#"sticky-note "Person" schema: "\#(scripted(titled))""#, on: editor)
        expectEqual(updated["changes"]?.arrayValue?.first?["did"], "updated")
        expectEqual(editor.registry.title(of: try require(editor.document[note.id])), "Person")
        expectEqual(editor.document[note.id]?[TypeSchemaProperty.self]?.text, titled)
    },
    test("an agent writes a type note's text and schema as they're written: the model isn't asked, where a person's edit asks it") {
        let model = ScriptedLanguageModel(), scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, model: model)
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        let person = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        _ = try drawnInProcess(#"sticky-note "Person" schema: "\#(scripted(person))" text: "A person""#, on: editor)
        let id = try require(editor.document.shapes.first?.id)
        @MainActor func settle() {
            scheduler.advance(by: TypeSync<TypeSchemaProperty>.idleDelay * 2)
            for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
        }
        settle()
        let updated = try drawnInProcess(#"sticky-note "Person" text: "A person, and their email""#, on: editor)
        expectEqual(updated["changes"]?.arrayValue?.first?["did"], "updated")
        settle()
        let email = person.replacingOccurrences(of: #""name": {"type": "string"}"#, with: #""name": {"type": "string"}, "email": {"type": "string"}"#)
        _ = try drawnInProcess(#"sticky-note "Person" schema: "\#(scripted(email))""#, on: editor)
        settle()
        expectEqual(model.requests.count, 0, "what an agent wrote is taken as in step")
        expectEqual(editor.typeSync?.status(of: id), .idle)
        // The person edits the text: that asks the model for the schema.
        editor.transact("Typing") { $0.update(id, as: StickyNote.self) { $0.props.text = "A person, their email and phone" } }
        scheduler.advance(by: TypeSync<TypeSchemaProperty>.idleDelay)
        spinRunLoop(until: { model.requests.count == 1 })
    },
])

/// `draw`, as the app's command server runs it, in this process, on `editor`: a dry run, or not.
@MainActor func drawnInProcess(_ script: String, on editor: CanvasEditor, dryRun: Bool) throws -> JSON {
    let commands = editor.registry.hostCommands
    return try awaitResult { try await commands.run("draw", ["script": .string(script), "dryRun": .bool(dryRun)], editor) }
}
