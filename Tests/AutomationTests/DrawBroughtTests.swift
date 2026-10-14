import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// What a run says of shapes it did not write: with a check that answers Draw's second question (`touched`), a run
// warns of each issue it brings to a shape none of its statements changed. The fixture check is about a shape other
// than the one written: a tile that more than one link ends at is crowded, and it is the links a script draws.

/// What the crowd check was asked, and the editor it reads a deleted link's end from.
@MainActor final class Crowd {
    weak var editor: CanvasEditor?
    /// How many times it was asked which shapes a run's writes reach.
    var asked = 0
}

/// Checks shapes: a tile more than one link ends at is crowded (an error on the tile, none on the links), and a
/// glossy tile glares. Of what a run wrote, it names the tiles its links end at, or ended at.
@MainActor func crowdPlugin(_ crowd: Crowd, touches: Bool = true) -> Contributor {
    let reached: @MainActor (ChangeSet, ShapeContext) -> Set<ShapeID> = { changes, shapes in
        crowd.asked += 1
        var found: Set<ShapeID> = []
        for id in changes.shapeIDs {
            let records: [AnyShapeRecord?] = [shapes.shape(id), crowd.editor?.document[id]]
            for record in records {
                if let to = record?.typed(as: Link.self)?.props.to { found.insert(to) }
            }
        }
        return found
    }
    let touched: (@MainActor (ChangeSet, ShapeContext) -> Set<ShapeID>)? = touches ? reached : nil
    return Contributor(id: "checks") { registrar in
        registrar.drawChecks(touched: touched, rest: #"canvas query ":crowded""#) { record, shapes -> [DrawIssue] in
            guard let tile = record.typed(as: Tile.self) else { return [] }
            var issues: [DrawIssue] = []
            if tile.props.finish == .glossy { issues.append(DrawIssue("A glossy tile glares.", isError: true, field: "finish")) }
            let links = shapes.document.shapes.filter { $0.typed(as: Link.self)?.props.to == tile.id }.count
            if links > 1 { issues.append(DrawIssue("it has \(links) links, and should have at most 1", isError: true, field: "links")) }
            return issues
        }
    }
}

/// An editor with names, edges and the crowd check: Hub with A left of it and B and C below, and a link from A to Hub.
@MainActor private func crowdEditor(_ crowd: Crowd = Crowd(), touches: Bool = true) throws -> CanvasEditor {
    let editor = try makeEditor([namesPlugin(), edgesPlugin(), crowdPlugin(crowd, touches: touches)])
    crowd.editor = editor
    let hub = tile("Hub", CGRect(x: 400, y: 200, width: 120, height: 80), in: editor)
    let a = tile("A", CGRect(x: 100, y: 200, width: 120, height: 80), in: editor)
    tile("B", CGRect(x: 400, y: 500, width: 120, height: 80), in: editor)
    tile("C", CGRect(x: 700, y: 500, width: 120, height: 80), in: editor)
    link(a, hub, in: editor)
    return editor
}

private func crowded(_ title: String, _ links: Int, line: Int?) -> JSON {
    var warning: [String: JSON] = ["message": .string("\"\(title)\": it has \(links) links, and should have at most 1"), "severity": "error", "attribute": "links"]
    if let line { warning["line"] = .number(Double(line)) }
    return .object(warning)
}

