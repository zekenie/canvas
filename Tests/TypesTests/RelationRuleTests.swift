@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// Needed and Only one as the check of a note's rows: a Needed row with no relationship is amber on the note and `:incomplete`,
// an issue of Validation's third level (as a needed field is), which shows nowhere; more than one where Only one is set is an error on the note, red on the row, none on the
// arrows. A verdict is a function of the records, so each change that moves it moves it with no commit to the note and the undo of
// the change moves it back. Over slips (which show rows) and bonds (arrows of the tests' own).

private let featureSchema = #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#

/// Feature and Layer (slip types), `in` a relationship type with an end at Feature named `layer` and one at Layer; a Feature
/// note `signIn`, a Layer note `foundation`.
@MainActor private struct Scene {
    let editor: CanvasEditor
    let feature: ShapeID, layer: ShapeID, rel: ShapeID
    let fromEnd: ShapeID, toEnd: ShapeID
    let signIn: ShapeID, foundation: ShapeID, ground: ShapeID

    init(rule: EndRule? = nil, name: String = "layer") throws {
        editor = try bondEditor()
        feature = editor.addSlipType(featureSchema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40))
        layer = editor.addSlipType(featureSchema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40))
        rel = editor.addRelationshipType("in", at: CGPoint(x: 240, y: 40))
        fromEnd = editor.addBond(feature, rel, name: name, rule: rule)
        toEnd = editor.addBond(rel, layer)
        signIn = editor.addSlip("Sign in", of: [feature], at: CGPoint(x: 40, y: 500))
        foundation = editor.addSlip("Foundation", of: [layer], at: CGPoint(x: 440, y: 500))
        ground = editor.addSlip("Ground", of: [layer], at: CGPoint(x: 440, y: 700))
    }

    var checks: FieldChecks { editor.fieldChecks! }
    var key: RelationshipRowKey { RelationshipRowKey(type: rel, label: .typed("layer")) }

    func check(_ id: ShapeID) -> FieldCheck { checks.fullCheck(of: editor.file.record(id)!) }
    func said(_ id: ShapeID) -> [String] { check(id).problems.map(\.message) }
    /// What Validation holds of the shape: its errors, its warnings and what it still needs.
    func kept(_ id: ShapeID) -> [String] { editor.issues(id).map(\.message) }

    @discardableResult
    func relate(_ note: ShapeID, _ other: ShapeID) -> ShapeID { editor.addBond(note, other, of: [rel]) }

    func setRule(_ rule: EndRule?, on arrow: ShapeID? = nil) {
        editor.transact { $0.update(arrow ?? fromEnd) { $0[RelationshipEndProperty.self] = rule } }
    }
}

private let needed = EndRule(needed: true, onlyOne: false)
private let onlyOne = EndRule(needed: false, onlyOne: true)
private let both = EndRule(needed: true, onlyOne: true)

