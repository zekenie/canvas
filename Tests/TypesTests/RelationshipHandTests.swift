import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Foundation
import Mentions
import Selection
import SlashCommands
import TestKit
import Titles
import Topology
import Types
import Validation

// The mark and the lists by hand, and read-only shapes.

@MainActor private struct MenuBench {
    let h: EditorHarness
    let log: RefusalLog
    var editor: CanvasEditor { h.editor }
    let person: ShapeID, company: ShapeID, employment: ShapeID, mentorship: ShapeID
    let ann: ShapeID, acme: ShapeID, note: ShapeID, scratch: ShapeID

    init() throws {
        let log = RefusalLog()
        self.log = log
        h = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin(), FreezingPlugin(log: log)]) }
        let editor = h.editor
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        employment = editor.addRelationshipType("Employment", at: CGPoint(x: 600, y: 40))
        mentorship = editor.addRelationshipType("Mentorship", at: CGPoint(x: 600, y: 200))
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 40, y: 700))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 400, y: 700))
        note = editor.addInstance("A note", of: [], at: CGPoint(x: 760, y: 700))
        scratch = editor.addInstance("scratch", of: [], at: CGPoint(x: 1100, y: 700))
    }

    /// A step of its own, named Marker: what Undo names when nothing after it made a step.
    func mark() {
        let scratch = scratch
        editor.undoHistory.seal()
        editor.transact("Marker") { $0.update(scratch, as: Memo.self) { $0.props.text = MentionText(plain: "scratch \(UUID().uuidString)") } }
        editor.undoHistory.seal()
    }

    func middle(_ id: ShapeID) -> CGPoint {
        let frame = editor.document[id]?.box ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func menu(on id: ShapeID, selecting ids: [ShapeID]? = nil) throws -> NSMenu {
        editor.selectedShapeIDs = ids ?? [id]
        return try require(h.secondaryClick(at: middle(id)))
    }

    func isA(on id: ShapeID) throws -> OfferedSlashCommand {
        try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "is-a" }, "/is-a is offered")
    }

    @discardableResult func pick(_ title: String, on id: ShapeID) throws -> Bool {
        let command = try isA(on: id)
        let choice = try require(command.choices().first { $0.title == title }, "a row \(title)")
        return try require(editor.slashCommands).run(command, on: id, choosing: choice)
    }
}