@MainActor let drawBroughtTests = Suite("draw: what a run brings to shapes it did not write", [
    test("an issue brought to a shape no statement names is a warning, once, with the line of the statement that brought it") {
        let editor = try crowdEditor()
        let result = try drawn(#"""
        tile "D" below "A"
        edge "B" -> "Hub"
        """#, on: editor)
        expectEqual(result["warnings"], [crowded("Hub", 2, line: 2)])
        expectEqual(rows(result).map { $0["title"]?.stringValue ?? $0["did"]?.stringValue }, ["D", "connected"], "Hub has no row")
    },
    test("a run that mends an issue, or leaves one as it was, says nothing of it") {
        let crowd = Crowd()
        let editor = try crowdEditor(crowd)
        _ = try drawn(#"edge "B" -> "Hub""#, on: editor)
        crowd.asked = 0
        // Another tile's link changes nothing of Hub, which stays crowded.
        expectEqual(try drawn(#"edge "A" -> "C""#, on: editor)["warnings"], [])
        expect(crowd.asked > 0, "the check was asked what the run reaches")
        expectEqual(try drawn(#"delete edge "B" -> "Hub""#, on: editor)["warnings"], [], "Hub is looked at, and has one issue fewer")
    },
    test("only what is new is said: an issue the shape had before the run is not") {
        let editor = try crowdEditor()
        _ = try drawn(#"tile "Hub" finish: glossy"#, on: editor)
        let result = try drawn(#"edge "B" -> "Hub""#, on: editor)
        expectEqual(result["warnings"], [crowded("Hub", 2, line: 1)], "Hub glared before, and that is not the run's")
        // One link more is another issue, by its message.
        expectEqual(try drawn(#"edge "C" -> "Hub""#, on: editor)["warnings"], [crowded("Hub", 3, line: 1)])
    },
    test("a dry run says the same, and changes nothing") {
        let editor = try crowdEditor()
        let before = editor.document, revision = editor.revision
        let dry = try drawn(#"edge "B" -> "Hub""#, on: editor, ["--dry-run"])
        expectEqual(dry["warnings"], [crowded("Hub", 2, line: 1)])
        expectEqual(editor.document, before)
        expectEqual(editor.revision, revision)
        expect(!editor.canUndo || editor.undoHistory.undoName != "Draw", "no step")
        expectEqual(try drawn(#"edge "B" -> "Hub""#, on: editor)["warnings"], dry["warnings"])
    },
    test("a shape the run changed is said by its own statement, and not again") {
        let editor = try crowdEditor()
        let result = try drawn(#"""
        tile "Hub" finish: glossy
        edge "B" -> "Hub"
        """#, on: editor)
        expectEqual(result["warnings"], [
            ["line": 1, "message": #""Hub": A glossy tile glares."#, "severity": "error", "attribute": "finish"],
            crowded("Hub", 2, line: 1),
        ])
    },
    test("a shape restated as it is was not written: the issue is said once, on the line of the statement that brought it") {
        let editor = try crowdEditor()
        let result = try drawn(#"""
        tile "Hub"
        edge "B" -> "Hub"
        """#, on: editor)
        expectEqual(rows(result).first?["did"], "unchanged")
        expectEqual(result["warnings"], [crowded("Hub", 2, line: 2)])
    },
    test("an issue that several statements bring together has no line") {
        let editor = try crowdEditor()
        let result = try drawn(#"""
        edge "A" -> "C"
        edge "B" -> "C"
        """#, on: editor)
        expectEqual(result["warnings"], [crowded("C", 2, line: nil)])
    },
    test("at most twenty shapes are said, in the order of their names, and the rest are counted") {
        @MainActor func broken(_ count: Int) throws -> [JSON] {
            let crowd = Crowd()
            let editor = try makeEditor([namesPlugin(), edgesPlugin(), crowdPlugin(crowd)])
            crowd.editor = editor
            let first = tile("S0", CGRect(x: 0, y: 0, width: 120, height: 80), in: editor)
            tile("S1", CGRect(x: 0, y: 200, width: 120, height: 80), in: editor)
            var script: [String] = []
            for index in 1...count {
                let name = "T" + String(format: "%02d", index)
                let made = tile(name, CGRect(x: 200 + Double(index) * 140, y: 0, width: 120, height: 80), in: editor)
                link(first, made, in: editor)
                script.append(#"edge "S1" -> "\#(name)""#)
            }
            // The last statement first, so the order said is the names', not the script's.
            return try drawn(script.reversed().joined(separator: "\n"), on: editor)["warnings"]?.arrayValue ?? []
        }
        let all = try broken(20)
        expectEqual(all.count, 20)
        expectEqual(all.first, crowded("T20", 2, line: 1), "by line, as every warning of a run is")
        let more = try broken(25)
        expectEqual(more.count, 21)
        expectEqual(more.compactMap { $0["line"]?.intValue }.sorted(), Array(6...25), "the twenty first by name: T01 to T20, written on lines 25 down to 6")
        expectEqual(more.last, ["message": #"and 5 more shapes now have issues: ask canvas query ":crowded""#, "severity": "warning"])
        let one = try broken(21)
        expectEqual(one.last, ["message": #"and 1 more shape now has issues: ask canvas query ":crowded""#, "severity": "warning"])
    },
    test("with no check, or one that names no shapes, a run says what it said") {
        let none = try makeEditor([namesPlugin(), edgesPlugin()])
        let hub = tile("Hub", CGRect(x: 400, y: 200, width: 120, height: 80), in: none)
        link(tile("A", CGRect(x: 100, y: 200, width: 120, height: 80), in: none), hub, in: none)
        tile("B", CGRect(x: 400, y: 500, width: 120, height: 80), in: none)
        expectEqual(try drawn(#"edge "B" -> "Hub""#, on: none)["warnings"], [])

        let crowd = Crowd()
        let silent = try crowdEditor(crowd, touches: false)
        expectEqual(try drawn(#"edge "B" -> "Hub""#, on: silent)["warnings"], [], "the check is asked only of the shapes the run wrote")
        expectEqual(crowd.asked, 0)
        // And says it of Hub once a statement changes Hub.
        expectEqual(try drawn(#"tile "Hub" finish: glossy"#, on: silent)["warnings"]?.arrayValue?.count, 2)
    },
    test("a run that reaches nothing asks once; a run is one undo step, as before") {
        let crowd = Crowd()
        let editor = try crowdEditor(crowd)
        let before = editor.document
        crowd.asked = 0
        expectEqual(try drawn(#"tile "D" below "A""#, on: editor)["warnings"], [])
        expectEqual(crowd.asked, 1, "nothing was brought, so no statement is asked about alone")
        editor.undo()
        crowd.asked = 0
        _ = try drawn(#"""
        tile "D" below "A"
        edge "B" -> "Hub"
        """#, on: editor)
        expectEqual(crowd.asked, 3, "once for the run, then once for each statement that wrote")
        expectEqual(editor.undoHistory.undoName, "Draw")
        editor.undo()
        expectEqual(editor.document, before)
        expectEqual(try drawn(#"tile "Hub""#, on: editor)["warnings"], [], "a run that writes nothing asks nothing")
    },
])
