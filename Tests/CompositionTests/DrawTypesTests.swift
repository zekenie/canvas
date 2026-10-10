import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
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
        expectEqual(type[PublicProperty.self], nil, "a type draw makes does not start public")
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

    test("a type drawn with public: true is public, and a type; the queries find it as either") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let made = try canvas(server, ["draw", #"sticky-note "Open" schema: "{\"type\": \"object\"}" public: true"#])
        expectEqual(made.status, 0, made.error)
        let type = try require(board.editor.document.shapes.first)
        expectEqual(type[PublicProperty.self], true)
        expect(board.editor.types?.isType(type.id) == true)
        let found = try JSON(text: canvas(server, ["query", "--brief", "sticky-note[schema][public]"]).output)
        expectEqual(found["count"], 1)
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
])
