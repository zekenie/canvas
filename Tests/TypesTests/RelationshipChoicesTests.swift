import Adornments
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

// What a person can mark and what the lists offer: the mark by hand (`/is-a`'s `Relationship Type` and Is a ▸'s,
// "Make Relationship Type" and "Make Plain Type"), the pill's symbol, and the role partition of the lists of types
// (`editor.typeChoices(for:)`): an arrow is offered relationship types, the fitting first; any other shape that is
// no type, plain types; a type's own note, every type; an arrow that is an end, nothing.

@MainActor private func isA(_ editor: CanvasEditor, on id: ShapeID) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "is-a" }, "/is-a is offered")
}

/// The titles of the rows `/is-a` lists for a shape, in order.
@MainActor private func titles(_ editor: CanvasEditor, on id: ShapeID) throws -> [String] {
    try isA(editor, on: id).choices().map(\.title)
}

/// Picks the row of a title, as a list does.
@MainActor @discardableResult private func pick(_ title: String, on id: ShapeID, in editor: CanvasEditor) throws -> Bool {
    let command = try isA(editor, on: id)
    let choice = try require(command.choices().first { $0.title == title }, "a row \(title)")
    return try require(editor.slashCommands).run(command, on: id, choosing: choice)
}

/// The names of what `/is-a` offers a shape, as a list shows them.
@MainActor private func names(_ editor: CanvasEditor, for id: ShapeID) -> [String] {
    editor.typeChoices(for: id).map { $0.name ?? "Untitled" }
}

extension CanvasEditor {
    fileprivate func pill(_ id: ShapeID) -> AdornmentLabel? { adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) }?.label }
}

/// Person, Company and Layer; Employment from a Person to a Company; Mentorship from a Layer to a Layer; Loose, with
/// no ends; Ann, Acme, and a plain note.
@MainActor private struct World {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, layer: ShapeID, employment: ShapeID, mentorship: ShapeID, loose: ShapeID
    let ann: ShapeID, acme: ShapeID, note: ShapeID

    init() throws {
        editor = try bondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        employment = editor.addRelationshipType("Employment", at: CGPoint(x: 600, y: 40))
        mentorship = editor.addRelationshipType("Mentorship", at: CGPoint(x: 600, y: 200))
        loose = editor.addRelationshipType("Loose", at: CGPoint(x: 600, y: 360))
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        editor.addBond(layer, mentorship)
        editor.addBond(mentorship, layer)
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 40, y: 700))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 400, y: 700))
        note = editor.addInstance("A note", of: [], at: CGPoint(x: 760, y: 700))
    }
}

