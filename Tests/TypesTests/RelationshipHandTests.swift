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

// The mark and the lists by hand, read-only shapes, and a commit heard out of turn.

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

/// A service installed before Types': when a memo's words become "go", it writes another memo while hearing that
/// commit, so Types hears the second commit before the first.
private struct ChaserPlugin: CanvasPlugin {
    let target: ShapeID
    var id: PluginID { "chaser" }
    func register(into registrar: inout PluginRegistrar) {
        let target = target
        registrar.service { _ in Chaser(target: target) }
    }
}

@MainActor private final class Chaser {
    let target: ShapeID
    var done = false
    init(target: ShapeID) { self.target = target }
}

extension Chaser: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !done, editor.document.shapes.contains(where: { $0.typed(as: Memo.self)?.props.text.stored == "go" }) else { return }
        done = true
        editor.transact("Chase") { $0.update(target, as: Memo.self) { $0.props.text = "chased" } }
    }
}

@MainActor let relationChecksOutOfTurnTests = Suite("Relation checks heard out of turn", [
    test("a commit heard out of turn that took the mark off: the loose end's line, the free end's and the misfit's all clear in what Validation holds") {
        let person = ShapeID(), company = ShapeID(), layer = ShapeID(), employment = ShapeID(), watcher = ShapeID(), other = ShapeID()
        let acme = ShapeID(), ann = ShapeID(), foundation = ShapeID(), misfit = ShapeID(), loose = ShapeID(), free = ShapeID()
        var related = slipTypeRecord(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 400, y: 40), id: employment)
        related[RelationshipProperty.self] = true
        var wrong = AnyShapeRecord(ShapeRecord(id: misfit, Bond(from: ann, to: foundation)))
        wrong[IsAProperty.self] = [TypeLink(employment)]
        var half = AnyShapeRecord(ShapeRecord(id: free, Bond(from: ann, to: nil)))
        half[IsAProperty.self] = [TypeLink(employment)]
        let document = CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                                               typeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200), id: company),
                                               typeRecord(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360), id: layer), related,
                                               AnyShapeRecord(ShapeRecord(id: watcher, memo("quiet", at: CGPoint(x: 700, y: 40)))),
                                               AnyShapeRecord(ShapeRecord(id: other, memo("still", at: CGPoint(x: 1000, y: 40)))),
                                               instanceRecord("Acme", of: [company], at: CGPoint(x: 400, y: 400), id: acme),
                                               instanceRecord("Ann", of: [person], at: CGPoint(x: 700, y: 400), id: ann),
                                               instanceRecord("foundation", of: [layer], at: CGPoint(x: 700, y: 700), id: foundation),
                                               AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person, to: employment))),
                                               AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: employment, to: company))),
                                               wrong, half, AnyShapeRecord(ShapeRecord(id: loose, Bond(from: employment, to: nil)))])
        let registry = try Registry(plugins: [ChaserPlugin(target: other)] + typePlugins() + [RowSlipsPlugin(), BondsPlugin(), RelaysPlugin(), PocketsPlugin()])
        let editor = CanvasEditor(registry: registry, file: CanvasFile(root: document), scheduler: ManualScheduler())
        let line = "Employment isn’t attached at both ends."
        expectEqual(editor.issues(loose).map(\.message), [line], "as opened: loose")
        expectEqual(editor.issues(free).map(\.message), [line], "as opened: free")
        expectEqual(editor.issues(misfit).map(\.message), ["Employment runs to a Company. “foundation” is a Layer."], "as opened: misfit")
        let before = editor.revision
        editor.transact("Go") { transaction in
            transaction.update(watcher, as: Memo.self) { $0.props.text = "go" }
            transaction.update(employment) { $0[RelationshipProperty.self] = nil }
        }
        expectEqual(editor.revision, before + 2, "two commits: the person's, and the service's while hearing it")
        expect(editor.relationships?.isActive == false, "no relationship type is left")
        expectEqual(editor.issues(misfit).map(\.message), [], "misfit")
        expectEqual(editor.issues(free).map(\.message), [], "free")
        expectEqual(editor.issues(loose).map(\.message), [], "loose")
        let fresh = try bondEditor(file: editor.file)
        expectEqual(try require(fresh.fieldChecks).fullCheck(of: try require(fresh.document[loose])), .clean, "a fresh read says nothing of the loose end")
    },
])
