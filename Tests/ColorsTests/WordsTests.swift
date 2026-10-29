import Canvas
import CanvasRPC
import CanvasTesting
import Colors
import CoreGraphics
import Draw
import Foundation
import Topology
import Palette
import Queries
import TestKit

// Colors in `canvas draw` and `canvas query`, on the tests' own kinds: a sheet and a pane have
// colors, a card has none.

/// A harness with the draw and query engines and what Colors gives them.
@MainActor private func wordsHarness(file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    try colorHarness([TopologyPlugin(), CardsPlugin(), DrawPlugin(), QueriesPlugin(), ColorNamesPlugin(), ColorQueriesPlugin()], file: file)
}

@MainActor private func colorDrawn(_ script: String, on h: EditorHarness, dryRun: Bool = false) throws -> JSON {
    try JSON(encoding: draw(script: script, dryRun: dryRun, reveal: false, program: RPC.commandName, in: h.editor))
}

/// A refusal's fields and message.
@MainActor private func colorRefused(_ script: String, on h: EditorHarness) throws -> DrawError {
    do throws(DrawError) {
        _ = try draw(script: script, dryRun: false, reveal: false, program: RPC.commandName, in: h.editor)
    } catch {
        return error
    }
    throw Unexpected()
}

private struct Unexpected: Error {}

/// The own colors of the shapes of a kind on the board, by x.
@MainActor private func colors(of kind: ShapeKind, in h: EditorHarness) -> [ShapeColor?] {
    h.editor.document.shapes.filter { $0.kind == kind }.map(\.ownColor)
}

