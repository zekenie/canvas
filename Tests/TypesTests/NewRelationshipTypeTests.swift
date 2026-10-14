import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Geometry
import Mentions
import Selection
import TestKit
import Titles
import Types
import Validation

// The drag between two types: a relationship type put between them, with an arrow to it from the first and another
// from it to the second, in place of the arrow the drag drew; selected and not edited; one step, "New Relationship
// Type"; and the card that names it, shown by the writer itself inside that step, so one Undo, once the card is
// dismissed, takes back the note, both arrows and the name. Over memos (a kind with a tool) and bonds, with the
// engine of `canvas draw` making the arrows.

/// Person at the left, Company far at the right, and the arrow a port's drag drew between them.
@MainActor private struct Gesture {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID
    let bond: ShapeID

    init(apart: CGFloat = 900, editor made: CanvasEditor? = nil) throws {
        editor = try made ?? typeEditorWithDraw()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: apart, y: 40))
        bond = editor.addBond(person, company)
        for n in 0..<3 {
            editor.addInstance("Ann \(n)", of: [person], at: CGPoint(x: 40, y: 300 + 100 * Double(n)))
            editor.addInstance("Acme \(n)", of: [company], at: CGPoint(x: apart, y: 300 + 100 * Double(n)))
        }
    }

    func frame(_ id: ShapeID) throws -> CGRect { try require(editor.shapeContext.frame(of: id), "a frame") }

    /// The shapes the board has that these ids did not.
    func added(since known: Set<ShapeID>) -> [AnyShapeRecord] { editor.document.shapes.filter { !known.contains($0.id) } }

    var ids: Set<ShapeID> { Set(editor.document.shapes.map(\.id)) }

    /// The bonds from `from` to `to`.
    func bonds(from: ShapeID, to: ShapeID) -> [ShapeID] {
        editor.document.shapes.compactMap { record in
            guard let bond = record.typed(as: Bond.self)?.props, bond.from == from, bond.to == to else { return nil }
            return record.id
        }
    }
}


/// Bonds made as the tests' own maker makes them, remembering how many connections the maker was told already joined each
/// pair (`EdgeRequest.beside`: what a maker that draws a second arrow apart from the first reads).
@MainActor final class BesideLog {
    /// `present`: every arrow named beside was in the document the maker was given.
    var made: [(from: ShapeID, to: ShapeID, beside: [ShapeID]?, present: Bool)] = []
}

struct RecordingBondEdgesPlugin: CanvasPlugin {
    let log: BesideLog
    var id: PluginID { "recording-bond-edges" }
    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.drawEdges(kind: { _ in Bond.kind },
                            attributes: [],
                            identity: [IsAProperty.key.rawValue],
                            sides: { _, _ in [:] },
                            ends: { record, _ in
                                guard let bond = record.typed(as: Bond.self)?.props, let from = bond.from, let to = bond.to else { return nil }
                                return (from, to)
                            },
                            make: { request, existing, shapes in
                                let present = (request.beside ?? []).allSatisfy { shapes.document[$0] != nil }
                                MainActor.assumeIsolated { log.made.append((request.from, request.to, request.beside, present)) }
                                return existing ?? AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: request.from, to: request.to)))
                            })
    }
}

/// An editor that draws bonds and tells a log how each was asked for.
@MainActor func selfEditor(_ log: BesideLog) throws -> CanvasEditor {
    let editor = try bondEditor(more: [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), RecordingBondEdgesPlugin(log: log)])
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// The text field inside the card shown.
@MainActor private func field(of card: CanvasCard) throws -> NSTextView {
    try require(card.view.subviews.compactMap { $0 as? NSTextView }.first, "the card's field")
}

@MainActor private func type(_ text: String, into field: NSTextView) {
    field.insertText(text, replacementRange: NSRange(location: (field.string as NSString).length, length: 0))
}