@MainActor let relationshipChoicesTests = Suite("What a person marks and what the lists offer", [
    test("a plain note becomes a relationship type in one step, Make Relationship Type: a type, marked; undo is exact") {
        let w = try World()
        let before = w.editor.document[w.note]
        w.editor.makeRelationshipType(w.note)
        expect(w.editor.types?.isType(w.note) == true)
        expectEqual(w.editor.document[w.note]?[RelationshipProperty.self], true)
        expectEqual(w.editor.document[w.note]?[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expect(w.editor.relationships?.graph.isRelationshipType(w.note) == true)
        expectEqual(w.editor.undoHistory.undoName, "Make Relationship Type")
        w.editor.undo()
        expectEqual(w.editor.document[w.note], before)
        expect(w.editor.types?.isType(w.note) == false)
        w.editor.redo()
        expectEqual(w.editor.document[w.note]?[RelationshipProperty.self], true)
    },
    test("words that are a JSON object are the schema of a note made a relationship type, as Make Type makes one") {
        let w = try World()
        let json = #"{"type":"object","properties":{"role":{"type":"string"}}}"#
        let note = w.editor.addInstance(json, of: [], at: CGPoint(x: 1000, y: 700))
        w.editor.makeRelationshipType(note)
        expectEqual(w.editor.schema(note), json)
    },
    test("a plain type is marked, a relationship type is left as it is, and a kind that cannot hold the mark is left out: nothing is a step") {
        let w = try World()
        w.editor.makeRelationshipType(w.person)
        expectEqual(w.editor.document[w.person]?[RelationshipProperty.self], true)
        expect(w.editor.relationships?.graph.isRelationshipType(w.person) == true)
        let revision = w.editor.revision
        w.editor.makeRelationshipType(w.employment)
        expectEqual(w.editor.revision, revision, "marked already")
        let bond = w.editor.addBond(w.ann, w.acme)
        let after = w.editor.revision
        w.editor.makeRelationshipTypes([bond])
        expectEqual(w.editor.revision, after, "an arrow cannot hold the mark")
        expectEqual(w.editor.document[bond]?[RelationshipProperty.self], nil)
    },
    test("several shapes are made relationship types in one step; a mark taken off leaves the type and its words, one step, Make Plain Type") {
        let w = try World()
        let second = w.editor.addInstance("Second", of: [], at: CGPoint(x: 1000, y: 700))
        w.editor.makeRelationshipTypes([w.note, second, w.company, w.employment])
        expectEqual(w.editor.undoHistory.undoName, "Make Relationship Type")
        for id in [w.note, second, w.company, w.employment] { expectEqual(w.editor.document[id]?[RelationshipProperty.self], true) }
        w.editor.undo()
        expect(w.editor.types?.isType(w.note) == false && w.editor.types?.isType(second) == false)
        expectEqual(w.editor.document[w.company]?[RelationshipProperty.self], nil, "the whole selection is one step")
        expectEqual(w.editor.document[w.employment]?[RelationshipProperty.self], true, "marked before")
        w.editor.makePlainTypes([w.employment, w.mentorship, w.person])
        expectEqual(w.editor.undoHistory.undoName, "Make Plain Type")
        for id in [w.employment, w.mentorship] {
            expectEqual(w.editor.document[id]?[RelationshipProperty.self], nil)
            expect(w.editor.types?.isType(id) == true, "still a type")
        }
        expectEqual(w.editor.title(w.employment), "Employment")
        expect(w.editor.relationships?.graph.isRelationshipType(w.employment) == false)
        w.editor.undo()
        expectEqual(w.editor.document[w.employment]?[RelationshipProperty.self], true)
        expectEqual(w.editor.document[w.mentorship]?[RelationshipProperty.self], true)
        let revision = w.editor.revision
        w.editor.makePlainTypes([w.person, w.note])
        expectEqual(w.editor.revision, revision, "unmarked already: no step")
    },
    test("a relationship type shows no title pill above it (it is a pill itself), a plain type's has braces, and a plain note's is as it was") {
        let w = try World()
        expectEqual(w.editor.pill(w.employment), nil, "its name is on the pill it is drawn as")
        expectEqual(w.editor.pill(w.person)?.systemImage, "curlybraces")
        w.editor.makePlainTypes([w.employment])
        expectEqual(w.editor.pill(w.employment)?.systemImage, "curlybraces", "unmarked")
        expectEqual(w.editor.pill(w.employment)?.text, "Employment")
        w.editor.undo()
        expectEqual(w.editor.pill(w.employment), nil)
        let untitled = w.editor.addRelationshipType(nil, at: CGPoint(x: 1000, y: 40))
        expectEqual(w.editor.pill(untitled), nil, "untitled too")
        w.editor.removeType(w.employment)
        expect(w.editor.pill(w.employment)?.systemImage == nil, "Remove Type: a plain note's pill")
    },
    test("/is-a lists Relationship Type beside Type on a plain note and a plain type, never on a relationship type or an arrow; picking it marks the shape") {
        let w = try World()
        expectEqual(try titles(w.editor, on: w.note).prefix(2), ["Type", "Relationship Type"])
        expectEqual(try titles(w.editor, on: w.person).prefix(1), ["Relationship Type"], "a type already: no Type row")
        let onMarked = try titles(w.editor, on: w.employment)
        expect(!onMarked.contains("Relationship Type"), "already one")
        let bond = w.editor.addBond(w.ann, w.acme)
        let onArrow = try titles(w.editor, on: bond)
        expect(!onArrow.contains("Relationship Type") && !onArrow.contains("Type"), "an arrow cannot hold the mark")
        try pick("Relationship Type", on: w.note, in: w.editor)
        expectEqual(w.editor.document[w.note]?[RelationshipProperty.self], true)
        expect(w.editor.types?.isType(w.note) == true)
        expectEqual(w.editor.undoHistory.undoName, "Make Relationship Type")
        try pick("Relationship Type", on: w.person, in: w.editor)
        expectEqual(w.editor.document[w.person]?[RelationshipProperty.self], true)
        expectEqual(w.editor.undoHistory.undoName, "Make Relationship Type")
        w.editor.undo()
        expectEqual(w.editor.document[w.person]?[RelationshipProperty.self], nil)
    },
    test("a name typed that is the list's own words offers no new type: Type and Relationship Type, in any case") {
        let w = try World()
        let command = try isA(w.editor, on: w.note)
        for typed in ["type", "Relationship Type", "RELATIONSHIP TYPE", "  relationship   type "] {
            expect(command.choice(otherwise: typed) == nil, "no New type row for \(typed)")
        }
        expectEqual(command.choice(otherwise: "mentor")?.title, "New type “Mentor”")
    },
    test("an arrow is offered relationship types only, the fitting first, then the open, then the rest; a note, plain types; a type's own note, every type") {
        let w = try World()
        let job = w.editor.addBond(w.ann, w.acme)
        let choices = w.editor.typeChoices(for: job)
        expectEqual(choices.map { $0.name ?? "Untitled" }, ["Employment", "Loose", "Mentorship"])
        expectEqual(choices.map(\.fit), [.taken, .open, .no])
        expectEqual(try titles(w.editor, on: job), ["Employment", "Loose", "Mentorship"], "/is-a: no Type, no Relationship Type")
        let groups = try isA(w.editor, on: job).choices().map(\.group)
        expectEqual(groups, [1, 1, 2], "the rest are apart")
        expectEqual(names(w.editor, for: w.ann), ["Company", "Layer"], "a note: plain types, never a relationship type; its own Person is not offered again")
        expectEqual(names(w.editor, for: w.note), ["Company", "Layer", "Person"])
        expectEqual(w.editor.typeChoices(for: w.note).map(\.fit), [.open, .open, .open])
        expectEqual(names(w.editor, for: w.person), ["Company", "Employment", "Layer", "Loose", "Mentorship"], "a type's own note: every type")
        // The index's own list is every type there is to be, as it was.
        expectEqual(w.editor.types?.choices(for: job).map { $0.name ?? "" }, ["Company", "Employment", "Layer", "Loose", "Mentorship", "Person"])
    },
    test("an arrow not bound at both ends is offered every relationship type, open; one whose end is a type's own note, none taken") {
        let w = try World()
        let half = w.editor.addBond(w.ann, nil)
        expectEqual(w.editor.typeChoices(for: half).map(\.fit), [.open, .open, .open])
        let toType = w.editor.addBond(w.ann, w.company)
        expectEqual(w.editor.typeChoices(for: toType).map(\.fit), [.no, .no, .no], "a type's note is no instance: offered, but nothing fits")
    },
    test("an arrow that is an end is of nothing: no rows, no new type, no Is a ▸") {
        let w = try World()
        let end = w.editor.addBond(w.person, w.loose)
        expect(w.editor.relationships?.end(end) != nil)
        expectEqual(w.editor.typeChoices(for: end).count, 0)
        expectEqual(try titles(w.editor, on: end), [])
        expect(try isA(w.editor, on: end).choice(otherwise: "mentor") == nil, "no New type row")
    },
    test("Is a ▸ and /is-a on an arrow that has a relationship type replace it, in one step, Add Type; two undos' worth would be a bug") {
        let w = try World()
        let job = w.editor.addBond(w.ann, w.acme, of: [w.employment])
        try pick("Mentorship", on: job, in: w.editor)
        expectEqual(w.editor.typesOf(job), [w.mentorship])
        expectEqual(w.editor.undoHistory.undoName, "Add Type")
        w.editor.undo()
        expectEqual(w.editor.typesOf(job), [w.employment], "one step puts it back")
        w.editor.setRelationshipType(w.loose, of: [job])
        expectEqual(w.editor.typesOf(job), [w.loose])
        expectEqual(w.editor.undoHistory.undoName, "Add Type")
        w.editor.setRelationshipType(w.loose, of: [job, w.ann])
        expectEqual(w.editor.typesOf(w.ann), [w.person], "a note is no arrow: left as it is")
        // A plain type on an arrow is legal, and stays alongside; the replacement takes the relationship types only.
        w.editor.addTypeLink(w.company, to: job)
        w.editor.setRelationshipType(w.mentorship, of: [job])
        expectEqual(w.editor.typesOf(job), [w.company, w.mentorship])
    },
    test("/is-a <new name> on an arrow makes a relationship type with no ends in the step New Relationship Type, and replaces the arrow's own") {
        let w = try World()
        let job = w.editor.addBond(w.ann, w.acme, of: [w.employment])
        let command = try isA(w.editor, on: job)
        let row = try require(command.choice(otherwise: "mentor"))
        expectEqual(row.title, "New type “Mentor”")
        expectEqual(row.step, "New Relationship Type")
        let made = try require(w.editor.newType(named: "Mentor", besides: job))
        expectEqual(w.editor.undoHistory.undoName, "New Relationship Type")
        expectEqual(w.editor.document[made]?[RelationshipProperty.self], true)
        expect(w.editor.relationships?.graph.isRelationshipType(made) == true)
        expect(w.editor.relationships?.graph.sides(of: made).isEmpty == true, "no ends")
        expectEqual(w.editor.typesOf(job), [made], "the arrow's Employment is replaced")
        w.editor.undo()
        expectEqual(w.editor.typesOf(job), [w.employment])
        expect(w.editor.document[made] == nil, "one step takes the type with it")
        // A note's: a plain type, the step it always was.
        let plain = try require(w.editor.newType(named: "Pal", besides: w.note))
        expectEqual(w.editor.undoHistory.undoName, "New Type")
        expectEqual(w.editor.document[plain]?[RelationshipProperty.self], nil)
        expectEqual(w.editor.typesOf(w.note), [plain])
    },
    test("nothing is refused: a plain type can be put on an arrow and a relationship type on a note by a script or by hand, and the index admits both as it did") {
        let w = try World()
        let job = w.editor.addBond(w.ann, w.acme)
        w.editor.addTypeLink(w.person, to: job)
        expectEqual(w.editor.typesOf(job), [w.person], "a plain type on an arrow")
        w.editor.addTypeLink(w.employment, to: w.note)
        expectEqual(w.editor.typesOf(w.note), [w.employment], "a relationship type on a note")
    },
])

@MainActor private struct Bench {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }

    init() throws {
        h = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin()]) }
    }

    func middle(_ id: ShapeID) -> CGPoint {
        let frame = editor.document[id]?.box ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func menu(on id: ShapeID, selecting ids: [ShapeID]? = nil) throws -> NSMenu {
        editor.selectedShapeIDs = ids ?? [id]
        return try require(h.secondaryClick(at: middle(id)))
    }
}

