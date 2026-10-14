@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// What finding the line of a warning costs. Once anything is brought, Draw
// asks `touched` again of each statement's own writes; Types' answer names what the whole run recompiled whatever
// the writes it is asked of, so a script of K unrelated statements beside one end given a rule asks K times for
// every note of the end type.

private let lineSchema = #"{"type": "object", "properties": {"level": {"type": "string"}}}"#

@MainActor private func lineWorld(instances: Int) throws -> CanvasEditor {
    let editor = try typeEditorWithDraw()
    func type(_ title: String, at origin: CGPoint, marked: Bool = false) -> ShapeID {
        var record = slipTypeRecord(lineSchema, title: title, at: origin)
        if marked { record[RelationshipProperty.self] = true }
        editor.transact { $0.insert(record) }
        return record.id
    }
    let person = type("Person", at: CGPoint(x: 40, y: 40))
    let employment = type("Employment", at: CGPoint(x: 400, y: 40), marked: true)
    let company = type("Company", at: CGPoint(x: 760, y: 40))
    editor.addBond(person, employment, name: "jobs")
    editor.addBond(employment, company, name: "staff")
    var acme = slipRecord("", of: [company], at: CGPoint(x: 760, y: 400))
    acme[TitleProperty.self] = "Acme"
    var globex = slipRecord("", of: [company], at: CGPoint(x: 760, y: 600))
    globex[TitleProperty.self] = "Globex"
    var records: [AnyShapeRecord] = [acme, globex]
    for index in 0..<instances {
        var note = slipRecord("", of: [person], at: CGPoint(x: 1200 + Double(index % 40) * 260, y: Double(index / 40) * 200))
        note[TitleProperty.self] = "P" + String(format: "%04d", index)
        records.append(note)
        for end in [acme.id, globex.id] {
            var bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: note.id, to: end, text: "")))
            bond[IsAProperty.self] = [TypeLink(employment)]
            records.append(bond)
        }
    }
    // And as many notes of no type, which nothing reads: what the unrelated statements restate.
    for index in 0..<instances {
        var note = slipRecord("", at: CGPoint(x: 1200 + Double(index % 40) * 260, y: 8_000 + Double(index / 40) * 200))
        note[TitleProperty.self] = "N" + String(format: "%04d", index)
        records.append(note)
    }
    editor.transact { transaction in for record in records { transaction.insert(record) } }
    _ = editor.validation?.results
    return editor
}

@MainActor private func cost(_ script: String, on editor: CanvasEditor) throws -> (took: Duration, warnings: Int, lines: [String]) {
    var failure: String?
    var count = 0
    var lines: [String] = []
    let took = threadCPUTime {
        do {
            let result = try draw(script: script, dryRun: true, reveal: false, program: "canvas", in: editor)
            let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
            let warnings = (json["warnings"]?.arrayValue ?? []).compactMap(\.objectValue).filter { $0["attribute"] != nil }
            count = warnings.count
            lines = warnings.map { $0["line"].map { "\($0)" } ?? "none" }
        } catch { failure = "\(error)" }
    }
    expectEqual(failure, nil)
    return (took, count, lines)
}

@MainActor let runLineCostTests = Suite("The cost of a warning's line", [
    test("K unrelated statements beside one end given a rule cost what each costs alone, not K times the notes the rule reaches") {
        let editor = try lineWorld(instances: 1_000)
        let rule = #"edge "Person" -> "Employment" endRule: {"onlyOne": true}"#
        var notes: [String] = []
        for index in 0..<1_000 { notes.append(#"edge "N\#(String(format: "%04d", index))" -> "N\#(String(format: "%04d", (index + 1) % 1_000))""#) }
        let unrelated = notes.joined(separator: "\n")
        // Each dry, so every run is over the same file.
        _ = try cost(rule, on: editor)
        let alone = try cost(rule, on: editor)
        let plain = try cost(unrelated, on: editor)
        let both = try cost(unrelated + "\n" + rule, on: editor)
        expectEqual(alone.warnings, 20)
        expectEqual(both.warnings, 20)
        expectEqual(Set(both.lines), Set(alone.lines.map { $0.replacingOccurrences(of: "1.0", with: "1001.0").replacingOccurrences(of: "(1)", with: "(1001)") }), "the rule's statement alone brought each: \(Set(both.lines)) against \(Set(alone.lines)) alone")
        let over = both.took - alone.took - plain.took
        expect(over < alone.took, "the two together took \(over) more than the two apart (\(alone.took) and \(plain.took))")
    },
    // Held loosely: it is there to catch a run that walks the board for each edge, not to hold a figure. A debug build takes
    // some 1.7 s of thread CPU alone and took 3.08 once with every test executable running at once.
    test("a run of 2,500 untyped edges asks one lookup an edge and names nothing, within six seconds of thread CPU") {
        let editor = try lineWorld(instances: 1_000)
        var edges: [String] = []
        for index in 0..<2_500 { edges.append(#"edge "N\#(String(format: "%04d", index % 1_000))" -> "N\#(String(format: "%04d", (index % 1_000 + 1 + index / 1_000) % 1_000))""#) }
        _ = try cost(edges.joined(separator: "\n"), on: editor)
        let run = try cost(edges.joined(separator: "\n"), on: editor)
        expectEqual(run.warnings, 0)
        expect(run.took < .seconds(6), "2,500 untyped edges took \(run.took) of thread CPU")
    },
])
