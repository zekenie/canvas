import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasRPC
import CanvasUI
import Draw
import Foundation
import LanguageModels
import Mentions
import Queries
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// Needed and Only one on the shipped list, with real notes and real arrows, after the first minute's drag (`Minute`): an end
// marked Needed turns every empty row amber and lists the notes in `:incomplete`, a pick clears it; with Only one a second pick
// replaces the first, and a second arrow drawn by hand is red on the note. Each with its one Undo.

@MainActor private func incomplete(_ editor: CanvasEditor) throws -> QueryResult {
    let queries = try require(editor.queries)
    return try awaitResult { try await queries.run(QueryRequest(":incomplete", limit: QueryRequest.every)) }
}

@MainActor private func issues(of id: ShapeID, in editor: CanvasEditor) -> [ValidationIssue] {
    _ = editor.validation?.results
    return editor.validation?.result(for: id)?.issues ?? []
}

extension Minute {
    /// The arrow from the Feature type into the relationship type: the end at Feature.
    func featureEnd(_ type: ShapeID) throws -> ShapeID {
        try require(arrows.first { $0.props.start.binding?.shapeID == feature && $0.props.end.binding?.shapeID == type }, "the end at Feature").id
    }

    /// What the check says of a note's row, and the look it gives the row.
    func look(of note: ShapeID, _ name: String) throws -> RowLook {
        let row = try require(rows.rows(of: note).first { $0.name == name }, "a row \(name)")
        let check = try require(editor.fieldChecks).check(of: try require(editor.document[note]))
        return RowLook.of(content: row.content, mark: row.relation.flatMap { check.mark(at: $0) })
    }

    /// The relationships: the arrows of the relationship type that are bound at both ends to notes.
    func relationships(of type: ShapeID) -> [ShapeID] {
        arrows.filter { $0[IsAProperty.self]?.map(\.shape) == [type] && $0.props.start.binding?.shapeID == featureNote }.map(\.id)
    }

    /// A second Layer note, with a value, below the first.
    func addLayerNote() -> ShapeID {
        var record = ShapeRecord(id: ShapeID(), StickyNote(frame: CGRect(x: 1000, y: 760, width: 200, height: 200), text: ""))
        record[IsAProperty.self] = [TypeLink(layer)]
        record[FieldValuesProperty.self] = FieldValues(["order": 2, "purpose": "serve foobar", "title": "roof"])
        let made = AnyShapeRecord(record)
        editor.transact { $0.insert(made) }
        editor.undoHistory.seal()
        return made.id
    }
}