@MainActor let relationRuleTests = Suite("Needed and Only one, checked on the note", [
    test("a Needed row with no relationship is amber on the note: needed, incomplete, an issue of the third level and no ring; a relationship drawn at it, with no commit to the note, clears it, and its undo brings it back") {
        let s = try Scene(rule: needed)
        let record = s.editor.document[s.signIn]
        expectEqual(s.said(s.signIn), ["layer is needed"])
        let problem = try require(s.check(s.signIn).problems.first)
        expectEqual(problem.kind, .needed)
        expectEqual(problem.locus, .row(s.key))
        expect(s.check(s.signIn).isIncomplete && !s.check(s.signIn).isWrong)
        expectEqual(s.kept(s.signIn), ["layer is needed"], "Validation keeps it, as the third level")
        expectEqual(s.editor.issues(s.signIn).map(\.severity), [.incomplete])
        expectEqual(s.editor.issues(s.signIn).map(\.field), ["layer"])
        expect(s.editor.validation?.result(for: s.signIn)?.isValid == true && s.editor.validation?.result(for: s.signIn)?.worst == nil, "valid, and no ring")
        expectEqual(s.said(s.foundation), [], "Layer's own notes have no such row")
        let arrow = s.relate(s.signIn, s.foundation)
        expectEqual(s.said(s.signIn), [], "the relationship is the row's")
        expectEqual(s.editor.document[s.signIn], record, "the note was not written")
        s.editor.undo()
        expectEqual(s.said(s.signIn), ["layer is needed"])
        s.editor.redo()
        expectEqual(s.said(s.signIn), [])
        s.editor.transact { $0.delete([arrow]) }
        expectEqual(s.said(s.signIn), ["layer is needed"], "the relationship deleted")
        expectEqual(s.kept(s.signIn), ["layer is needed"])
    },
    test("a relationship that is a misfit, one whose end is a pill that cannot be read, and the far note's own deletion, still count in the row; a free-ended arrow does not") {
        let s = try Scene(rule: needed)
        // The arrow is aimed at a Feature note: red on the arrow, and the Feature note's row is not also amber.
        let other = s.editor.addSlip("Other", of: [s.feature], at: CGPoint(x: 40, y: 700))
        let misfit = s.relate(s.signIn, other)
        expect(s.check(misfit).isMisfit)
        expectEqual(s.said(s.signIn), [], "a misfit is one problem, on the arrow")
        s.editor.transact { $0.delete([misfit]) }
        let free = s.editor.addBond(s.signIn, nil, of: [s.rel])
        expectEqual(s.said(s.signIn), ["layer is needed"], "a free-ended arrow is in no row")
        s.editor.transact { $0.delete([free]) }
        // A pill that stands for nothing: the arrow is there.
        let pill = s.editor.addRelay(standingFor: [])
        s.relate(s.signIn, pill)
        expectEqual(s.said(s.signIn), [])
    },
    test("Only one with two relationships is one error on the note at its row and none on the arrows; deleting one, and the undo, flip it") {
        let s = try Scene(rule: onlyOne)
        expectEqual(s.said(s.signIn), [], "Only one alone asks for nothing")
        let first = s.relate(s.signIn, s.foundation)
        expectEqual(s.said(s.signIn), [])
        let second = s.relate(s.signIn, s.ground)
        let words = "layer has 2 notes, and should have at most 1"
        expectEqual(s.said(s.signIn), [words])
        let problem = try require(s.check(s.signIn).problems.first)
        expectEqual(problem.kind, .wrong)
        expectEqual(problem.locus, .row(s.key))
        expect(s.check(s.signIn).isWrong && !s.check(s.signIn).isIncomplete)
        let issue = try require(s.editor.issues(s.signIn).first)
        expectEqual(issue.message, words)
        expectEqual(issue.severity, .error)
        expectEqual(issue.field, "layer", "the row's name")
        expectEqual(s.editor.validation?.result(for: s.signIn)?.isValid, false, "it rings")
        expectEqual(s.kept(first), [])
        expectEqual(s.kept(second), [], "none on the arrows")
        expectEqual(s.said(first) + s.said(second), [])
        s.editor.transact { $0.delete([second]) }
        expectEqual(s.said(s.signIn), [])
        expectEqual(s.kept(s.signIn), [], "deleting one clears the error")
        s.editor.undo()
        expectEqual(s.kept(s.signIn), [words])
        s.editor.redo()
        expectEqual(s.kept(s.signIn), [])
    },
    test("setting and clearing a rule on an end flips every note of the type with no commit to the notes, and the undo of each flips them back") {
        let s = try Scene()
        let bo = s.editor.addSlip("Bo", of: [s.feature], at: CGPoint(x: 40, y: 700))
        expectEqual(s.said(s.signIn), [])
        s.setRule(needed)
        expectEqual(s.said(s.signIn), ["layer is needed"])
        expectEqual(s.said(bo), ["layer is needed"], "every note of the type")
        s.setRule(both)
        expectEqual(s.said(bo), ["layer is needed"])
        s.relate(bo, s.foundation)
        s.relate(bo, s.ground)
        expectEqual(s.kept(bo), ["layer has 2 notes, and should have at most 1"])
        s.setRule(needed)
        expectEqual(s.kept(bo), [], "Only one taken off: the issue goes")
        s.editor.undo()
        expectEqual(s.kept(bo), ["layer has 2 notes, and should have at most 1"], "and comes back with the undo")
        s.setRule(nil)
        expectEqual(s.said(s.signIn), [])
        expectEqual(s.kept(bo), [])
        s.editor.undo()
        expectEqual(s.kept(bo), ["layer has 2 notes, and should have at most 1"])
        // A rule on an arrow that is no end of a relationship type says nothing to anyone.
        let plain = s.editor.addBond(s.signIn, s.foundation)
        s.setRule(both, on: plain)
        expectEqual(s.said(s.foundation), [])
    },
    test("a rename of a ruled row says its new name in the note's problem and in Validation's issue, with no commit to the note") {
        let s = try Scene(rule: both)
        s.relate(s.signIn, s.foundation)
        s.relate(s.signIn, s.ground)
        expectEqual(s.kept(s.signIn), ["layer has 2 notes, and should have at most 1"])
        let empty = s.editor.addSlip("Empty", of: [s.feature], at: CGPoint(x: 40, y: 700))
        expectEqual(s.said(empty), ["layer is needed"])
        s.editor.transact { $0.update(s.fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "stage") } }
        expectEqual(s.kept(s.signIn), ["stage has 2 notes, and should have at most 1"])
        expectEqual(s.editor.issues(s.signIn).first?.field, "stage")
        expectEqual(s.said(empty), ["stage is needed"])
        s.editor.undo()
        expectEqual(s.kept(s.signIn), ["layer has 2 notes, and should have at most 1"])
        expectEqual(s.said(empty), ["layer is needed"])
    },
    test("a row with no name typed is called by its relationship type, and a rename of that type changes the words") {
        let s = try Scene()
        s.editor.transact { $0.update(s.fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "") } }
        s.setRule(both)
        expectEqual(s.said(s.signIn), ["in is needed"])
        let noteBefore = s.editor.shape(inFile: s.signIn)
        s.editor.transact { $0.update(s.rel) { $0[TitleProperty.self] = "Stage" } }
        expectEqual(s.editor.shape(inFile: s.signIn), noteBefore, "no commit to the note")
        expectEqual(s.editor.rowBook?.rows(of: s.signIn).map(\.name).last, "stage", "the row follows")
        expectEqual(s.said(s.signIn), ["stage is needed"])
        s.relate(s.signIn, s.foundation)
        s.relate(s.signIn, s.ground)
        expectEqual(s.kept(s.signIn), ["stage has 2 notes, and should have at most 1"])
        s.editor.transact { $0.update(s.rel) { $0[TitleProperty.self] = "Tier" } }
        expectEqual(s.kept(s.signIn), ["tier has 2 notes, and should have at most 1"], "Validation's issue follows the rename")
        s.editor.undo()
        expectEqual(s.kept(s.signIn), ["stage has 2 notes, and should have at most 1"])
    },
    test("a note of a type that builds on the end type has the row, and a note of two types with a ruled row each has two problems") {
        let s = try Scene(rule: needed)
        let employee = s.editor.addSlipType(featureSchema, title: "Employee", at: CGPoint(x: 800, y: 40))
        s.editor.addTypeLink(s.feature, to: employee)
        let cy = s.editor.addSlip("Cy", of: [employee], at: CGPoint(x: 800, y: 500))
        expectEqual(s.said(cy), ["layer is needed"], "Employee builds on Feature")
        s.editor.removeTypeLink(s.feature, from: employee)
        expectEqual(s.said(cy), [], "and stops")
        s.editor.undo()
        expectEqual(s.said(cy), ["layer is needed"])
        // A second relationship type with a Needed end at Layer, and a note of both types.
        let owns = s.editor.addRelationshipType("owns", at: CGPoint(x: 240, y: 300))
        s.editor.addBond(s.layer, owns, name: "owner", rule: needed)
        s.editor.addBond(owns, s.feature)
        let both = s.editor.addSlip("Both", of: [s.feature, s.layer], at: CGPoint(x: 800, y: 700))
        expectEqual(s.said(both).sorted(), ["layer is needed", "owner is needed"])
        let marks = s.check(both).problems.compactMap { problem -> String? in if case .row = problem.locus { problem.place.first } else { nil } }
        expectEqual(marks.sorted(), ["layer", "owner"])
        _ = both
    },
    test("each far change flips a ruled note's verdict with no commit to the note, and the undo of each flips it back") {
        let s = try Scene(rule: needed)
        let record = s.editor.document[s.signIn]
        let amber = ["layer is needed"]
        expectEqual(s.said(s.signIn), amber)
        // The relationship type unmarked, and marked again; deleted, and brought back.
        s.editor.transact { $0.update(s.rel) { $0[RelationshipProperty.self] = nil } }
        expectEqual(s.said(s.signIn), [], "unmarked: no relationship type is left")
        s.editor.undo()
        expectEqual(s.said(s.signIn), amber)
        s.editor.transact { $0.delete([s.rel]) }
        expectEqual(s.said(s.signIn), [], "the type deleted")
        s.editor.undo()
        expectEqual(s.said(s.signIn), amber)
        // The end deleted, and re-aimed at the other type: the row moves to the Layer notes.
        s.editor.transact { $0.delete([s.fromEnd]) }
        expectEqual(s.said(s.signIn), [], "no end")
        s.editor.undo()
        expectEqual(s.said(s.signIn), amber)
        s.editor.transact { $0.update(s.fromEnd, as: Bond.self) { $0.props.from = s.layer } }
        expectEqual(s.said(s.signIn), [])
        expectEqual(s.said(s.foundation), amber, "Layer's notes have the row now")
        s.editor.undo()
        expectEqual(s.said(s.signIn), amber)
        expectEqual(s.said(s.foundation), [])
        // The note loses the type, and has it back.
        s.editor.removeTypeLink(s.feature, from: s.signIn)
        expectEqual(s.said(s.signIn), [])
        s.editor.undo()
        expectEqual(s.said(s.signIn), amber)
        // The end type loses its schema, and is no type: nothing is at the end.
        s.editor.removeType(s.feature)
        expectEqual(s.said(s.signIn), [], "Feature is no type now")
        s.editor.undo()
        expectEqual(s.said(s.signIn), amber)
        expectEqual(s.editor.document[s.signIn], record, "the note was not written")
    },
    test("a note's rows are those of its kind that draws rows: a note that is a type, an arrow, and a note with no type say nothing") {
        let s = try Scene(rule: needed)
        expectEqual(s.said(s.feature), [], "a type's own note")
        expectEqual(s.said(s.fromEnd), [])
        let plain = s.editor.addSlip("Plain", of: [], at: CGPoint(x: 40, y: 700))
        expectEqual(s.said(plain), [])
        // A note that is not a Feature is not asked.
        expectEqual(s.said(s.ground), [])
    },
    test("a relationship through a pill counts in the row, and a pill whose note stops being open leaves the arrow in the row") {
        let s = try Scene(rule: onlyOne)
        let far = s.editor.addSlip("Far", of: [s.layer], at: CGPoint(x: 440, y: 900))
        s.editor.open(far)
        let pill = s.editor.addRelay(standingFor: [far], says: "Far")
        s.relate(s.signIn, pill)
        s.relate(s.signIn, s.foundation)
        expectEqual(s.kept(s.signIn), ["layer has 2 notes, and should have at most 1"], "the arrow through the pill counts")
        s.editor.transact { $0.update(far) { $0.meta[Open.self] = false } }
        expectEqual(s.kept(s.signIn), ["layer has 2 notes, and should have at most 1"], "the arrow is there, what it reaches is unknown")
        s.editor.undo()
        expectEqual(s.kept(s.signIn).count, 1)
    },
])
