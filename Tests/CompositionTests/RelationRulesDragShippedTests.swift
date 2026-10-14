import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import Draw
import Foundation
import LanguageModels
import Mentions
import Queries
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation


@MainActor private func keptIssues(of id: ShapeID, in editor: CanvasEditor) -> [String] {
    _ = editor.validation?.results
    return (editor.validation?.result(for: id)?.issues ?? []).map(\.message)
}

/// What a second editor opened on the same file holds of the shape.
@MainActor private func freshIssues(of id: ShapeID, document: CanvasDocument) -> [String] {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let other = ShippedPlugins.makeEditor(document: document, pasteboard: pasteboard, model: ScriptedLanguageModel())
    _ = other.validation?.results
    return (other.validation?.result(for: id)?.issues ?? []).map(\.message)
}

@MainActor private func incompleteIDs(_ editor: CanvasEditor) throws -> Set<ShapeID> {
    let queries = try require(editor.queries)
    return Set(try awaitResult { try await queries.run(QueryRequest(":incomplete", limit: QueryBudget.maxRows)) }.rows.map(\.id))
}

@MainActor let relationRulesDragShippedTests = Suite("Rules of an end, on the shipped list, with real arrows and a real press", [
    test("a relationship's start handle dragged from a note that breaks Only one onto another note clears the first note's error, as deleting the arrow does") {
        let m = try Minute()
        defer { m.close() }
        let editor = m.editor
        let made = try m.nameTheType()
        let end = try m.featureEnd(made)
        let second = m.addLayerNote()
        // A second Feature note, below the first.
        var other = ShapeRecord(id: ShapeID(), StickyNote(frame: CGRect(x: 40, y: 900, width: 200, height: 200), text: ""))
        other[IsAProperty.self] = [TypeLink(m.feature)]
        let bo = other.id
        editor.transact { $0.insert(AnyShapeRecord(other)) }
        expect(editor.setEndRule([end], needed: true, onlyOne: true))
        // Two relationships of the first Feature note, made as a port's drag makes one.
        let registry = editor.registry
        var drawn: [ShapeID] = []
        for target in [m.layerNote, second] {
            editor.transact { transaction in
                guard var arrow = registry.drawConnection(from: m.featureNote, to: target, in: transaction.shapes, standingFor: ([], [])) else { return }
                arrow[IsAProperty.self] = [TypeLink(made)]
                drawn.append(arrow.id)
                transaction.insert(arrow)
            }
        }
        editor.undoHistory.seal()
        expectEqual(keptIssues(of: m.featureNote, in: editor), ["layer has 2 notes, and should have at most 1"])
        expectEqual(try incompleteIDs(editor), [bo], "the second Feature note has none")
        // The re-aim: the second arrow's start handle, pressed and dragged onto the other Feature note, released.
        let arrow = try require(drawn.last)
        editor.selection = arrow
        let geometry = try require(editor.arrowGeometry(of: arrow))
        m.h.move(to: m.h.view(geometry.startHandle))
        m.h.press()
        m.h.drag(to: m.h.view(try m.center(bo)), speed: 3)
        m.h.release()
        let now = try require(editor.document[arrow]?.typed(as: Arrow.self))
        expectEqual(now.props.start.binding?.shapeID, bo, "the arrow starts at the other note now")
        expectEqual(keptIssues(of: m.featureNote, in: editor), freshIssues(of: m.featureNote, document: editor.document), "the note the arrow left: Validation's kept issues against a fresh read of the file")
        let check = try require(editor.fieldChecks).fullCheck(of: try require(editor.document[m.featureNote]))
        expectEqual(check.problems.map(\.message), [], "the check of the note the arrow left")
        expectEqual(try incompleteIDs(editor), [], "the other note has a relationship now, and nothing is incomplete")
        expectEqual(try m.look(of: m.featureNote, "layer"), .plain, "the row of the note the arrow left: one pill, not red")
        expectEqual(editor.validation?.result(for: m.featureNote)?.isValid ?? true, true, "and no ring")
    },
    test("an empty Needed row is no warning of a run, and a second job drawn by a run that names only the edge leaves the note it does not restate in error on the board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let story = #"""
        sticky-note "Person" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A person"
        sticky-note "Employment" right of "Person" relationship: true schema: "{\"type\": \"object\"}" text: "A job"
        sticky-note "Company" right of "Employment" schema: "{\"type\": \"object\", \"properties\": {\"name\": {\"type\": \"string\"}}}" text: "A company"
        edge "Person" -> "Employment" text: "jobs" endRule: {"onlyOne": true}
        edge "Employment" -> "Company" text: "staff" endRule: {"needed": true}
        sticky-note "Ann" below "Person" is: "Person" fieldValues: {"name": "Ann"}
        sticky-note "Acme" below "Company" is: "Company" fieldValues: {"name": "Acme"}
        sticky-note "Beta" right of "Acme" is: "Company" fieldValues: {"name": "Beta"}
        edge "Ann" -> "Acme" is: "Employment"
        """#
        let first = try draw(story, on: board, server)
        expectEqual(first.status, 0, first.error)
        let firstWarnings = try JSON(text: first.output)["warnings"]?.arrayValue ?? []
        expect(!firstWarnings.contains { ($0["message"]?.stringValue ?? "").contains("is needed") }, "an empty Needed row (Beta's) is no warning of the run: \(firstWarnings)")
        // The second job, in a run of its own: Ann is not restated.
        let second = try draw(#"edge "Ann" -> "Beta" is: "Employment""#, on: board, server)
        expectEqual(second.status, 0, second.error)
        let editor = board.editor
        let ann = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Ann" }).id
        _ = editor.validation?.results
        expectEqual(editor.validation?.result(for: ann)?.issues.map(\.message), ["jobs has 2 notes, and should have at most 1"], "the board: Ann is red")
    },
])
