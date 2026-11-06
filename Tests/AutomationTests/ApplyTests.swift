@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// `canvas apply` over fixtures: a document drawn by key on every board it reaches in one step, again by key, refused by key; `canvas
// measure` of a document by key; and `canvas draw --drawing` joining a run to a drawing. The drawings are kept by a plugin of the test's own
// (Drawings is the shipped keeper: CompositionTests' ApplyTests hold it).

/// The drawings a file keeps, for these tests.
enum TestDrawings: FileProperty {
    static let key: PropertyKey = "test-drawings"
    static var defaultValue: [String: DrawingRecord] { [:] }
}

let recordsPlugin = Contributor(id: "test-records") { registrar in
    registrar.declare(file: TestDrawings.self)
    registrar.drawRecords(
        read: { name, file in file[TestDrawings.self][name] },
        write: { name, record, transaction in
            var all = transaction.fileValue(TestDrawings.self)
            all[name] = record
            transaction.setFileValue(TestDrawings.self, to: all)
        },
        names: { file in file[TestDrawings.self].keys.sorted() })
}

@MainActor private func applyEditor(keeping: Bool = true) throws -> CanvasEditor {
    try drawEditor([pens, PocketsPlugin(), namedPockets] + (keeping ? [recordsPlugin] : []))
}

@MainActor private func applied(_ document: JSON, on editor: CanvasEditor, _ options: [String] = []) throws -> JSON {
    switch try run(["apply", "-"] + options, on: editor, input: document.compactText) {
    case .success(let json): return json
    case .failure(let error): throw DrawFailed(error: error)
    }
}

@MainActor private func refusedApply(_ document: JSON, on editor: CanvasEditor) throws -> RPCError {
    switch try run(["apply", "-"], on: editor, input: document.compactText) {
    case .success(let json): throw DrewAnyway(result: json)
    case .failure(let error): return error
    }
}

private func verdict(_ answer: JSON, _ key: String) -> JSON? {
    answer["nodes"]?.arrayValue?.first { $0["key"]?.stringValue == key }
}

private func id(_ answer: JSON, _ key: String) -> ShapeID? {
    verdict(answer, key)?["id"]?.stringValue.flatMap(UUID.init(uuidString:)).map(ShapeID.init)
}

private func tileNode(_ key: String, _ label: String, at: [Double], in container: String? = nil) -> JSON {
    var node: JSON = ["key": .string(key), "kind": "tile", "props": ["label": .string(label)], "place": ["at": .array(at.map { .number($0) })]]
    if let container { node["in"] = .string(container) }
    return node
}