@MainActor let colorDrawTests = Suite("Colors in canvas draw", [
    test("a name is kept in its list's spelling, a hex value as #RRGGBB, in either case or length") {
        let h = try wordsHarness()
        _ = try colorDrawn("sheet color: blue", on: h)
        _ = try colorDrawn("sheet color: BLUE", on: h)
        _ = try colorDrawn(##"sheet color: "  Blue ""##, on: h)
        _ = try colorDrawn(##"sheet color: "#46e""##, on: h)
        _ = try colorDrawn(##"sheet color: "#4465e9""##, on: h)
        _ = try colorDrawn(##"pane color: "#4465E9""##, on: h)
        expectEqual(colors(of: Sheet.kind, in: h), [.blue, .blue, .blue, .value(RGB(hex: 0x4466EE)), .value(RGB(hex: 0x4465E9))])
        expectEqual(colors(of: Pane.kind, in: h), [.value(RGB(hex: 0x4465E9))])
        let stored = h.editor.document.shapes.compactMap { $0.propertiesJSON?["color"] }
        expectEqual(stored, ["blue", "blue", "blue", "#4466EE", "#4465E9", "#4465E9"])
    },
    test("a name the file lacks is refused on its line, saying it isn't a color and which there are") {
        let h = try wordsHarness()
        let error = try colorRefused("sheet color: blue\nsheet color: brand", on: h)
        expectEqual(error.reason, "invalid_value")
        expectEqual(error.line, 2)
        expectEqual(error.statement, "sheet color: brand")
        expect(error.message.contains(##""brand" isn't a color"##), error.message)
        expect(error.message.contains("gray, red, orange, yellow, green, teal, blue, indigo, purple, pink"), error.message)
        expect(error.message.contains("#RRGGBB"), error.message)
        expectEqual(h.editor.document.shapes.count, 0, "a refused script draws nothing")
    },
    test("a #… that isn't a hex value is refused") {
        let h = try wordsHarness()
        for bad in ["#12", "#GGGGGG", "#4465E9FF", "#"] {
            let error = try colorRefused(##"sheet color: "\##(bad)""##, on: h)
            expectEqual(error.reason, "invalid_value", bad)
            expectEqual(error.line, 1, bad)
            expect(error.message.contains(bad), error.message)
        }
        expectEqual(h.editor.document.shapes.count, 0)
    },
    test("a kind with no colors takes no color: attribute, as draw says of any unknown one") {
        let h = try wordsHarness()
        let error = try colorRefused("card color: blue", on: h)
        let other = try colorRefused("card tint: blue", on: h)
        expectEqual(error.reason, other.reason)
        expect(error.message.contains("color"), error.message)
        expectEqual(h.editor.document.shapes.count, 0)
    },
    test("a dry run reports what a run does and writes nothing; a run is one undo step") {
        let h = try wordsHarness()
        let dry = try colorDrawn("sheet color: Teal", on: h, dryRun: true)
        expectEqual(h.editor.document.shapes.count, 0)
        let real = try colorDrawn("sheet color: Teal", on: h)
        expectEqual(dry["changes"]?.arrayValue?.count, real["changes"]?.arrayValue?.count)
        expectEqual(colors(of: Sheet.kind, in: h), [.teal])
        let before = h.editor.undoHistory.undoName
        _ = try colorDrawn("sheet color: red\nsheet color: pink below board\npane color: green below board", on: h)
        expectEqual(h.editor.document.shapes.count, 4)
        h.editor.undo()
        expectEqual(h.editor.document.shapes.count, 1, "the three shapes of the script are one step")
        expectEqual(h.editor.undoHistory.undoName, before)
        expectEqual(colors(of: Sheet.kind, in: h), [.teal])
    },
    test("canvas kinds shows the attribute with its description, on the kinds that have colors") {
        let h = try wordsHarness()
        let listed = try JSON(encoding: kinds(named: nil, in: h.editor.registry)).arrayValue ?? []
        func attribute(_ kind: ShapeKind) -> JSON? { listed.first { $0["kind"]?.stringValue == kind.rawValue }?["attributes"]?["color"] }
        expectEqual(attribute(Sheet.kind), "text (a color's name or #RRGGBB)")
        expectEqual(attribute(Pane.kind), "text (a color's name or #RRGGBB)")
        expectEqual(attribute(Card.kind), nil)
    },
])

/// A shape at slot `n` of a row, with an own color if given.
@MainActor private func colored<P: BoxShapeProps>(_ props: P, _ n: Int, _ color: ShapeColor?) -> AnyShapeRecord {
    var props = props
    props.frame = CGRect(x: CGFloat(n) * 100, y: 0, width: 50, height: 50)
    var record = AnyShapeRecord(ShapeRecord(props))
    if let color { record[ColorProperty.self] = color }
    return record
}

@MainActor private func colorAnswer(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryRequest.every, properties: .all))
    }
}

/// Which shapes (by their order on the board) a query matches.
@MainActor private func colorMatches(_ text: String, on h: EditorHarness) throws -> [Int] {
    let ids = Set(try colorAnswer(text, on: h).rows.map(\.id))
    return h.editor.document.shapes.enumerated().filter { ids.contains($0.element.id) }.map(\.offset)
}

@MainActor let colorQueryTests = Suite("Colors in canvas query", [
    test("a color is found as it's stored: a name, a hex value, and either whatever its case with the i flag") {
        // The third holds BLUE as a hand-written board would; draw and setColor keep a name as its list spells it.
        let h = try wordsHarness(file: CanvasFile(root: CanvasDocument(shapes: [colored(Sheet(), 0, .blue), colored(Pane(), 1, .value(RGB(hex: 0x4466EE))), colored(Sheet(), 2, .named("BLUE")), colored(Card(.zero), 3, nil)])))
        expectEqual(try colorMatches(##"[color="blue"]"##, on: h), [0])
        expectEqual(try colorMatches(##"[color=blue]"##, on: h), [0])
        expectEqual(try colorMatches(##"[color="BLUE"]"##, on: h), [2])
        expectEqual(try colorMatches(##"[color="BLUE" i]"##, on: h), [0, 2])
        expectEqual(try colorMatches(##"[color="#4466EE"]"##, on: h), [1])
        expectEqual(try colorMatches(##"[color="#4466ee" i]"##, on: h), [1])
        expectEqual(try colorMatches(##"[color^="#44"]"##, on: h), [1])
        expectEqual(try colorMatches(##"sheet[color="red"]"##, on: h), [])
    },
    test("[color] matches a shape with a color of its own, not one drawn in its kind's default") {
        let h = try wordsHarness(file: CanvasFile(root: CanvasDocument(shapes: [colored(Sheet(), 0, .teal), colored(Sheet(), 1, nil), colored(Pane(), 2, nil), colored(Card(.zero), 3, nil)])))
        expectEqual(try colorMatches("[color]", on: h), [0])
        expectEqual(try colorMatches("sheet:not([color])", on: h), [1])
    },
    test("a row's color is the stored text, a name or #RRGGBB") {
        let box = Sheet(CGRect(x: 0, y: 0, width: 50, height: 50))
        var short = AnyShapeRecord(ShapeRecord(box))
        short[ColorProperty.self] = .named("blue")
        var raw = AnyShapeRecord(ShapeRecord(Pane(CGRect(x: 100, y: 0, width: 50, height: 50))))
        raw[ColorProperty.self] = .value(RGB(hex: 0x4465E9))
        let h = try wordsHarness(file: CanvasFile(root: CanvasDocument(shapes: [short, raw])))
        let rows = try colorAnswer("*", on: h).rows
        expectEqual(rows.map { $0.properties?["color"] }, ["blue", "#4465E9"])
    },
])