@MainActor let newRelationshipTypeTests = Suite("A relationship type between two types", [
    test("three shapes the board did not have and no arrow from one type to the other: a marked type with the starter schema, no words and no title, overlapping neither, and an arrow to it and one from it") {
        let g = try Gesture()
        let before = g.ids
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        let added = g.added(since: before)
        expectEqual(added.count, 3, "the new type and its two arrows: \(added.map(\.kind))")
        expect(g.editor.document[g.bond] == nil, "the arrow the drag drew is gone")
        expectEqual(g.bonds(from: g.person, to: g.company), [], "and no arrow runs from one type to the other")
        let relationship = try require(g.editor.document[made])
        expectEqual(relationship[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expectEqual(relationship[RelationshipProperty.self], true)
        expectEqual(g.editor.words(made)?.stored, "")
        expectEqual(relationship[TitleProperty.self], nil)
        expect(g.editor.relationships?.graph.isRelationshipType(made) == true)
        expectEqual(g.bonds(from: g.person, to: made).count, 1)
        expectEqual(g.bonds(from: made, to: g.company).count, 1)
        let box = try g.frame(made), personBox = try g.frame(g.person), companyBox = try g.frame(g.company)
        expect(!box.intersects(personBox) && !box.intersects(companyBox), "overlapping neither: \(box)")
        // Room for each arrow's body: the type's box is the gap's middle with the end arrows' room each side.
        expect(box.minX >= personBox.maxX + TypesStyle.endArrowRoom - 0.5, "room for the arrow from Person: \(box)")
        expect(box.maxX <= companyBox.minX - TypesStyle.endArrowRoom + 0.5, "and for the one to Company: \(box)")
        // Both end types gain the end at once.
        expectEqual(g.editor.relationships?.graph.sides(of: made).from.map(\.type), [g.person])
        expectEqual(g.editor.relationships?.graph.sides(of: made).to.map(\.type), [g.company])
        expectEqual(g.editor.relationships?.rows(for: [g.person], isType: false).count, 1, "a Person note has a row for it")
        expectEqual(g.editor.relationships?.rows(for: [g.company], isType: false).count, 1, "and a Company note")
    },
    test("it is selected and not edited, the card that names it is shown at its pill inside the step, and the step is named New Relationship Type") {
        let g = try Gesture()
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        expectEqual(g.editor.selectedShapeIDs, [made])
        expect(g.editor.editingShapeID == nil, "never edited")
        let card = try require(g.editor.card, "the name card")
        expectEqual(card.shape, made)
        expectEqual(card.anchor, g.editor.titlePillRect(of: made))
        expect(card.adoptsPress)
        expectEqual(card.stepName, TypesStyle.nameRelationshipType)
        expectEqual(g.editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        g.editor.closeCard()
    },
    test("one Undo, once the card is dismissed, takes back the note, both arrows and the name, and brings back the arrow and the selection; Redo brings all back") {
        let g = try Gesture()
        g.editor.selection = g.person
        let start = g.editor.document
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        let drawn = g.editor.document
        let card = try require(g.editor.card)
        type("in", into: try field(of: card))
        expectEqual(g.editor.document[made]?[TitleProperty.self], "in")
        g.editor.closeCard()
        expectEqual(g.editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        g.editor.undo()
        expectEqual(g.editor.document, start, "the board as it was, the arrow the drag drew back")
        expectEqual(g.editor.selectedShapeIDs, [g.person], "and the selection")
        expect(!g.editor.canUndo || g.editor.undoHistory.undoName != TypesStyle.newRelationshipType, "one step")
        g.editor.redo()
        expect(g.editor.document[made]?[TitleProperty.self] == "in", "named again")
        expectEqual(g.editor.document.shapes.count, drawn.shapes.count)
        expectEqual(g.editor.selectedShapeIDs, [made])
    },
    test("the closer the two types are, the nearer it lands: with room between them it is across the gap; with none, beside the middle and clear of both") {
        let roomy = try Gesture(apart: 900)
        let made = try require(roomy.editor.newRelationshipType(from: roomy.person, to: roomy.company, replacing: roomy.bond))
        let between = try roomy.frame(made), left = try roomy.frame(roomy.person), right = try roomy.frame(roomy.company)
        expect(between.midX > left.maxX && between.midX < right.minX, "between")
        roomy.editor.closeCard()
        let tight = try Gesture(apart: 330)
        let beside = try require(tight.editor.newRelationshipType(from: tight.person, to: tight.company, replacing: tight.bond))
        let box = try tight.frame(beside), personBox = try tight.frame(tight.person), companyBox = try tight.frame(tight.company)
        expect(!box.intersects(personBox) && !box.intersects(companyBox), "clear of both: \(box)")
        tight.editor.closeCard()
    },
    test("a drag with nothing that makes connections, or an end that is not on the board shown, makes nothing and leaves the arrow") {
        let plain = try bondEditor()
        let person = plain.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = plain.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 900, y: 40))
        let bond = plain.addBond(person, company)
        let before = plain.document
        expectEqual(plain.newRelationshipType(from: person, to: company, replacing: bond), nil, "no Draw, no connection")
        expectEqual(plain.document, before)
        expect(plain.card == nil && !plain.canUndo || plain.undoHistory.undoName != TypesStyle.newRelationshipType)
        let g = try Gesture()
        let kept = g.editor.document
        expectEqual(g.editor.newRelationshipType(from: g.person, to: ShapeID(), replacing: g.bond), nil, "an end that is nowhere")
        expectEqual(g.editor.document, kept)
    },
    test("a connection that could not be made throws the whole step away: nothing is left, no step, and the arrow stays") {
        // An end that cannot be connected: a bond's maker refuses nothing, so the maker is told of a missing end.
        let g = try Gesture()
        let kept = g.editor.document
        let steps = g.editor.undoHistory.undoName
        expectEqual(g.editor.newRelationshipType(from: ShapeID(), to: g.company, replacing: g.bond), nil)
        expectEqual(g.editor.document, kept)
        expectEqual(g.editor.undoHistory.undoName, steps)
    },
    test("a kind with the mark that has a tool is the one made: the first type's own kind when it can hold the mark") {
        let g = try Gesture()
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        expectEqual(g.editor.document[made]?.kind, g.editor.document[g.person]?.kind)
        g.editor.closeCard()
    },
    test("a type related to itself is two arrows, never a two-headed one: one into the new type and one out of it, the second asked of the maker beside the first, which is in the document by then, and the type lands clear of it with room for both") {
        let log = BesideLog()
        let editor = try selfEditor(log)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 400, y: 300))
        let ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 400, y: 700))
        let before = Set(editor.document.shapes.map(\.id))
        let made = try require(editor.newRelationshipType(from: person, to: person))
        let added = editor.document.shapes.filter { !before.contains($0.id) }
        expectEqual(added.count, 3, "the new type and its two arrows: \(added.map(\.kind))")
        let bonds = added.compactMap { $0.typed(as: Bond.self)?.props }
        expectEqual(bonds.map(\.from), [person, made])
        expectEqual(bonds.map(\.to), [made, person])
        let first = try require(added.first { $0.typed(as: Bond.self)?.props.from == person }).id
        expectEqual(log.made.count, 2)
        expect(log.made.first?.beside == nil, "the first arrow names none beside it: \(log.made.map(\.beside))")
        expect(log.made.last?.beside == [first], "the second names the first: \(log.made.map(\.beside))")
        expect(log.made.last?.present == true, "and the first is in the document the maker reads its bend from")
        expect(editor.document.shapes.allSatisfy { ($0.typed(as: Bond.self)?.props).map { $0.from != $0.to } ?? true }, "no arrow runs from the type to itself")
        let graph = try require(editor.relationships?.graph)
        expectEqual(graph.sides(of: made).from.map(\.type), [person])
        expectEqual(graph.sides(of: made).to.map(\.type), [person])
        expectEqual(graph.relationshipTypes(joining: person, and: person), [made])
        let row = try require(graph.rows(for: [person], isType: false).first)
        expectEqual(row.sides, [.from, .to], "one row on both sides")
        expectEqual(editor.relationships?.rows(for: [person], isType: false).count, 1)
        let box = try require(editor.shapeContext.frame(of: made)), own = try require(editor.shapeContext.frame(of: person))
        expect(!box.intersects(own), "clear of the type: \(box) \(own)")
        expect(!box.intersects(try require(editor.shapeContext.frame(of: ann))), "and of what is near")
        let gap = max(box.minX - own.maxX, own.minX - box.maxX, box.minY - own.maxY, own.minY - box.maxY)
        expect(gap >= TypesStyle.endArrowRoom - 0.5, "room for each arrow's body: \(gap)")
        expectEqual(editor.selectedShapeIDs, [made])
        expectEqual(editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        editor.closeCard()
    },
    test("one Undo takes a self-related type back, both arrows and the name: the board as it was") {
        let log = BesideLog()
        let editor = try selfEditor(log)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 400, y: 300))
        editor.selection = person
        editor.undoHistory.seal()
        let start = editor.document
        let made = try require(editor.newRelationshipType(from: person, to: person))
        type("friends", into: try field(of: try require(editor.card)))
        editor.closeCard()
        expectEqual(editor.document[made]?[TitleProperty.self], "friends")
        editor.undo()
        expectEqual(editor.document, start)
        expectEqual(editor.selectedShapeIDs, [person])
        editor.redo()
        expectEqual(editor.document[made]?[TitleProperty.self], "friends")
        expectEqual(editor.document.shapes.filter { $0.typed(as: Bond.self) != nil }.count, 2)
    },
    test("it is drawn small where a kind lays itself out so, and rows come at once to both end types: the height both are about to gain is a dashed line and a row") {
        expectEqual(TypesStyle.relationshipRowGrowth, TypesStyle.relationRuleHeight + TypesStyle.rowHeight)
    },
])