@MainActor let applyTests = Suite("canvas apply over fixtures", [
    test("each node is made with the id the document's run picks, where its place says (negative too), in one step, its record kept by key") {
        let editor = try applyEditor()
        let answer = try applied(["drawing": "D", "nodes": [tileNode("t:one", "One", at: [-300, -200]), tileNode("t:two", "Two", at: [100, 50])]], on: editor)
        expectEqual(answer["nodes"]?.arrayValue?.map { $0["did"] }, ["created", "created"])
        expectEqual(shape("One", in: editor)?.box?.origin, CGPoint(x: -300, y: -200))
        expectEqual(shape("Two", in: editor)?.box?.origin, CGPoint(x: 100, y: 50))
        expectEqual(id(answer, "t:one"), shape("One", in: editor)?.id)
        let record = editor.file[TestDrawings.self]["D"]
        expectEqual(Set(record?.shapes.values.map(\.key) ?? []), ["t:one", "t:two"])
        expectEqual(record?.board, "root")
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expect(shape("One", in: editor) == nil && shape("Two", in: editor) == nil, "one undo takes it all back")
        expect(editor.file[TestDrawings.self].isEmpty, "the record too")
    },
    test("a pen holds what is in it, placed from its top-left, in one step; a kind no tool places is refused by key") {
        let editor = try applyEditor()
        let answer = try applied(["drawing": "D", "nodes": [
            ["key": "pen:yard", "kind": "pen", "props": ["label": "Yard"], "place": ["at": [200, 100], "size": [400, 300]]],
            tileNode("t:in", "Inside", at: [40, 50], in: "pen:yard"),
        ]], on: editor)
        guard let pen = id(answer, "pen:yard"), let inside = id(answer, "t:in") else {
            expect(false, "all drawn: \(answer.compactText)")
            return
        }
        expectEqual(editor.file.record(pen)?.box, CGRect(x: 200, y: 100, width: 400, height: 300))
        expectEqual(editor.file.record(inside)?.box?.origin, CGPoint(x: 240, y: 150), "from the pen's top-left")
        expectEqual(editor.file.record(inside)?.container, pen)
        editor.undo()
        expectEqual(editor.file.shapeCount, 0)
        let error = try refusedApply(["drawing": "D", "nodes": [["key": "pocket:p", "kind": "pocket"]]], on: editor)
        expectEqual(error.data?["key"], "pocket:p")
        expectEqual(error.data?["refusals"]?.arrayValue?.first?["reason"], "unknown_kind")
    },
    test("drawn again it is unchanged; a changed label is updated; a key gone is deleted; a tile that isn't the drawing's stays") {
        let editor = try applyEditor()
        let first: JSON = ["drawing": "D", "nodes": [tileNode("t:one", "One", at: [0, 0]), tileNode("t:two", "Two", at: [200, 0])]]
        _ = try applied(first, on: editor)
        _ = try drawn(#"tile "Mine" right of origin (gap: 900) below origin (gap: 0)"#, on: editor)
        let before = editor.file
        let again = try applied(first, on: editor)
        expectEqual(again["nodes"]?.arrayValue?.map { $0["did"] }, ["unchanged", "unchanged"])
        expectEqual(editor.file, before)
        let renamed = try applied(["drawing": "D", "nodes": [tileNode("t:one", "Uno", at: [0, 0]), tileNode("t:two", "Two", at: [200, 0])]], on: editor)
        expectEqual(verdict(renamed, "t:one")?["did"], "updated")
        expectEqual(verdict(renamed, "t:two")?["did"], "unchanged")
        let gone = try applied(["drawing": "D", "nodes": [tileNode("t:one", "Uno", at: [0, 0])]], on: editor)
        expectEqual(gone["deleted"]?.arrayValue?.compactMap { $0["key"]?.stringValue }, ["t:two"])
        expect(shape("Two", in: editor) == nil)
        expect(shape("Mine", in: editor) != nil, "a shape outside the drawing is never touched")
    },
    test("a dry run says what it would do, a created node with no id, and changes nothing") {
        let editor = try applyEditor()
        let before = editor.file
        let answer = try applied(["drawing": "D", "nodes": [tileNode("t:one", "One", at: [0, 0])]], on: editor, ["--dry-run"])
        expectEqual(answer["dryRun"], true)
        expectEqual(verdict(answer, "t:one")?["did"], "created")
        expectEqual(verdict(answer, "t:one")?["id"], nil)
        expectEqual(editor.file, before)
        expect(!editor.canUndo)
    },
    test("a document that isn't one is refused by key, every problem at once, and nothing changes") {
        let editor = try applyEditor()
        let error = try refusedApply(["drawing": "D", "nodes": [
            tileNode("t:a", "A", at: [0, 0], in: "nowhere"),
            tileNode("t:a", "A again", at: [0, 0]),
            ["key": "t:b", "kind": "wall"],
            tileNode("t:c", "C", at: [0, 0], in: "t:d"),
            tileNode("t:d", "D", at: [0, 0]),
        ]], on: editor)
        let refusals = error.data?["refusals"]?.arrayValue ?? []
        expectEqual(Set(refusals.compactMap { $0["reason"]?.stringValue }), ["unknown_key", "duplicate", "unknown_kind", "cannot_contain"])
        expectEqual(error.data?["key"], "t:a")
        expectEqual(editor.file.shapeCount, 0)
        let ring = try refusedApply(["drawing": "D", "nodes": [
            ["key": "pen:a", "kind": "pen", "in": "pen:b"], ["key": "pen:b", "kind": "pen", "in": "pen:a"],
        ]], on: editor)
        expectEqual(ring.data?["refusals"]?.arrayValue?.first?["reason"], "circular")
        let unnamed = try refusedApply(["nodes": [tileNode("t:a", "A", at: [0, 0])]], on: editor)
        expectEqual(unnamed.data?["refusals"]?.arrayValue?.first?["reason"], "invalid_document")
    },
    test("a draw refusal is the document's, naming the node's key, and nothing changes") {
        let editor = try applyEditor()
        let error = try refusedApply(["drawing": "D", "nodes": [["key": "t:a", "kind": "tile", "props": ["label": "A", "finish": "shiny"]]]], on: editor)
        expectEqual(error.data?["key"], "t:a")
        expectEqual(editor.file.shapeCount, 0)
    },
    test("with nothing that keeps drawings, apply is refused") {
        let editor = try applyEditor(keeping: false)
        let error = try refusedApply(["drawing": "D", "nodes": [tileNode("t:a", "A", at: [0, 0])]], on: editor)
        expectEqual(error.data?["refusals"]?.arrayValue?.first?["reason"], "no_drawings")
    },
    test("a draw run joins a drawing: what it names is kept by id in the run's own step; a dry run keeps nothing") {
        let editor = try applyEditor()
        _ = try drawn(#"tile "A""#, on: editor, ["--dry-run", "--drawing", "Mine"])
        expect(editor.file[TestDrawings.self].isEmpty, "a dry run keeps nothing")
        _ = try drawn(#"tile "A""#, on: editor, ["--drawing", "Mine"])
        let a = try require(shape("A", in: editor))
        expectEqual(editor.file[TestDrawings.self]["Mine"]?.shapes[a.id.description]?.key, "#\(a.id)")
        editor.undo()
        expect(editor.file[TestDrawings.self].isEmpty, "one undo takes the shape and the record back")
        let error = try refused(#"tile "B""#, on: try applyEditor(keeping: false), ["--drawing", "Mine"])
        expectEqual(error.data?["reason"] ?? .string(error.message), "no_drawings")
    },
    test("what a draw run joined to a program's drawing stays through the program's next apply, and in the record") {
        let editor = try applyEditor()
        _ = try applied(["drawing": "D", "nodes": [tileNode("t:one", "One", at: [0, 0])]], on: editor)
        _ = try drawn(#"tile "Mine" right of origin (gap: 600) below origin (gap: 0)"#, on: editor, ["--drawing", "D"])
        let mine = try require(shape("Mine", in: editor))
        expectEqual(editor.file[TestDrawings.self]["D"]?.shapes[mine.id.description]?.key, "#\(mine.id)", "joined, by its id")
        let again = try applied(["drawing": "D", "nodes": [tileNode("t:one", "One", at: [0, 0])]], on: editor)
        expectEqual(again["deleted"]?.arrayValue ?? [], [], "nothing the document lacks a key for is deleted: \(again.compactText)")
        expect(shape("Mine", in: editor) != nil, "the joined tile is there")
        expectEqual(editor.file[TestDrawings.self]["D"]?.shapes[mine.id.description]?.key, "#\(mine.id)", "and still the drawing's")
    },
    test("measure of a document answers by key: each node's size, nothing drawn") {
        let editor = try applyEditor()
        let answer = try require(try run(["measure", "-"], on: editor, input: (["nodes": [tileNode("t:a", "A", at: [0, 0]), ["key": "pen:p", "kind": "pen"]]] as JSON).compactText).get())
        let drawnTile = try drawn(#"tile "A""#, on: editor)
        let tileSize = rows(drawnTile).first?["at"]?.arrayValue?.last
        expectEqual(answer["nodes"]?["t:a"]?["size"], tileSize, "the size a draw makes")
        expectEqual(answer["nodes"]?["pen:p"]?["size"], [400, 300])
        editor.undo()
        expect(answer["constants"] != nil)
        expectEqual(editor.file.shapeCount, 0)
    },
])
