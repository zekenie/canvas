import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import Colors
import Foundation
import Publishing
import TestKit
import Titles
import Types

// Types through `canvas` as built, over a socket of its own: a type is drawn with a schema, not public;
// an instance names it by its title, in one undo step; queries find the instances by their types.

@MainActor let drawTypesTests = Suite("Types, drawn and queried through canvas", [
    test("a note drawn with a schema is a type, not public; sticky-note \"Ann\" is: \"Person\" makes an instance of it, one undo step; the queries find it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let person = scripted(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        let made = try canvas(server, ["draw", #"sticky-note "Person" text: "A person: their name" schema: "\#(person)""#])
        expectEqual(made.status, 0, made.error)
        let type = try require(board.editor.document.shapes.first)
        expectEqual(type[PrivateProperty.self], nil, "a type draw makes is public, as every shape is")
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        board.editor.undo()
        expectEqual(board.editor.document.shapes.count, 0, "one step takes the type back")
        board.editor.redo()

        let steps = board.editor.undoHistory.undoName
        let drawn = try canvas(server, ["draw", #"sticky-note "Ann" is: "Person""#])
        expectEqual(drawn.status, 0, drawn.error)
        let ann = try require(board.editor.document.shapes.first { $0.id != type.id })
        expectEqual(ann[IsAProperty.self]?.map(\.shape), [type.id])
        expect(board.editor.undoHistory.undoName != nil && steps != nil)
        board.editor.undo()
        expectEqual(board.editor.document.shapes.map(\.id), [type.id], "one step takes the instance back")
        board.editor.redo()

        for (query, count) in [(#":is-a("Person")"#, 1), (#":edge-to("Person", is-a)"#, 1), (#"[is~="Person"]"#, 1), ("sticky-note[schema]", 1)] {
            let found = try JSON(text: canvas(server, ["query", "--brief", query]).output)
            expectEqual(found["count"], .number(Double(count)), query)
        }
        let rows = try JSON(text: canvas(server, ["query", "--fields", "is", #"sticky-note"Ann""#]).output)
        expectEqual(rows["rows"]?.arrayValue?.first?["properties"]?["is"], .array([.string("Person")]), "the entries read as titles")

        // A note that is no type is refused, saying so; nothing is drawn.
        let plain = try canvas(server, ["draw", #"sticky-note "Plain""#])
        expectEqual(plain.status, 0, plain.error)
        let refused = try canvas(server, ["draw", #"sticky-note "Bob" is: "Plain""#])
        expect(refused.status != 0)
        expect(refused.error.contains("isn't a type or a shape"), refused.error)
    },

    test("a type drawn with a color has it in its JSON; drawn again it is unchanged; a schema: that says none keeps the color given since, one that says one gives it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let schema = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        let script = #"sticky-note "Person" schema: "\#(scripted(schema))" color: blue"#
        let made = try canvas(server, ["draw", script])
        expectEqual(made.status, 0, made.error)
        let type = try require(board.editor.document.shapes.first).id
        @MainActor func held() -> (color: ShapeColor?, said: TypeColorDirective.Reading?) {
            let record = board.editor.document[type]
            return (record?.ownColor, record?[TypeSchemaProperty.self].flatMap { TypeColorDirective.reading(of: $0.text) })
        }
        expectEqual(held().color, .blue)
        expectEqual(held().said, .color(.blue), "its JSON says it")
        let revision = board.editor.revision
        let again = try canvas(server, ["draw", script])
        expectEqual(again.status, 0, again.error)
        expectEqual(board.editor.revision, revision, "drawn again, unchanged")
        board.editor.setColor(.teal, of: [type])
        let restated = try canvas(server, ["draw", #"sticky-note "Person" schema: "\#(scripted(schema))""#])
        expectEqual(restated.status, 0, restated.error)
        expectEqual(held().color, .teal, "a schema that says no color keeps the one given since")
        expectEqual(held().said, .color(.teal))
        let red = try require(TypeColorDirective.text(schema, saying: .red))
        let said = try canvas(server, ["draw", #"sticky-note "Person" schema: "\#(scripted(red))""#])
        expectEqual(said.status, 0, said.error)
        expectEqual(held().color, .red, "one that says one gives it")
    },
    test("a type drawn with private: true is private, and a type; the queries find it as either") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let made = try canvas(server, ["draw", #"sticky-note "Open" schema: "{\"type\": \"object\"}" private: true"#])
        expectEqual(made.status, 0, made.error)
        let type = try require(board.editor.document.shapes.first)
        expectEqual(type[PrivateProperty.self], true)
        expect(board.editor.types?.isType(type.id) == true)
        let found = try JSON(text: canvas(server, ["query", "--brief", "sticky-note[schema][private]"]).output)
        expectEqual(found["count"], 1)
    },

    test("a note drawn with fieldValues holds them without the empty ones, in one step; a wrong shape is refused; queries read it by path") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let drawn = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: {"status": "paid", "note": ""}"#])
        expectEqual(drawn.status, 0, drawn.error)
        expectEqual(board.editor.undoHistory.undoName, "Draw")
        let order = try require(board.editor.document.shapes.first)
        expectEqual(order[FieldValuesProperty.self], FieldValues(["status": "paid"]), "the empty note is not kept")
        let rows = try JSON(text: canvas(server, ["query", "--fields", "fieldValues", #"sticky-note"Order 12""#]).output)
        expectEqual(rows["rows"]?.arrayValue?.first?["properties"]?["fieldValues"], .object(["status": .string("paid")]))
        for (query, count) in [(#"[fieldValues.status="paid"]"#, 1), (#"[fieldValues.status="due"]"#, 0)] {
            let found = try JSON(text: canvas(server, ["query", "--brief", query]).output)
            expectEqual(found["count"], .number(Double(count)), query)
        }
        let kinds = try JSON(text: canvas(server, ["kinds", "sticky-note"]).output)
        expect(String(describing: kinds).contains("fieldValues"), "canvas kinds lists it among a note's attributes")
        for wrong in ["5", #""paid""#] {
            let refused = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: \#(wrong)"#])
            expect(refused.status != 0, "fieldValues: \(wrong)")
            expectEqual(board.editor.document.shapes.first?[FieldValuesProperty.self], FieldValues(["status": "paid"]), "nothing changed")
        }
        let emptied = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: {"status": ""}"#])
        expectEqual(emptied.status, 0, emptied.error)
        expectEqual(board.editor.document.shapes.first?[FieldValuesProperty.self], nil, "only empties leave none")
        let filled = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: {"status": "paid"}"#])
        expectEqual(filled.status, 0, filled.error)
        // A statement names only what it changes: the rest stays, and null inside clears one member.
        let more = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: {"other": "x"}"#])
        expectEqual(more.status, 0, more.error)
        expectEqual(board.editor.document.shapes.first?[FieldValuesProperty.self], FieldValues(["status": "paid", "other": "x"]), "keeps what it doesn't name")
        let cleared = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: {"status": null}"#])
        expectEqual(cleared.status, 0, cleared.error)
        expectEqual(board.editor.document.shapes.first?[FieldValuesProperty.self], FieldValues(["other": "x"]), "null clears the member it is written at")
        let restored = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: {"status": "paid"}"#])
        expectEqual(restored.status, 0, restored.error)
        let taken = try canvas(server, ["draw", #"sticky-note "Order 12" fieldValues: null"#])
        expectEqual(taken.status, 0, taken.error)
        expectEqual(board.editor.document.shapes.first?[FieldValuesProperty.self], nil, "null takes every value off")
        let edge = try canvas(server, ["draw", """
        sticky-note "A" below "Order 12"
        sticky-note "B" right of "A"
        edge "A" -> "B" fieldValues: {"since": "2024"}
        """])
        expectEqual(edge.status, 0, edge.error)
        let arrow = try require(board.editor.document.shapes.first { $0.kind.rawValue == "arrow" })
        expectEqual(arrow[FieldValuesProperty.self], FieldValues(["since": "2024"]), "an edge takes it too")
    },

    test("a draw's warnings hold a wrong value of a note, for a type on the board and for one drawn in the same script; a needed field is no warning") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let thing = scripted(#"{"type": "object", "properties": {"count": {"type": "integer", "minimum": 1}, "label": {"type": "string"}}, "required": ["label"]}"#)
        // The type and its instance together: the type isn't on the board yet.
        let together = try canvas(server, ["draw", """
        sticky-note "Thing" schema: "\(thing)"
        sticky-note "T1" below "Thing" is: "Thing" fieldValues: {"count": 0}
        """])
        expectEqual(together.status, 0, together.error)
        let warnings = try require(JSON(text: together.output)["warnings"]?.arrayValue)
        let messages = warnings.compactMap { $0["message"]?.stringValue }
        expect(messages.contains { $0.contains("\"T1\"") && $0.contains("count") && $0.contains("at least 1") }, "the wrong count: \(messages)")
        expect(!messages.contains { $0.contains("label") }, "label is needed, and needed is no warning: \(messages)")
        expectEqual(warnings.first { $0["message"]?.stringValue?.contains("count") == true }?["severity"], "error")
        // The type now on the board.
        let later = try canvas(server, ["draw", #"sticky-note "T2" right of "Thing" is: "Thing" fieldValues: {"count": 0, "label": "x"}"#])
        expectEqual(later.status, 0, later.error)
        let laterMessages = try require(JSON(text: later.output)["warnings"]?.arrayValue).compactMap { $0["message"]?.stringValue }
        expect(laterMessages.contains { $0.contains("at least 1") }, "\(laterMessages)")
        let fine = try canvas(server, ["draw", #"sticky-note "T3" right of "T2" is: "Thing" fieldValues: {"count": 2, "label": "x"}"#])
        expectEqual(fine.status, 0, fine.error)
        let fineMessages = try JSON(text: fine.output)["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? []
        expect(!fineMessages.contains { $0.contains("least") }, "a right value is no warning: \(fineMessages)")
    },

    test("a draw onto a note whose card is open is a step of its own: Undo takes back Draw alone, then the card's change") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        let order = scripted(#"{"type": "object", "properties": {"shipping": {"type": "object", "properties": {"street": {"type": "string"}, "city": {"type": "string"}}}}}"#)
        let made = try canvas(server, ["draw", """
        sticky-note "Order" schema: "\(order)"
        sticky-note "O1" below "Order" is: "Order"
        """])
        expectEqual(made.status, 0, made.error)
        let note = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "O1" }).id
        let opened = try require(editor.fieldCards).open(FieldCardRequest(shape: note, target: .field(FieldPath(field: "shipping")), mode: .values, isReadOnly: false,
                                                                            rowRect: CGRect(x: 60, y: 60, width: 140, height: 22), closed: {}, tabbedOut: { _ in }))
        expect(opened, "the card opens on the group's row")
        let city = FieldPath(field: "shipping").key("city")
        expect(try require(editor.fieldWriter).set("Leeds", at: city, of: note), "a value changed in the card")
        let cardStep = try require(editor.undoHistory.undoName)
        let drawn = try canvas(server, ["draw", #"sticky-note "O1" fieldValues: {"shipping": {"street": "High St"}}"#])
        expectEqual(drawn.status, 0, drawn.error)
        expectEqual(editor.undoHistory.undoName, "Draw")
        expectEqual(editor.document[note]?[FieldValuesProperty.self], FieldValues(["shipping": ["city": "Leeds", "street": "High St"]]), "joined with what the card wrote")
        editor.undo()
        expectEqual(editor.document[note]?[FieldValuesProperty.self], FieldValues(["shipping": ["city": "Leeds"]]), "Undo takes back Draw alone")
        expectEqual(editor.undoHistory.undoName, cardStep, "the card's change is a step of its own")
        editor.undo()
        expectEqual(editor.document[note]?[FieldValuesProperty.self], nil)
    },

    test("an edge takes is: too: edge \"A\" -> \"B\" is: \"Friendship\" is an arrow that is a Friendship") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let drawn = try canvas(server, ["draw", """
        sticky-note "Friendship" schema: "{\\"type\\": \\"object\\"}"
        sticky-note "A" below "Friendship"
        sticky-note "B" right of "A"
        edge "A" -> "B" is: "Friendship"
        """])
        expectEqual(drawn.status, 0, drawn.error)
        let friendship = try require(board.editor.document.shapes.first { board.editor.registry.title(of: $0) == "Friendship" })
        let arrow = try require(board.editor.document.shapes.first { $0.kind.rawValue == "arrow" })
        expectEqual(arrow[IsAProperty.self]?.map(\.shape), [friendship.id])
        let found = try JSON(text: canvas(server, ["query", "--brief", #"arrow:is-a("Friendship")"#]).output)
        expectEqual(found["count"], 1)
    },

    test("two arrows of one pair are two edges told apart by is:: each restated unchanged, a bare edge ambiguous, delete edge ... is: takes one") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        func dids(_ output: String) throws -> [String] {
            try JSON(text: output)["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? []
        }
        @MainActor func arrows(_ type: String? = nil) throws -> Int {
            try JSON(text: canvas(server, ["query", "--brief", type.map { #"arrow:is-a("\#($0)")"# } ?? "arrow"]).output)["count"]?.numberValue.map(Int.init) ?? -1
        }
        let setup = try canvas(server, ["draw", """
        sticky-note "Friendship" schema: "{\\"type\\": \\"object\\"}"
        sticky-note "Mentorship" right of "Friendship" schema: "{\\"type\\": \\"object\\"}"
        sticky-note "Ann" below "Friendship"
        sticky-note "Bo" right of "Ann"
        """])
        expectEqual(setup.status, 0, setup.error)
        let two = """
        edge "Ann" -> "Bo" is: "Friendship"
        edge "Ann" -> "Bo" is: "Mentorship"
        """
        let first = try canvas(server, ["draw", two])
        expectEqual(first.status, 0, first.error)
        expectEqual(try dids(first.output), ["connected", "connected"])
        expectEqual(try arrows(), 2)
        let again = try canvas(server, ["draw", two])
        expectEqual(try dids(again.output), ["unchanged", "unchanged"])
        let bare = try canvas(server, ["draw", #"edge "Ann" -> "Bo""#])
        expect(bare.status != 0)
        expect(bare.error.contains("ambiguous_edge") && bare.error.contains("write is: to say which"), bare.error)
        let removed = try canvas(server, ["draw", #"delete edge "Ann" -> "Bo" is: "Friendship""#])
        expectEqual(removed.status, 0, removed.error)
        expectEqual(try dids(removed.output), ["deleted"])
        expectEqual(try arrows("Friendship"), 0)
        expectEqual(try arrows("Mentorship"), 1)
        let other = try canvas(server, ["draw", #"delete edge "Ann" -> "Bo" text: "x""#])
        expect(other.status != 0 && other.error.contains("delete edge takes is: and no other attribute"), other.error)
    },
])