@MainActor let nameCardTests = Suite("The card that names a relationship type", [
    test("it opens inside the gesture, at the pill, with the caret in its one field; each keystroke writes the title as typed and the pill follows; a blank is none") {
        let g = try Gesture()
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        let card = try require(g.editor.card)
        let text = try field(of: card)
        expect(card.firstResponder === text, "the keyboard is in the field")
        let bare = try require(g.editor.titlePillRect(of: made))
        type("i", into: text)
        expectEqual(g.editor.document[made]?[TitleProperty.self], "i")
        type("n", into: text)
        expectEqual(g.editor.document[made]?[TitleProperty.self], "in", "as typed, not capitalised")
        let named = try require(g.editor.titlePillRect(of: made))
        expect(named.width > bare.width || named != bare, "the pill follows the name")
        expectEqual(g.editor.card?.anchor, named, "and the card stays under it")
        text.deleteBackward(nil)
        text.deleteBackward(nil)
        expectEqual(g.editor.document[made]?[TitleProperty.self], nil, "a blank is none")
        expectEqual(g.editor.titlePillRect(of: made).map { $0.width > 0 }, true, "and the placeholder returns")
        type("  a   b ", into: text)
        expectEqual(g.editor.document[made]?[TitleProperty.self], "a b", "folded as every title is")
        g.editor.closeCard()
    },
    test("Return, Esc and Tab close it keeping what was typed; Esc with nothing typed keeps an untitled relationship type and both arrows") {
        for (name, selector) in [("Return", #selector(NSResponder.insertNewline(_:))), ("Esc", #selector(NSResponder.cancelOperation(_:))),
                                 ("Tab", #selector(NSResponder.insertTab(_:))), ("Shift-Tab", #selector(NSResponder.insertBacktab(_:)))] {
            let g = try Gesture()
            let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
            type("in", into: try field(of: try require(g.editor.card)))
            try field(of: try require(g.editor.card)).doCommand(by: selector)
            expect(g.editor.card == nil, "\(name) closes it")
            expectEqual(g.editor.document[made]?[TitleProperty.self], "in", "\(name) keeps the name")
        }
        let g = try Gesture()
        let before = g.ids
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        try field(of: try require(g.editor.card)).doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expect(g.editor.card == nil)
        expectEqual(g.editor.document[made]?[TitleProperty.self], nil, "untitled")
        expectEqual(g.added(since: before).count, 3, "the type and both arrows stay")
        expectEqual(g.editor.undoHistory.undoName, TypesStyle.newRelationshipType, "and the step holds them")
    },
    test("the step is kept after the press, so the name is part of it: shown in an action, the card's keystrokes join the action's step and its name; a commit from elsewhere ends it") {
        let g = try Gesture()
        g.editor.undoHistory.seal()
        var made: ShapeID?
        let start = g.editor.document
        g.editor.undoHistory.group {
            made = g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond)
        }
        let id = try require(made)
        // The action is over; the card is still shown and the step still open: it takes the name.
        expect(g.editor.card != nil)
        type("in", into: try field(of: try require(g.editor.card)))
        expectEqual(g.editor.undoHistory.undoName, TypesStyle.newRelationshipType, "the step keeps the gesture's name")
        g.editor.closeCard()
        g.editor.undo()
        expectEqual(g.editor.document, start, "one Undo takes back the type, both arrows and the name")
        g.editor.redo()
        expectEqual(g.editor.document[id]?[TitleProperty.self], "in")
        // A commit from elsewhere ends the step: what is typed after is a step of its own.
        g.editor.undo()
        g.editor.undoHistory.group { made = g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond) }
        let again = try require(made)
        let card = try require(g.editor.card)
        type("i", into: try field(of: card))
        g.editor.transact("Elsewhere") { $0.update(g.person) { $0[TitleProperty.self] = "People" } }
        type("n", into: try field(of: card))
        expectEqual(g.editor.document[again]?[TitleProperty.self], "in")
        g.editor.closeCard()
        g.editor.undo()
        expectEqual(g.editor.document[again]?[TitleProperty.self], "i", "the keystroke after the other commit is a step of its own")
    },
    test("the host's save point splits the step, as it splits any kept one: what is typed after it is a step named for the card") {
        let g = try Gesture()
        g.editor.undoHistory.seal()
        var made: ShapeID?
        g.editor.undoHistory.group { made = g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond) }
        let id = try require(made)
        let card = try require(g.editor.card)
        type("i", into: try field(of: card))
        g.editor.undoHistory.breakStep()
        type("n", into: try field(of: card))
        expectEqual(g.editor.undoHistory.undoName, TypesStyle.nameRelationshipType)
        g.editor.closeCard()
        g.editor.undo()
        expectEqual(g.editor.document[id]?[TitleProperty.self], "i", "the first Undo takes the name's second half")
        expectEqual(g.editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        g.editor.undo()
        expect(g.editor.document[id] == nil, "the next takes the gesture")
    },
    test("an Undo while the card shows closes it and takes back the step; a press elsewhere closes it keeping the name") {
        let g = try Gesture()
        let start = g.editor.document
        g.editor.undoHistory.group { _ = g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond) }
        type("in", into: try field(of: try require(g.editor.card)))
        g.editor.undo()
        expect(g.editor.card == nil, "undone")
        expectEqual(g.editor.document, start)
        let other = try Gesture()
        let made = try require(other.editor.newRelationshipType(from: other.person, to: other.company, replacing: other.bond))
        type("in", into: try field(of: try require(other.editor.card)))
        other.editor.closeCard(.pressedElsewhere)
        expectEqual(other.editor.document[made]?[TitleProperty.self], "in")
    },
    test("zoomed out, where no card shows, the type is made, selected and untitled; a read-only shape is not named") {
        let g = try Gesture()
        g.editor.camera.setZoom(0.2, around: .zero)
        let made = try require(g.editor.newRelationshipType(from: g.person, to: g.company, replacing: g.bond))
        expect(g.editor.card == nil, "no card at 20%")
        expectEqual(g.editor.selectedShapeIDs, [made])
        expectEqual(g.editor.document[made]?[TitleProperty.self], nil)
        expect(!g.editor.nameRelationshipType(made), "nothing shows")
    },
])
