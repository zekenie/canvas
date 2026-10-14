import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Foundation
import Mentions
import Queries
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// What a rule an end carries costs (`RelationshipRuleBenchmarks.swift`): setting Needed at a type with 10,000 notes rechecks
// every one of them in its commit, a keystroke in a ruled end's label with 1,000 notes names none, and `:incomplete` over 10,000
// notes whose row is Needed and empty lists them all.
//
// The figures below are the design's; none has been run on a quiet machine. Run them alone with
// `TEST_FILTER="Rule benchmarks" ./build.sh bench` (release, the thread's CPU).

extension Budget {
    /// A rule set at a type with 10,000 instances, until every note's check is made again (the commit, the index's
    /// announcement, Validation told, and each note's part made by the read that follows): a type-level edit like a schema
    /// edit (the thread's CPU, release). A proposal, `typeEditReachAll`'s: 190 ms.
    static let ruleFanOut10k = 190.0
    /// A keystroke in a ruled end's label with 1,000 notes of the type: one recompile, the partition equal, no note named and
    /// nothing laid out (the thread's CPU, release). A proposal: 2 ms.
    static let endLabelRuled = 2.0
    /// `:incomplete` over 10,000 notes of a type with a Needed row, none related, every one listed with its row's `problems`
    /// (what the answer takes of the main actor in slices, and what it takes off it, together; release). A proposal: 150 ms.
    static let incompleteRelations10k = 150.0
}

/// A Person type, a Company type and a relationship type Employment between them, its two ends drawn (the one at Person named
/// `jobs`, with `rule`), and `count` notes of Person in a grid. The end at Person and the first note are returned.
@MainActor private func ruledBoard(_ count: Int, rule: EndRule?) -> (document: CanvasDocument, end: ShapeID, relationship: ShapeID, note: ShapeID) {
    func type(_ title: String, at x: CGFloat, relationship: Bool = false) -> AnyShapeRecord {
        var note = ShapeRecord(StickyNote(frame: CGRect(x: x, y: -600, width: 200, height: 200), text: MentionText(plain: "")))
        note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        note[TitleProperty.self] = title
        if relationship { note[RelationshipProperty.self] = true }
        return AnyShapeRecord(note)
    }
    func bound(_ id: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }
    let person = type("Person", at: 0), company = type("Company", at: 400), employment = type("Employment", at: 800, relationship: true)
    var from = ShapeRecord(Arrow(start: bound(person.id), end: bound(employment.id)))
    from.props.text = MentionText(plain: "jobs")
    if let rule { from[RelationshipEndProperty.self] = rule }
    let to = ShapeRecord(Arrow(start: bound(employment.id), end: bound(company.id)))
    var shapes = [person, company, employment, AnyShapeRecord(from), AnyShapeRecord(to)]
    let columns = Int(Double(count).squareRoot().rounded(.up))
    var first = ShapeID()
    for place in 0..<count {
        var note = ShapeRecord(StickyNote(frame: CGRect(x: CGFloat(place % columns) * 220, y: CGFloat(place / columns) * 220, width: 200, height: 200), text: MentionText(plain: "Ann \(place)")))
        note[IsAProperty.self] = [TypeLink(person.id)]
        if place == 0 { first = note.id }
        shapes.append(AnyShapeRecord(note))
    }
    return (CanvasDocument(shapes: shapes), from.id, employment.id, first)
}