@MainActor let relationshipHandTests = Suite("Relationship types by hand", [
    test("Relationship Type on a selection of a plain note, a plain type and a relationship type: unchecked, one step with the design's name, undo exact; then checked, Make Plain Type takes every mark and keeps every type") {
        let b = try MenuBench()
        let ids = [b.note, b.person, b.employment]
        let before = ids.map { b.editor.document[$0] }
        var outline = try b.menu(on: b.note, selecting: ids).outline
        expect(outline.contains("  Relationship Type"), "unchecked: \(outline)")
        b.mark()
        try b.menu(on: b.note, selecting: ids).choose("Is a", "Relationship Type")
        for id in ids { expect(b.editor.relationships?.graph.isRelationshipType(id) == true) }
        expectEqual(b.editor.undoHistory.undoName, "Make Relationship Type")
        b.editor.undo()
        expectEqual(b.editor.undoHistory.undoName, "Marker", "one step")
        expectEqual(ids.map { b.editor.document[$0] }, before, "undo is exact")
        b.editor.redo()
        outline = try b.menu(on: b.note, selecting: ids).outline
        expect(outline.contains("  ✓ Relationship Type"), "checked: \(outline)")
        let marked = ids.map { b.editor.document[$0] }
        try b.menu(on: b.note, selecting: ids).choose("Is a", "Relationship Type")
        expectEqual(b.editor.undoHistory.undoName, "Make Plain Type")
        for id in ids {
            expect(b.editor.types?.isType(id) == true, "the type is kept")
            expectEqual(b.editor.document[id]?[RelationshipProperty.self], nil)
        }
        b.editor.undo()
        expectEqual(ids.map { b.editor.document[$0] }, marked, "undo is exact")
    },
    test("read-only: Relationship Type, checked and unchecked, on a frozen shape changes nothing and shakes; the rest of a selection changes in the one step") {
        let b = try MenuBench()
        b.editor.freeze([b.note])
        let before = b.editor.document[b.note]
        try b.menu(on: b.note).choose("Is a", "Relationship Type")
        expectEqual(b.editor.document[b.note], before, "refused")
        expect(b.log.refusals.contains { $0.contains(b.note) }, "it shakes")
        b.log.refusals = []
        try b.menu(on: b.person, selecting: [b.person, b.note]).choose("Is a", "Relationship Type")
        expectEqual(b.editor.document[b.note], before, "the frozen one refused")
        expect(b.editor.relationships?.graph.isRelationshipType(b.person) == true, "the other marked")
        expect(b.log.refusals.contains { $0.contains(b.note) }, "and it shakes")
        expectEqual(b.editor.undoHistory.undoName, "Make Relationship Type")
        b.log.refusals = []
        b.editor.freeze([b.employment])
        let marked = b.editor.document[b.employment]
        try b.menu(on: b.employment).choose("Is a", "Relationship Type")
        expectEqual(b.editor.document[b.employment], marked, "the mark stays on a frozen relationship type")
        expect(b.log.refusals.contains { $0.contains(b.employment) }, "it shakes")
        expect(try require(b.editor.slashCommands).commands(for: b.note).first { $0.name == "is-a" } == nil, "/is-a is not offered on a read-only shape")
    },
    test("Is a ▸ on a selection of a note and an arrow: a plain type picked is given to the note and not to the arrow, a relationship type to the arrow and not to the note") {
        let b = try MenuBench()
        let job = b.editor.addBond(b.ann, b.acme)
        let outline = try b.menu(on: b.note, selecting: [b.note, job]).outline
        expect(outline.contains("  Company") && outline.contains("  Employment"), "the note's plain types and the arrow's relationship types: \(outline)")
        try b.menu(on: b.note, selecting: [b.note, job]).choose("Is a", "Company")
        expectEqual(b.editor.typesOf(b.note), [b.company], "the note is a Company")
        expectEqual(b.editor.typesOf(job), [], "an arrow cannot be given a plain type from the app")
        b.editor.undo()
        try b.menu(on: b.note, selecting: [b.note, job]).choose("Is a", "Employment")
        expectEqual(b.editor.typesOf(job), [b.employment], "the arrow is an Employment")
        expectEqual(b.editor.typesOf(b.note), [], "a relationship type on a note is not offered by the lists")
    },
    test("read-only: a frozen arrow that has a relationship type keeps its list whole when given another, and shakes") {
        let b = try MenuBench()
        let job = b.editor.addBond(b.ann, b.acme, of: [b.employment])
        b.editor.freeze([job])
        let before = b.editor.document[job]
        b.mark()
        b.editor.setRelationshipType(b.mentorship, of: [job])
        expectEqual(b.editor.document[job], before, "neither taken off nor given")
        expect(b.log.refusals.contains { $0.contains(job) }, "it shakes")
        expectEqual(b.editor.undoHistory.undoName, "Marker", "no step")
    },
    test("/is-a on an arrow that has a relationship type and a plain type: one step, and its undo returns the record exactly") {
        let b = try MenuBench()
        let job = b.editor.addBond(b.ann, b.acme, of: [b.employment, b.company])
        let before = b.editor.document[job]
        b.mark()
        try b.pick("Mentorship", on: job)
        expectEqual(b.editor.typesOf(job), [b.company, b.mentorship])
        expectEqual(b.editor.undoHistory.undoName, "Add Type")
        b.editor.undo()
        expectEqual(b.editor.undoHistory.undoName, "Marker", "one step")
        expectEqual(b.editor.document[job], before, "undo is exact, the order of the list too")
        b.editor.redo()
        expectEqual(b.editor.typesOf(job), [b.company, b.mentorship])
    },
    test("Is a ▸ on a selection of two arrows, one of a relationship type: the pick gives both the type in one step, replacing the one") {
        let b = try MenuBench()
        let first = b.editor.addBond(b.ann, b.acme, of: [b.employment])
        let second = b.editor.addBond(b.ann, b.acme)
        let before = [first, second].map { b.editor.document[$0] }
        b.mark()
        b.editor.setRelationshipType(b.mentorship, of: [first, second])
        expectEqual(b.editor.typesOf(first), [b.mentorship])
        expectEqual(b.editor.typesOf(second), [b.mentorship])
        expectEqual(b.editor.undoHistory.undoName, "Add Type")
        b.editor.undo()
        expectEqual(b.editor.undoHistory.undoName, "Marker", "one step")
        expectEqual([first, second].map { b.editor.document[$0] }, before)
    },
])