@MainActor let relationshipMenuTests = Suite("Is a ▸ and the mark", [
    test("the submenu holds Type, Relationship Type, a line, then the plain types of a note, checked by what it is") {
        let b = try Bench()
        let person = b.editor.addType(TypeSchemaProperty.starter, title: "Person")
        let employment = b.editor.addRelationshipType("Employment", at: CGPoint(x: 400, y: 40))
        let note = b.editor.addInstance("Ann", of: [person], at: CGPoint(x: 40, y: 400))
        let outline = try b.menu(on: note).outline
        let at = try require(outline.firstIndex(of: "Is a ▸"))
        expectEqual(Array(outline[at...].prefix(5)), ["Is a ▸", "  Type", "  Relationship Type", "  —", "  ✓ Person"])
        _ = employment
    },
    test("choosing Relationship Type on a note makes it one in a step; checked on a relationship type takes the mark off alone") {
        let b = try Bench()
        let note = b.editor.addInstance("Ann", of: [], at: CGPoint(x: 40, y: 400))
        try b.menu(on: note).choose("Is a", "Relationship Type")
        expectEqual(b.editor.document[note]?[RelationshipProperty.self], true)
        expect(b.editor.types?.isType(note) == true)
        expectEqual(b.editor.undoHistory.undoName, "Make Relationship Type")
        let outline = try b.menu(on: note).outline
        expect(outline.contains("  ✓ Type") && outline.contains("  ✓ Relationship Type"), "\(outline)")
        try b.menu(on: note).choose("Is a", "Relationship Type")
        expectEqual(b.editor.document[note]?[RelationshipProperty.self], nil)
        expect(b.editor.types?.isType(note) == true, "still a type")
        expectEqual(b.editor.undoHistory.undoName, "Make Plain Type")
        b.editor.undo()
        expectEqual(b.editor.document[note]?[RelationshipProperty.self], true)
    },
    test("unchecking Type on a relationship type is Remove Type, which clears the mark with the schema") {
        let b = try Bench()
        let employment = b.editor.addRelationshipType("Employment", at: CGPoint(x: 400, y: 40))
        try b.menu(on: employment).choose("Is a", "Type")
        expectEqual(b.editor.undoHistory.undoName, "Remove Type")
        expectEqual(b.editor.document[employment]?[RelationshipProperty.self], nil)
        expectEqual(b.editor.document[employment]?[TypeSchemaProperty.self], nil)
    },
    test("the release and the lists agree: what a port's release takes or lists is what `/is-a` calls taken and open on the arrow, in its order, and a pick from either replaces the type in one step") {
        _ = NSApplication.shared
        let w = try World()
        // A second type from a Person to a Company, and an open one: Ann to Acme fits Employment and Mentoring, and Loose is open.
        let mentoring = w.editor.addRelationshipType("Mentoring", at: CGPoint(x: 600, y: 520))
        w.editor.addBond(w.person, mentoring)
        w.editor.addBond(mentoring, w.company)
        let bond = w.editor.addBond(w.ann, w.acme)
        let taken = w.editor.typeChoices(for: bond).filter { $0.fit == .taken }.map(\.type), open = w.editor.typeChoices(for: bond).filter { $0.fit == .open }.map(\.type)
        expectEqual(taken, [w.employment, mentoring])
        expectEqual(w.editor.connectionDrawn(bond), .offered(taken: taken, open: open))
        let menu = try require(w.editor.menuToPopUp).menu
        expectEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Employment", "Mentoring", "Loose", "Plain arrow"])
        // /is-a's rows for the arrow list the same types, the fitting first.
        let rows = try titles(w.editor, on: bond)
        expectEqual(rows.prefix(3).map { $0 }, ["Employment", "Mentoring", "Loose"])
        menu.performActionForItem(at: 1)
        expectEqual(w.editor.typesOf(bond), [mentoring])
        try pick("Employment", on: bond, in: w.editor)
        expectEqual(w.editor.typesOf(bond), [w.employment], "a pick from `/is-a` replaces it, as a pick from the list does")
        expectEqual(w.editor.undoHistory.undoName, "Add Type")
        w.editor.undo()
        expectEqual(w.editor.typesOf(bond), [mentoring], "in one step")
    },
    test("a selection of notes and types is checked only when every shape is one; a selection with an arrow has no Relationship Type") {
        let b = try Bench()
        let a = b.editor.addInstance("A", of: [], at: CGPoint(x: 40, y: 400))
        let second = b.editor.addRelationshipType("Employment", at: CGPoint(x: 400, y: 40))
        var outline = try b.menu(on: a, selecting: [a, second]).outline
        expect(outline.contains("  Relationship Type") && !outline.contains("  ✓ Relationship Type"), "\(outline)")
        try b.menu(on: a, selecting: [a, second]).choose("Is a", "Relationship Type")
        expectEqual(b.editor.undoHistory.undoName, "Make Relationship Type")
        expect(b.editor.relationships?.graph.isRelationshipType(a) == true)
        outline = try b.menu(on: a, selecting: [a, second]).outline
        expect(outline.contains("  ✓ Relationship Type"), "\(outline)")
        let bond = b.editor.addBond(a, second)
        outline = try b.menu(on: a, selecting: [a, bond]).outline
        expect(!outline.contains("  Relationship Type") && !outline.contains("  ✓ Relationship Type"), "an arrow cannot hold the mark: \(outline)")
    },
])