@MainActor let relationshipRuleBenchmarks = Suite("Rule benchmarks", [
    test("a rule set at a type with 10,000 notes rechecks every one of them in its commit: the type-level edit's budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let board = ruledBoard(size, rule: nil)
            let notes = board.document.shapes.filter { $0[IsAProperty.self] != nil && $0.kind == StickyNote.kind && $0[TypeSchemaProperty.self] == nil }
            var editor: CanvasEditor?
            var heard: [RelationshipChange] = []
            let set = median(runs: 5, prepare: {
                let made = CanvasEditor(registry: registry, document: board.document, scheduler: ManualScheduler())
                made.relationships?.onChange { heard.append($0) }
                // Every note's check kept, as a first read of the board leaves them.
                for record in notes { _ = made.fieldChecks?.fullCheck(of: record) }
                editor = made
            }, onThread: true) {
                guard let editor else { return }
                editor.setEndRule([board.end], needed: true)
                // What Validation's refresh reads after the commit: the check of each note, made again.
                for record in notes { _ = editor.fieldChecks?.fullCheck(of: editor.document[record.id] ?? record) }
            }
            #if DEBUG
            expectEqual(editor?.fieldChecks?.relationPartsMade ?? 0, notes.count, "a part made for each note by the read after the commit")
            #endif
            expect(heard.last?.notes.count == notes.count, "every note named once: \(heard.last?.notes.count ?? -1)")
            report(String(format: "%6d notes, a rule set at their type: %6.1f ms (budget %.0f)", notes.count, set, Budget.ruleFanOut10k))
            if holdsToBudgets, size >= 10_000 { expect(set < Budget.ruleFanOut10k, "a rule set at a type with \(notes.count) notes took \(set) ms") }
        }
    },

    test("a keystroke in a ruled end's label with 1,000 notes of the type names no note: the partition is equal and nothing is laid out") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let board = ruledBoard(1_000, rule: EndRule(needed: true, onlyOne: false))
        let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: board.document, scheduler: ManualScheduler())
        var heard: [RelationshipChange] = []
        editor.relationships?.onChange { heard.append($0) }
        // The board has been read, as the app's every frame reads it: Validation holds an issue for each of the notes, and
        // a keystroke must not make a frame check them again.
        _ = editor.validation?.results
        var n = 0
        #if DEBUG
        let made = editor.fieldChecks?.relationPartsMade ?? 0
        #endif
        let keystroke = median(runs: 60, onThread: true) {
            n += 1
            editor.transact { $0.update(board.end, as: Arrow.self) { $0.props.text = MentionText(plain: String(repeating: "j", count: n)) } }
            _ = editor.validation?.results
        }
        #if DEBUG
        expectEqual((editor.fieldChecks?.relationPartsMade ?? 0) - made, 0, "no note's check made again by a keystroke")
        #endif
        expectEqual(editor.document[board.end]?.typed(as: Arrow.self)?.props.text, MentionText(plain: String(repeating: "j", count: n)), "the keystrokes were written")
        expectEqual(heard.count, n, "one announcement a keystroke")
        expect(heard.allSatisfy { $0.notes.isEmpty && $0.layout.isEmpty && $0.rows }, "no note named, nothing laid out, a redraw")
        report(String(format: "1,000 notes, a keystroke in a ruled end's label: %6.3f ms (budget %.0f)", keystroke, Budget.endLabelRuled))
        if holdsToBudgets { expect(keystroke < Budget.endLabelRuled, "a keystroke in a ruled end's label took \(keystroke) ms") }
    },

    test(":incomplete over 10,000 notes whose Needed row is empty lists them all with their problems in the budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let registry = try Registry(plugins: shippedPlugins(pasteboard))
        for size in sizes {
            let board = ruledBoard(size, rule: EndRule(needed: true, onlyOne: false))
            var times: [Double] = []
            var count = 0, listed = 0, shown = 0
            for _ in 0..<5 {
                let editor = CanvasEditor(registry: registry, document: board.document, scheduler: ManualScheduler())
                _ = try require(editor.queries).vocabulary
                let answered = try queried(":incomplete", on: editor)
                times.append(answered.timings.main.milliseconds + answered.timings.offMain.milliseconds)
                count = answered.count
                shown = answered.rows.count
                listed = answered.rows.count { $0.problems?.first?.message == "jobs is needed" }
            }
            expectEqual(count, size, "every note is incomplete")
            expectEqual(listed, shown, "each of the rows listed says what it needs")
            let took = middle(times)
            report(String(format: "%6d notes with a Needed row, :incomplete: %6.1f ms (budget %.0f)", size, took, Budget.incompleteRelations10k))
            if holdsToBudgets, size >= 10_000 { expect(took < Budget.incompleteRelations10k, "`:incomplete` over \(size) notes took \(took) ms") }
        }
    },
])