@MainActor let relationRulesShippedTests = Suite("Needed and Only one, shipped", [
    test("an end marked Needed turns every empty row amber and lists the notes in :incomplete with their problems; a pick in the row clears it, an Undo brings it back; the rule's own Undo takes the amber away") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        let end = try m.featureEnd(made)
        let second = m.addLayerNote()
        let featureNote2 = AnyShapeRecord({
            var record = ShapeRecord(id: ShapeID(), StickyNote(frame: CGRect(x: 300, y: 500, width: 200, height: 200), text: ""))
            record[IsAProperty.self] = [TypeLink(m.feature)]
            return record
        }())
        editor.transact { $0.insert(featureNote2) }
        editor.undoHistory.seal()
        expectEqual(try incomplete(editor).rows.count, 0, "no rule: nothing is incomplete")
        expectEqual(try m.look(of: m.featureNote, "in"), .empty)
        // Needed: one step, every Feature note's empty row amber, and the Layer note's row untouched.
        let before = editor.document
        expect(editor.setEndRule([end], needed: true))
        expectEqual(editor.undoHistory.undoName, "Make Needed")
        let listed = try incomplete(editor)
        expectEqual(Set(listed.rows.map(\.id)), [m.featureNote, featureNote2.id])
        let problems = try require(listed.rows.first { $0.id == m.featureNote }?.problems)
        expectEqual(problems.map(\.message), ["in is needed"])
        expectEqual(problems.map(\.problemClass), ["needed"])
        expectEqual(problems.map(\.field), ["in"])
        expectEqual(try m.look(of: m.featureNote, "in"), .needed)
        expectEqual(try m.look(of: featureNote2.id, "in"), .needed)
        expectEqual(try m.look(of: m.layerNote, "feature"), .empty, "Layer's row asks nothing")
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: m.featureNote)?.issues.map(\.severity), [.incomplete], "amber is the third level")
        expect(editor.validation?.result(for: m.featureNote)?.isValid ?? true, "valid")
        expectEqual(editor.validation?.result(for: m.featureNote)?.worst, nil, "no ring")
        // The type's row has the dot.
        expect(m.rows.rows(of: m.feature).contains { $0.name == "in" })
        // A pick in the row: the note is complete; Undo brings the amber back; the other note stays amber.
        expect(try m.click(row: "in", of: m.featureNote))
        m.window.pressReturn()
        editor.endEditing()
        expectEqual(editor.undoHistory.undoName, "Add Relationship")
        expectEqual(Set(try incomplete(editor).rows.map(\.id)), [featureNote2.id])
        expectEqual(try m.look(of: m.featureNote, "in"), .plain)
        editor.undo()
        expectEqual(Set(try incomplete(editor).rows.map(\.id)), [m.featureNote, featureNote2.id], "one Undo takes the arrow away")
        editor.undo()
        expectEqual(editor.document, before, "and one more the rule")
        expectEqual(try incomplete(editor).rows.count, 0)
        editor.redo()
        expectEqual(try incomplete(editor).rows.count, 2)
        _ = second
    },
    test("with Only one a second pick replaces the first in one step and one Undo; a second arrow drawn by hand is red on the note, the pills red, an error in Issues, and none on the arrows; deleting one clears it") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        let end = try m.featureEnd(made)
        let second = m.addLayerNote()
        expect(editor.setEndRule([end], onlyOne: true))
        expectEqual(editor.undoHistory.undoName, "Allow Only One")
        // The first pick: the only Layer note the list holds is the one; then the second Layer note replaces it.
        expect(try m.click(row: "in", of: m.featureNote))
        m.window.pressReturn()
        editor.endEditing()
        let first = try require(m.relationships(of: made).first)
        expectEqual(m.relationships(of: made).count, 1)
        editor.undoHistory.seal()
        let afterFirst = editor.document
        expect(try m.click(row: "in", of: m.featureNote))
        expectEqual(m.listed, ["2 · serve foobar · roof"], "the note at the row is not listed")
        m.window.pressReturn()
        editor.endEditing()
        expectEqual(editor.undoHistory.undoName, "Add Relationship")
        let replacement = try require(m.relationships(of: made).first)
        expectEqual(m.relationships(of: made).count, 1, "replaced, not added")
        expect(replacement != first && editor.document[first] == nil)
        expectEqual(editor.document[replacement]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, second)
        expectEqual(try m.look(of: m.featureNote, "in"), .plain)
        editor.undo()
        expectEqual(editor.document, afterFirst, "one Undo returns the first")
        // By hand: a second arrow made as a port's drag makes one (the maker and the type taken), no pick and so no replacing. (A
        // press at the note's port is on the first arrow's end: a drag from there moves that arrow.)
        let registry = editor.registry
        editor.transact { transaction in
            guard var arrow = registry.drawConnection(from: m.featureNote, to: second, in: transaction.shapes, standingFor: ([], [])) else { return }
            arrow[IsAProperty.self] = [TypeLink(made)]
            transaction.insert(arrow)
        }
        editor.undoHistory.seal()
        let both = m.relationships(of: made)
        expectEqual(both.count, 2, "nothing was replaced or refused")
        expectEqual(editor.validation?.result(for: m.featureNote)?.isValid, false, "the note rings")
        expectEqual(issues(of: m.featureNote, in: editor).map(\.message), ["in has 2 notes, and should have at most 1"])
        expectEqual(issues(of: m.featureNote, in: editor).first?.severity, .error)
        expectEqual(both.flatMap { issues(of: $0, in: editor) }, [], "none on the arrows")
        expectEqual(try m.look(of: m.featureNote, "in"), .wrong)
        expectEqual(Set(try incomplete(editor).rows.map(\.id)), [], "it is wrong and not incomplete")
        editor.undo()
        expectEqual(m.relationships(of: made).count, 1, "one Undo takes the hand-drawn arrow")
        expectEqual(issues(of: m.featureNote, in: editor), [])
        expectEqual(try m.look(of: m.featureNote, "in"), .plain)
        editor.redo()
        let extra = m.relationships(of: made)
        expectEqual(extra.count, 2)
        if let hand = extra.last { editor.transact { $0.delete([hand]) } }
        expectEqual(issues(of: m.featureNote, in: editor), [], "deleting one clears it")
    },
    test("a run says it too: a note drawn against the ends the same script draws carries a Needed row left empty and an Only one row broken as problems named by the row, the dry run says the same, and the board then agrees") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let editor = board.editor
        let script = #"""
        sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A person"
        sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\"}" text: "A job"
        sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company"
        edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
        edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}
        sticky-note "Ann" below "Person" is: "Person" fieldValues: {"name": "Ann"}
        sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
        sticky-note "Beta" right of "Acme" is: "Company" fieldValues: {"name": "Beta"}
        sticky-note "Cy" below "Beta" is: "Company" fieldValues: {"name": "Cy"}
        edge "Ann" -> "Acme" is: "Employment"
        edge "Ann" -> "Beta" is: "Employment"
        """#
        func problems(_ output: ProcessOutput) throws -> [String: [String]] {
            let json = try JSON(text: output.output)
            var found: [String: [String]] = [:]
            for row in json["changes"]?.arrayValue ?? [] where row["kind"] == "sticky-note" {
                guard let title = row["title"]?.stringValue else { continue }
                found[title] = (row["problems"]?.arrayValue ?? []).map { "\($0["field"]?.stringValue ?? "?") \($0["class"]?.stringValue ?? "?"): \($0["message"]?.stringValue ?? "?")" }
            }
            return found
        }
        let dry = try draw(script, on: board, server, ["--dry-run"])
        expectEqual(dry.status, 0, dry.error)
        let ran = try draw(script, on: board, server)
        expectEqual(ran.status, 0, ran.error)
        let said = try problems(ran)
        expectEqual(said["Ann"], ["jobs wrong: jobs has 2 notes, and should have at most 1"])
        expectEqual(said["Cy"], ["staff needed: staff is needed"])
        expectEqual(said["Acme"], [], "Ann works at it")
        expectEqual(said["Beta"], [])
        expectEqual(try problems(dry), said, "a dry run says the same")
        let warnings = try JSON(text: ran.output)["warnings"]?.arrayValue ?? []
        expect(warnings.contains { $0["severity"]?.stringValue == "error" && ($0["message"]?.stringValue ?? "").contains("jobs has 2 notes") }, "the run's error warning: \(warnings)")
        // The board then says the same, and drawing it again says the same of each.
        let ann = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Ann" }).id
        let cy = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Cy" }).id
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: ann)?.issues.map(\.message), ["jobs has 2 notes, and should have at most 1"])
        expectEqual(editor.validation?.result(for: cy)?.issues.map(\.message), ["staff is needed"], "amber is the third level")
        expectEqual(editor.validation?.result(for: cy)?.worst, nil, "and rings nothing")
        let again = try draw(script, on: board, server)
        expectEqual(try problems(again), said, "again, the same")
        expect((try JSON(text: again.output)["changes"]?.arrayValue ?? []).allSatisfy { $0["did"]?.stringValue == "unchanged" })
        let found = try JSON(text: canvas(server, ["query", ":incomplete"]).output)
        expectEqual(found["rows"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Cy"])
        let invalid = try JSON(text: canvas(server, ["query", "sticky-note:invalid"]).output)
        expectEqual(invalid["rows"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Ann"])
    },
])
