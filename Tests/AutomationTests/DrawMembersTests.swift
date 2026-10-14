import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// A row's members (`registrar.drawReports(members:)`): the keys a report may add to a row, flat beside its own.
// A fixture report says what a tie is by its bond (`tied`), says `cut` of a tie a run deletes, warns of a tie
// deleted without naming its bond, and offers one member it never declared.

/// What the fixture report was asked of a connection a run deleted: the bond, and what the statement wrote.
@MainActor final class GoneLog {
    var asked: [(bond: String?, written: JSONObject?, onBoard: Bool)] = []
}

@MainActor private func membersPlugin(_ log: GoneLog = GoneLog()) -> Contributor {
    Contributor(id: "members") { registrar in
        registrar.drawReports(members: ["tied", "cut"]) { record, written, shapes, _ in
            var report = DrawShapeReport()
            guard record.kind == Link.kind else { return report }
            let onBoard = shapes.document[record.id] != nil
            if !onBoard { log.asked.append((record[Bond.self], written, onBoard)) }
            if let bond = record[Bond.self] {
                report.members[onBoard ? "tied" : "cut"] = .string(bond)
                // Never declared: left out of the row.
                report.members["secret"] = .string(bond)
                if !onBoard, written == nil { report.warnings = [DrawIssue("that removed a tie bound by \(bond)")] }
            }
            return report
        }
    }
}

@MainActor private func memberEditor(_ log: GoneLog = GoneLog()) throws -> CanvasEditor {
    let editor = try makeEditor([namesPlugin(), tieEdgesPlugin(), membersPlugin(log)])
    _ = try drawn(threeShapes, on: editor)
    return editor
}

@MainActor let drawMembersTests = Suite("draw: what a report adds to a row", [
    test("a member the report declared is on the row beside its own, on a restated and a dry-run row too, and one it did not declare is left out") {
        let editor = try memberEditor()
        let made = try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        let row = try require(rows(made).first)
        expectEqual(row["tied"], "x")
        expectEqual(row["did"], "connected")
        expectEqual(row["from"], "Hub", "the row's own members are as they were")
        expect(row["secret"] == nil, "a member nobody declared")
        let again = try drawn(#"edge "Hub" -> "East" bond: "x""#, on: editor)
        expectEqual(rows(again).first?["did"], "unchanged")
        expectEqual(rows(again).first?["tied"], "x", "an unchanged row says it too")
        let dry = try drawn(#"edge "Hub" -> "East" bond: "y""#, on: editor, ["--dry-run"])
        expectEqual(rows(dry).first?["tied"], "y", "a dry run says what a real run says")
        let real = try drawn(#"edge "Hub" -> "East" bond: "y""#, on: editor)
        expectEqual(rows(real).first?["tied"], "y")
        expect(rows(try drawn(#"tile "Hub""#, on: editor)).first?["tied"] == nil, "a shape the report says nothing of carries none")
    },
    test("a connection a run deletes is reported on too, for members and warnings: with nothing written when a delete edge names no bond") {
        let log = GoneLog()
        let editor = try memberEditor(log)
        _ = try drawn("""
        edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "y"
        """, on: editor)
        let none = try drawn(#"delete edge "Hub" -> "East""#, on: editor)
        expectEqual(rows(none).map { $0["did"] }, ["deleted", "deleted"])
        expectEqual(Set(rows(none).compactMap { $0["cut"]?.stringValue }), ["x", "y"], "each row says what went")
        expectEqual(Set(messages(none)), [#"delete edge "Hub" -> "East": that removed a tie bound by x"#, #"delete edge "Hub" -> "East": that removed a tie bound by y"#],
                    "a warning for each")
        expect(log.asked.allSatisfy { $0.written == nil && !$0.onBoard }, "asked with nothing written, and the record gone")
        _ = try drawn("""
        edge "Hub" -> "East" bond: "x"
        edge "Hub" -> "East" bond: "y"
        """, on: editor)
        log.asked = []
        let one = try drawn(#"delete edge "Hub" -> "East" bond: "y""#, on: editor)
        expectEqual(rows(one).map { $0["cut"] }, ["y"])
        expectEqual(messages(one), [], "a delete that names the bond is not warned")
        expect(log.asked.allSatisfy { $0.written != nil }, "it wrote something")
        log.asked = []
        let shape = try drawn(#"delete "East""#, on: editor)
        expectEqual(rows(shape).compactMap { $0["cut"]?.stringValue }, ["x"], "the connection that went with a shape too")
        expectEqual(messages(shape), [], "which a delete of a shape does not warn of")
    },
    test("a member is a word that is not the row's own, an edge's attribute or declared twice") {
        @MainActor func plugins(_ members: [String], attributes: [String] = []) -> [any CanvasPlugin] {
            [DrawPlugin(), AutomationPlugin(), Contributor(id: "edges") {
                $0.drawEdges(kind: { _ in nil }, attributes: attributes, sides: { _, _ in [:] }, ends: { _, _ in nil }, make: { _, _, _ throws(DrawError) in
                    throw DrawError("no", reason: "cannot_connect")
                })
            }, Contributor(id: "reports") { $0.drawReports(members: members) { _, _, _, _ in DrawShapeReport() } }]
        }
        func refused(_ reason: String) -> RegistryError { .invalid(point: "DrawReports", reason: reason) }
        expectThrows(refused("member did: a draw result's row has did of its own")) { _ = try Registry(plugins: plugins(["did"])) }
        expectThrows(refused("member problems: a draw result's row has problems of its own")) { _ = try Registry(plugins: plugins(["problems"])) }
        expectThrows(refused("member : a key is a word a row can carry")) { _ = try Registry(plugins: plugins([""])) }
        expectThrows(refused("member a: it's declared twice")) { _ = try Registry(plugins: plugins(["a", "a"])) }
        expectThrows(refused("member text: an edge's row carries text as an attribute")) { _ = try Registry(plugins: plugins(["text"], attributes: ["text"])) }
        _ = try Registry(plugins: plugins(["tied", "cut"], attributes: ["text"]))
    },
])
