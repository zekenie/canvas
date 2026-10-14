import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Queries
import TestKit

// `canvas draw` with a plugin that reports (`DrawReports`): each shape and edge the run made, changed or
// restated is reported on once the script's shapes are all in the transaction. Its problems go on the
// shape's row, its warnings among the run's with the statement's line. These tests' report is a fixture:
// a tile says it is unfit when its label is `Odd`, and a shape whose statement wrote `facts` is warned
// about them.

/// What a fixture report was asked: the shape, whether the statement wrote values, and which of the
/// script's shapes the board it was given held.
@MainActor final class ReportLog {
    var asked: [(title: String?, written: JSONObject?, boardHolds: Int)] = []
}

@MainActor func reportsPlugin(_ log: ReportLog = ReportLog()) -> Contributor {
    Contributor(id: "reports") { registrar in
        registrar.drawReports { record, written, shapes, _ in
            let title = record.typed(as: Tile.self)?.props.label
            log.asked.append((title, written, shapes.document.shapes.count))
            var report = DrawShapeReport()
            if title == "Odd" || record.kind == Link.kind {
                report.problems = [ShapeProblem(field: "label", path: "/label", class: "wrong", message: "label is odd"),
                                   ShapeProblem(field: nil, path: nil, class: "needed", message: "a rule across fields")]
            }
            if written?["facts"] != nil { report.warnings = [DrawIssue("facts: it has no type", field: "facts")] }
            return report
        }
    }
}

@MainActor let drawReportTests = Suite("draw: what a plugin reports", [
    test("a created, an updated and an unchanged shape's rows carry its problems, a shape with none carries no member, and each is asked once") {
        let log = ReportLog()
        let editor = try drawEditor([reportsPlugin(log)])
        let made = try drawn("tile \"Odd\"\ntile \"Even\" right of \"Odd\"", on: editor)
        expectEqual(rows(made).map { $0["problems"]?.arrayValue?.count }, [2, nil])
        let odd = try require(rows(made).first?["problems"]?.arrayValue?.first)
        expectEqual(odd, ["field": "label", "path": "/label", "class": "wrong", "message": "label is odd"])
        expectEqual(rows(made).first?["problems"]?.arrayValue?.last, ["class": "needed", "message": "a rule across fields"], "none for the whole shape, so no field and no path")
        expectEqual(log.asked.count, 2, "once a shape")
        log.asked = []
        let same = try drawn("tile \"Odd\"", on: editor)
        expectEqual(rows(same).map { $0["did"] }, ["unchanged"])
        expectEqual(rows(same).first?["problems"]?.arrayValue?.count, 2, "an unchanged row says what is left")
        expect(try require(log.asked.first).written == nil, "nothing was written for it")
        let moved = try drawn("tile \"Odd\" size: 150x", on: editor)
        expectEqual(rows(moved).first?["problems"]?.arrayValue?.count, 2, "a changed one too")
    },

    test("the report is asked once every shape of the script is in the transaction, with what the statement wrote") {
        let log = ReportLog()
        let editor = try drawEditor([factsPlugin(), reportsPlugin(log)])
        _ = try drawn("tile \"A\" facts: {\"x\": 1}\ntile \"B\" right of \"A\"", on: editor)
        expectEqual(log.asked.map(\.boardHolds), [2, 2], "the second shape is on the board when the first is reported")
        let first = try require(log.asked.first { $0.title == "A" })
        expectEqual(first.written, ["facts": ["x": 1]], "what was written, as the writer wrote it, not as joined")
        expect(try require(log.asked.first { $0.title == "B" }).written?.isEmpty == true, "a statement that wrote no values wrote an empty object")
        log.asked = []
        _ = try drawn("tile \"A\" facts: {\"y\": 2}", on: editor)
        expectEqual(try require(log.asked.first).written, ["facts": ["y": 2]], "the join is not in it: only what the statement named")
    },

    test("a warning is on its statement's line, named by its shape; a dry run reports the same") {
        let editor = try drawEditor([factsPlugin(), reportsPlugin()])
        let result = try drawn("tile \"A\"\ntile \"B\" right of \"A\" facts: {\"x\": 1}", on: editor, ["--dry-run"])
        let warnings = (result["warnings"]?.arrayValue ?? [])
        expectEqual(warnings.count, 1)
        expectEqual(warnings.first?["message"], #""B": facts: it has no type"#)
        expectEqual(warnings.first?["line"], 2)
        expectEqual(warnings.first?["attribute"], "facts")
        expectEqual(warnings.first?["severity"], "warning")
        expectEqual(editor.document.shapes.count, 0)
        let real = try drawn("tile \"A\"\ntile \"B\" right of \"A\" facts: {\"x\": 1}", on: editor)
        expectEqual(real["warnings"], result["warnings"])
        // Restated and unchanged: nothing written, so nothing warned.
        let again = try drawn("tile \"B\" facts: {\"x\": 1}", on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged"])
        expectEqual(again["warnings"]?.arrayValue?.isEmpty ?? true, true)
    },

    test("an edge's row carries its problems too, and what its statement wrote") {
        let log = ReportLog()
        let editor = try drawEditor([factsPlugin(), reportsPlugin(log)])
        let result = try drawn("tile \"A\"\ntile \"B\" right of \"A\"\nedge \"A\" -> \"B\" facts: {\"x\": 1}", on: editor)
        let edge = try require(rows(result).first { $0["kind"] == "link" })
        expectEqual(edge["problems"]?.arrayValue?.count, 2)
        expectEqual(try require(log.asked.first { $0.title == nil }).written, ["facts": ["x": 1]])
        expect(try require(result["warnings"]?.arrayValue?.first)["message"]?.stringValue?.hasPrefix("edge ") == true, "named as an edge is")
        log.asked = []
        let same = try drawn("edge \"A\" -> \"B\" facts: {\"x\": 1}", on: editor)
        expectEqual(rows(same).map { $0["did"] }, ["unchanged"])
        expectEqual(rows(same).first?["problems"]?.arrayValue?.count, 2)
        expect(try require(log.asked.first).written == nil)
    },

    test("an edge can't carry an attribute named problems, which its row has of its own") {
        expectThrows(RegistryError.invalid(point: "DrawEdges", reason: "attribute problems: a draw result's row has problems of its own")) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), Contributor(id: "edges") {
                $0.drawEdges(kind: { _ in Link.kind }, attributes: ["problems"], sides: { _, _ in [:] }, ends: { _, _ in nil }, make: { _, _, _ throws(DrawError) in
                    throw DrawError("no", reason: "cannot_connect")
                })
            }])
        }
    },

    test("two plugins reporting refuse the plugin list") {
        let twice = { (id: PluginID) in Contributor(id: id) { $0.drawReports { _, _, _, _ in DrawShapeReport() } } }
        expectThrows(RegistryError.conflict(point: "DrawReports", key: "draw reports", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [DrawPlugin(), AutomationPlugin(), twice("a"), twice("b")])
        }
    },
])
