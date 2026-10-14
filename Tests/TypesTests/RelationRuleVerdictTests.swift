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

// What Validation keeps of a note (`editor.issues`) is held against what a second editor opened on the same file says.

private let schema = #"{"type": "object", "properties": {"purpose": {"type": "string"}}}"#
private let onlyOne = EndRule(needed: false, onlyOne: true)
private let needed = EndRule(needed: true, onlyOne: false)

/// A drag that changes one shape and does nothing else (as RelationshipHoldTests').
@MainActor private final class HeldDragging {
    let shape: ShapeID
    init(_ shape: ShapeID) { self.shape = shape }
}

extension HeldDragging: Session {
    var touching: Set<ShapeID> { [shape] }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

@MainActor private struct World {
    let editor: CanvasEditor
    let feature: ShapeID, layer: ShapeID, rel: ShapeID
    let fromEnd: ShapeID, toEnd: ShapeID
    let foundation: ShapeID, ground: ShapeID

    init(rule: EndRule?, name: String = "layer", query: Bool = false) throws {
        editor = query ? try queryBondEditor() : try bondEditor()
        feature = editor.addSlipType(schema, words: "A feature", title: "Feature", at: CGPoint(x: 40, y: 40))
        layer = editor.addSlipType(schema, words: "A layer", title: "Layer", at: CGPoint(x: 440, y: 40))
        rel = editor.addRelationshipType("in", at: CGPoint(x: 240, y: 40))
        fromEnd = editor.addBond(feature, rel, name: name, rule: rule)
        toEnd = editor.addBond(rel, layer)
        foundation = editor.addSlip("Foundation", of: [layer], at: CGPoint(x: 440, y: 500))
        ground = editor.addSlip("Ground", of: [layer], at: CGPoint(x: 440, y: 700))
    }

    /// Validation's kept errors of a shape on the board shown.
    func kept(_ id: ShapeID) -> [String] { editor.issues(id).filter { $0.severity == .error }.map(\.message).sorted() }
    /// What the service's check says now (asked, so a stale stamp is remade).
    func said(_ id: ShapeID) -> [String] { editor.fieldChecks!.fullCheck(of: editor.file.record(id)!).problems.map(\.message).sorted() }
    /// The errors a second editor opened on the same file holds of the shape.
    func fresh(_ id: ShapeID) throws -> [String] {
        let other = try bondEditor(file: editor.file)
        return other.issues(id).filter { $0.severity == .error }.map(\.message).sorted()
    }
    /// What a second editor's check says of the shape.
    func freshSaid(_ id: ShapeID) throws -> [String] {
        let other = try bondEditor(file: editor.file)
        return other.fieldChecks!.fullCheck(of: other.file.record(id)!).problems.map(\.message).sorted()
    }

    @discardableResult
    func relate(_ note: ShapeID, _ other: ShapeID) -> ShapeID { editor.addBond(note, other, of: [rel]) }
}

@MainActor let relationRuleVerdictTests = Suite("Rule verdicts kept after each change of the ends, rows and rules", [
    // A row two blocks give alike is the more specific type's (`RelationshipGraph.rows(for:isType:)`). An unruled end drawn at a
    // type that builds on the end type, with the ruled row's key, takes the rule off its notes; deleting it puts the rule back.
    // The partition of the ruled rows at the sub type is empty before and after, so nobody is named.
    test("an unruled end drawn at a type that builds on the end type, of the ruled row's name, takes the rule from its notes: Validation's kept issue of a note of it is what a fresh read says") {
        let w = try World(rule: onlyOne)
        let sub = w.editor.addSlipType(schema, title: "Sub", at: CGPoint(x: 800, y: 40))
        w.editor.addTypeLink(w.feature, to: sub)
        let cy = w.editor.addSlip("Cy", of: [sub], at: CGPoint(x: 800, y: 500))
        w.relate(cy, w.foundation)
        w.relate(cy, w.ground)
        expectEqual(w.kept(cy), ["layer has 2 notes, and should have at most 1"], "Sub builds on Feature: its notes have the Only one row")
        expectEqual(try w.fresh(cy), w.kept(cy))
        // The sub type's own end, of the same name, with no rule.
        let heard = RelationshipHeard(w.editor)
        let subEnd = w.editor.addBond(sub, w.rel, name: "layer")
        expect(heard.changes.contains { $0.notes.contains(cy) }, "the end drawn: the index names the note of the sub type (it named \(heard.changes.map { $0.notes.count }) notes, laid out \(heard.changes.map { $0.layout.count }))")
        expectEqual(w.kept(cy), try w.fresh(cy), "after the sub type's own unruled end of the same name is drawn")
        expectEqual(w.said(cy), try w.freshSaid(cy), "the service's own answer")
        heard.changes.removeAll()
        w.editor.transact { $0.delete([subEnd]) }
        expect(heard.changes.contains { $0.notes.contains(cy) }, "the end deleted: the index names the note of the sub type (it named \(heard.changes.map { $0.notes.count }) notes, laid out \(heard.changes.map { $0.layout.count }))")
        expectEqual(w.kept(cy), try w.fresh(cy), "after that end is deleted")
        w.editor.undo()
        expectEqual(w.kept(cy), try w.fresh(cy), "after the delete is undone")
        w.editor.undo()
        expectEqual(w.kept(cy), try w.fresh(cy), "after the end's drawing is undone")
    },
    test("the sub type's unruled end renamed away from the ruled row's name (a split across the two types' blocks) puts the rule back on its notes: Validation's kept issue is what a fresh read says") {
        let w = try World(rule: onlyOne)
        let sub = w.editor.addSlipType(schema, title: "Sub", at: CGPoint(x: 800, y: 40))
        w.editor.addTypeLink(w.feature, to: sub)
        let subEnd = w.editor.addBond(sub, w.rel, name: "layer")
        let cy = w.editor.addSlip("Cy", of: [sub], at: CGPoint(x: 800, y: 500))
        w.relate(cy, w.foundation)
        w.relate(cy, w.ground)
        expectEqual(w.kept(cy), try w.fresh(cy), "at the start")
        w.editor.transact { $0.update(subEnd, as: Bond.self) { $0.props.text = MentionText(plain: "stage") } }
        expectEqual(w.kept(cy), try w.fresh(cy), "after the sub type's end is renamed stage")
        w.editor.undo()
        expectEqual(w.kept(cy), try w.fresh(cy), "after the rename is undone")
        w.editor.transact { $0.update(subEnd, as: Bond.self) { $0.props.text = MentionText(plain: "stage") } }
        w.editor.transact { $0.update(subEnd, as: Bond.self) { $0.props.text = MentionText(plain: "layer") } }
        expectEqual(w.kept(cy), try w.fresh(cy), "after it is renamed back to layer (a merge across the blocks)")
    },
    test("a note of two types, one giving the ruled row and the later one an unruled row of the same name: the unruled end drawn and deleted") {
        let w = try World(rule: onlyOne)
        let other = w.editor.addSlipType(schema, title: "Other", at: CGPoint(x: 800, y: 40))
        let both = w.editor.addSlip("Both", of: [w.feature, other], at: CGPoint(x: 800, y: 500))
        w.relate(both, w.foundation)
        w.relate(both, w.ground)
        expectEqual(w.kept(both), try w.fresh(both), "at the start")
        let otherEnd = w.editor.addBond(other, w.rel, name: "layer")
        expectEqual(w.kept(both), try w.fresh(both), "after Other's unruled end of the same name is drawn")
        w.editor.transact { $0.delete([otherEnd]) }
        expectEqual(w.kept(both), try w.fresh(both), "after it is deleted")
    },
    // A re-aim by a drag: the hovers are held, the release counts the arrow as it is. The note the arrow left is an end of
    // nothing the release reads.
    test("a relationship re-aimed away from a note by a drag (hovers, then the release) clears the note's Only one error as a re-aim in one commit does") {
        let w = try World(rule: onlyOne)
        let ann = w.editor.addSlip("Ann", of: [w.feature], at: CGPoint(x: 40, y: 500))
        let bo = w.editor.addSlip("Bo", of: [w.feature], at: CGPoint(x: 40, y: 700))
        w.relate(ann, w.foundation)
        let second = w.relate(ann, w.ground)
        expectEqual(w.kept(ann), ["layer has 2 notes, and should have at most 1"])
        // The drag: the arrow's start is moved to Bo at a hover, and released there.
        w.editor.session = HeldDragging(second)
        w.editor.transact("Hover") { $0.update(second, as: Bond.self) { $0.props.from = bo } }
        w.editor.connectionReleased(second)
        w.editor.session = nil
        expectEqual(w.said(ann), try w.freshSaid(ann), "the service's answer for the note the arrow left")
        expectEqual(w.kept(ann), try w.fresh(ann), "Validation's kept issue for the note the arrow left")
        expectEqual(w.kept(bo), try w.fresh(bo), "and for the note it was aimed at")
        // It does not mend itself: a commit that names the note (a value typed on it) has Validation ask again, and the kept part
        // answers as before, since neither the note's stamp nor the index's revision moved.
        w.editor.transact { $0.update(ann) { $0[FieldValuesProperty.self] = FieldValues(["purpose": "x"]) } }
        expectEqual(w.kept(ann), try w.fresh(ann), "after a commit to the note itself")
        // The Undo of the drag's hover is a commit with no session: it names the note, and all is right again.
        w.editor.undo()
        w.editor.undo()
        expectEqual(w.kept(ann), try w.fresh(ann), "after the drag is undone")
    },
    test("a relationship re-aimed onto a note by a drag gives the note its Only one error, and the note it left under Needed is amber") {
        let w = try World(rule: EndRule(needed: true, onlyOne: true))
        let ann = w.editor.addSlip("Ann", of: [w.feature], at: CGPoint(x: 40, y: 500))
        let bo = w.editor.addSlip("Bo", of: [w.feature], at: CGPoint(x: 40, y: 700))
        w.relate(ann, w.foundation)
        let moved = w.relate(bo, w.ground)
        expectEqual(w.said(bo), [])
        w.editor.session = HeldDragging(moved)
        w.editor.transact("Hover") { $0.update(moved, as: Bond.self) { $0.props.from = ann } }
        w.editor.connectionReleased(moved)
        w.editor.session = nil
        expectEqual(w.kept(ann), try w.fresh(ann), "the note it was aimed at")
        expectEqual(w.said(bo), try w.freshSaid(bo), "the note the arrow left: its Needed row is empty now")
    },
    // Only one, a pick in the row of a note on the board shown, where the relationship the row holds was drawn on another board (from the
    // far note's own row, through a pill there): the old arrow and the pill it empties are on the far board.
    test("Only one replacing an arrow that is on another board: the far arrow and the pill it empties go, in the one step, and one Undo returns the file byte for byte") {
        let s = try RelationScene.drawn()
        // The Layer end allows one Feature a Layer.
        let layerEnd = try require(s.index.graph.sides(of: s.rel).to.first).carrier
        s.editor.transact { $0.update(layerEnd) { $0[RelationshipEndProperty.self] = EndRule(needed: false, onlyOne: true) } }
        // From the far Feature note's own row, on its board: a pill there for the Layer note on the root.
        s.setOpen(s.layerNote)
        expect(s.editor.showBoard(s.pocketBoard))
        let far = try require(s.editor.relate(s.away, to: s.layerNote, in: try s.featureRow()), "the far note related to the root's Layer note")
        expectEqual(s.relays(on: s.pocketBoard).count, 1, "a pill on the far board")
        expect(s.editor.showBoard(.root))
        s.editor.undoHistory.seal()
        expectEqual(s.index.relations(of: s.layerNote, in: try s.layerRow()).map(\.arrow), [far], "the Layer note's row holds the far relationship")
        let start = try s.bytes(), file = s.editor.file
        // The pick in the Layer note's row, on the root: the Feature note beside it.
        let made = try require(s.editor.relate(s.layerNote, to: s.note, in: try s.layerRow()), "the pick")
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        expect(s.editor.shape(inFile: far) == nil, "the far arrow is gone")
        expectEqual(s.relays(on: s.pocketBoard).count, 0, "with the pill it emptied, on the far board")
        expectEqual(s.index.relations(of: s.layerNote, in: try s.layerRow()).map(\.arrow), [made])
        expectEqual(s.editor.fieldChecks?.fullCheck(of: try require(s.editor.document[s.layerNote])).problems.map(\.message) ?? [], [])
        s.editor.undo()
        expect(s.editor.file == file, "one Undo returns the whole file")
        expect(try s.bytes() == start, "byte for byte")
        s.editor.redo()
        expect(s.editor.shape(inFile: far) == nil)
        expectEqual(s.relays(on: s.pocketBoard).count, 0)
    },
    test("a rule set and cleared on the board shown flips a note on a board not shown, and its undo flips it back; shown again, Validation holds what a fresh read does") {
        let s = try RelationScene.drawn()
        let end = try require(s.index.graph.sides(of: s.rel).from.first).carrier
        let checks = try require(s.editor.fieldChecks)
        @MainActor func said(_ id: ShapeID) -> [String] { checks.fullCheck(of: s.editor.file.record(id)!).problems.map(\.message) }
        @MainActor func fresh(_ id: ShapeID) throws -> [String] {
            let other = try bondEditor(file: s.editor.file)
            return other.fieldChecks!.fullCheck(of: other.file.record(id)!).problems.map(\.message)
        }
        expectEqual(said(s.away), [])
        s.editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: true) } }
        expectEqual(said(s.away), ["layer is needed"], "the far note")
        s.editor.undo()
        expectEqual(said(s.away), [])
        s.editor.redo()
        // Two relationships of the far note, drawn on its board with no pick.
        let down2 = slipRecord("Down two", of: [s.layer], at: CGPoint(x: 400, y: 300))
        s.editor.transact(on: s.pocketBoard, "Add") { $0.insert(down2) }
        let b1 = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.away, to: s.awayLayer))), b2 = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.away, to: down2.id)))
        s.editor.transact(on: s.pocketBoard, "Relate") { transaction in
            for var bond in [b1, b2] {
                bond[IsAProperty.self] = [TypeLink(s.rel)]
                transaction.insert(bond)
            }
        }
        expectEqual(said(s.away), try fresh(s.away), "two relationships drawn on the far board")
        expectEqual(said(s.away), ["layer has 2 notes, and should have at most 1"])
        s.editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: false) } }
        expectEqual(said(s.away), [], "Only one taken off on the board shown")
        s.editor.undo()
        expectEqual(said(s.away), ["layer has 2 notes, and should have at most 1"])
        // The end renamed so the words change, and the board then shown.
        s.editor.transact { $0.update(end, as: Bond.self) { $0.props.text = MentionText(plain: "stage") } }
        expectEqual(said(s.away), ["stage has 2 notes, and should have at most 1"])
        expect(s.editor.showBoard(s.pocketBoard))
        expectEqual(s.editor.issues(s.away).map(\.message), ["stage has 2 notes, and should have at most 1"], "Validation, once its board is shown")
        // With the far board shown, the rule is taken off its end, which is now on a board not shown.
        s.editor.transact(on: .root, "Rule") { $0.update(end) { $0[RelationshipEndProperty.self] = nil } }
        expectEqual(s.editor.issues(s.away).map(\.message), [], "the end's rule cleared on the board not shown")
        s.editor.undo()
        // (An Undo of a step on another board may show that board: the far note's board is shown again before Validation is read.)
        expectEqual(said(s.away), ["stage has 2 notes, and should have at most 1"], "and undone, the check")
        expect(s.editor.showBoard(s.pocketBoard))
        expectEqual(s.editor.issues(s.away).map(\.message), ["stage has 2 notes, and should have at most 1"], "and undone")
        // A relationship of it deleted from the other board.
        expect(s.editor.showBoard(.root))
        s.editor.transact(on: s.pocketBoard, "Delete") { $0.delete([b2.id]) }
        expectEqual(said(s.away), try fresh(s.away), "a far relationship deleted")
        expect(s.editor.showBoard(s.pocketBoard))
        expectEqual(s.editor.issues(s.away).map(\.message), [], "Validation, the board shown again")
    },
    test("a far note's ruled row counts the relationship drawn to its pill: the pill re-pointed, the note closed and opened, the pill deleted, each against a fresh read") {
        let w = try World(rule: nil)
        // Layer's notes have a Needed, Only one row.
        w.editor.transact { $0.update(w.toEnd) { $0[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: true) } }
        let ann = w.editor.addSlip("Ann", of: [w.feature], at: CGPoint(x: 40, y: 500))
        let bo = w.editor.addSlip("Bo", of: [w.feature], at: CGPoint(x: 40, y: 700))
        w.editor.open(w.foundation)
        w.editor.open(w.ground)
        let pill = w.editor.addRelay(standingFor: [w.foundation], says: "Foundation")
        w.relate(ann, pill)
        w.relate(bo, w.foundation)
        @MainActor func agree(_ what: String) throws {
            for id in [w.foundation, w.ground] {
                expectEqual(w.said(id), try w.freshSaid(id), "the check, \(what)")
                expectEqual(w.kept(id), try w.fresh(id), "Validation, \(what)")
            }
        }
        try agree("at the start")
        expectEqual(w.kept(w.foundation).count, 1, "two: one through the pill")
        w.editor.transact { $0.update(pill, as: Relay.self) { $0.props.stands = [Citation(w.ground)] } }
        try agree("the pill re-pointed at Ground")
        w.editor.undo()
        try agree("undone")
        w.editor.transact { $0.update(w.foundation) { $0.meta[Open.self] = nil } }
        try agree("Foundation closed")
        w.editor.undo()
        try agree("opened again")
        w.editor.transact { $0.delete([pill]) }
        try agree("the pill deleted")
        w.editor.undo()
        try agree("and back")
    },
    // A rename that leaves the partition equal names no note; the notes whose kept answer holds an Only one error of a row that is
    // called otherwise now are checked again by it (`rowErrors`), and no other.
    test("at a hub whose notes each break Only one, a keystroke in the ruled end's label makes each part once with the new name, and one in another relationship type's end or in the title of a type at an end makes none") {
        let w = try World(rule: onlyOne)
        let hub = (0..<1_000).map { w.editor.addSlip("n\($0)", of: [w.feature], at: CGPoint(x: 40 + Double($0 % 30) * 30, y: 900 + Double($0 / 30) * 30)) }
        w.editor.transact { transaction in
            for note in hub {
                for layer in [w.foundation, w.ground] {
                    var bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: note, to: layer)))
                    bond[IsAProperty.self] = [TypeLink(w.rel)]
                    transaction.insert(bond)
                }
            }
        }
        expectEqual(hub.filter { w.kept($0).count == 1 }.count, 1_000, "every note of the hub breaks Only one")
        // Another relationship type, between two types that have nothing to do with the hub.
        let a = w.editor.addSlipType(schema, title: "Alpha", at: CGPoint(x: 1200, y: 40)), b = w.editor.addSlipType(schema, title: "Beta", at: CGPoint(x: 1600, y: 40))
        let other = w.editor.addRelationshipType("other", at: CGPoint(x: 1400, y: 40))
        let otherEnd = w.editor.addBond(a, other, name: "x")
        w.editor.addBond(other, b)
        let checks = try require(w.editor.fieldChecks)
        let heard = RelationshipHeard(w.editor)
        var made = checks.relationPartsMade
        var took = threadCPUTime {
            w.editor.transact { $0.update(w.fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "layers") } }
            _ = w.kept(hub[0])
        }
        expect(heard.last?.notes.isEmpty == true && heard.last?.rows == true, "the rename names no note")
        // Every issue quotes the row's name, so each says the new one, and each part is made once.
        expect(checks.relationPartsMade - made <= 1_000, "a keystroke in the ruled end's label made \(checks.relationPartsMade - made) parts again, in \(took)")
        expectEqual(w.kept(hub[999]), ["layers has 2 notes, and should have at most 1"], "the row's new name, in the last note's issue")
        made = checks.relationPartsMade
        took = threadCPUTime {
            w.editor.transact { $0.update(otherEnd, as: Bond.self) { $0.props.text = MentionText(plain: "xy") } }
            _ = w.kept(hub[0])
        }
        expect(checks.relationPartsMade - made < 10, "a keystroke in another relationship type's end label made \(checks.relationPartsMade - made) parts again, in \(took)")
        made = checks.relationPartsMade
        w.editor.transact { $0.update(b) { $0[TitleProperty.self] = "Betas" } }
        _ = w.kept(hub[0])
        expect(checks.relationPartsMade - made < 10, "a keystroke in the title of a type at another relationship type's end made \(checks.relationPartsMade - made) parts again")
    },
    test("a value typed on a relationship under a ruled row names the arrow alone, and a rule set on the end is not a value-only change") {
        let w = try World(rule: onlyOne)
        let ann = w.editor.addSlip("Ann", of: [w.feature], at: CGPoint(x: 40, y: 500))
        let first = w.relate(ann, w.foundation)
        w.relate(ann, w.ground)
        expectEqual(w.kept(ann).count, 1)
        let heard = RelationshipHeard(w.editor)
        let checks = try require(w.editor.fieldChecks)
        let made = checks.relationPartsMade, stamp = w.editor.relationships?.stamp(of: ann)
        w.editor.transact { $0.update(first) { $0[FieldValuesProperty.self] = FieldValues(["purpose": "x"]) } }
        expectEqual(heard.last?.values, [first], "the arrow alone")
        expect(heard.last?.notes.isEmpty == true && heard.last?.arrows.isEmpty == true, "no note: \(String(describing: heard.last))")
        _ = w.kept(ann)
        _ = w.said(ann)
        expect(checks.relationPartsMade - made <= 1, "the arrow's own part at most: \(checks.relationPartsMade - made)")
        expectEqual(w.editor.relationships?.stamp(of: ann), stamp, "the note's stamp stands, so its part was not made again")
        w.editor.setEndRule([w.fromEnd], onlyOne: false)
        expect(heard.last?.notes.contains(ann) == true && heard.last?.values.isEmpty == true, "the rule names the note: \(String(describing: heard.last))")
        expectEqual(w.kept(ann), [])
    },
    test("a rule set at a type with 10,000 notes rechecks each once in its commit, inside the design's figure scaled for a debug build, and a drag afterwards rechecks nothing") {
        let w = try World(rule: nil)
        var hub: [ShapeID] = []
        w.editor.transact { transaction in
            for n in 0..<10_000 {
                let record = slipRecord("n\(n)", of: [w.feature], at: CGPoint(x: 40 + Double(n % 100) * 30, y: 900 + Double(n / 100) * 30))
                hub.append(record.id)
                transaction.insert(record)
            }
        }
        let checks = try require(w.editor.fieldChecks)
        _ = w.kept(hub[0])
        for id in hub { _ = checks.fullCheck(of: w.editor.document[id]!) }
        let made = checks.relationPartsMade
        let took = threadCPUTime {
            w.editor.setEndRule([w.fromEnd], needed: true)
            _ = w.kept(hub[0])
        }
        expectEqual(checks.relationPartsMade - made, 10_000, "each note's part once")
        expectEqual(w.said(hub[9_999]), ["layer is needed"])
        let ms = Double(took.components.attoseconds) / 1e15 + Double(took.components.seconds) * 1000
        expect(ms < 190 * 8, "a rule set at 10,000 notes took \(ms) ms in a debug build (190 ms, times 8)")
        print("rule set at 10,000 notes: \(ms) ms (debug)")
        let after = checks.relationPartsMade
        w.editor.transact("Move") { $0.update(hub[5]) { $0.box?.origin.x += 10 } }
        _ = w.kept(hub[0])
        expectEqual(checks.relationPartsMade - after, 0, "a drag rechecks nothing")
    },
    test("every far change, and its undo, with a note that breaks Only one and one whose Needed row is empty: the check and Validation's kept issues are a fresh read's after each") {
        let w = try World(rule: EndRule(needed: true, onlyOne: true))
        let ann = w.editor.addSlip("Ann", of: [w.feature], at: CGPoint(x: 40, y: 500))
        let bo = w.editor.addSlip("Bo", of: [w.feature], at: CGPoint(x: 40, y: 700))
        let first = w.relate(ann, w.foundation)
        let second = w.relate(ann, w.ground)
        let notes = [ann, bo, w.foundation, w.ground]
        @MainActor func agree(_ what: String) throws {
            for id in notes where w.editor.document[id] != nil {
                expectEqual(w.said(id), try w.freshSaid(id), "the check, \(what)")
                expectEqual(w.kept(id), try w.fresh(id), "Validation, \(what)")
            }
        }
        @MainActor func step(_ what: String, _ body: () -> Void) throws {
            body()
            try agree(what)
            w.editor.undo()
            try agree("undo of: \(what)")
            w.editor.redo()
            try agree("redo of: \(what)")
            w.editor.undo()
        }
        try agree("at the start")
        expectEqual(w.kept(ann).count, 1)
        try step("the end deleted") { w.editor.transact { $0.delete([w.fromEnd]) } }
        try step("the end re-aimed at Layer") { w.editor.transact { $0.update(w.fromEnd, as: Bond.self) { $0.props.from = w.layer } } }
        try step("the other end deleted") { w.editor.transact { $0.delete([w.toEnd]) } }
        try step("the other end named as the ruled one: one row on both sides") { w.editor.transact { $0.update(w.toEnd, as: Bond.self) { $0.props.to = w.feature; $0.props.text = MentionText(plain: "layer") } } }
        try step("the ruled end's name cleared") { w.editor.transact { $0.update(w.fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "") } } }
        try step("the note's type taken away") { w.editor.removeTypeLink(w.feature, from: ann) }
        try step("the note made a Layer too") { w.editor.addTypeLink(w.layer, to: ann) }
        try step("a relationship deleted") { w.editor.transact { $0.delete([second]) } }
        try step("a relationship re-aimed to Bo's") { w.editor.transact { $0.update(second, as: Bond.self) { $0.props.from = bo } } }
        try step("a relationship's far end re-aimed") { w.editor.transact { $0.update(second, as: Bond.self) { $0.props.to = w.foundation } } }
        try step("a relationship's type taken off") { w.editor.removeTypeLink(w.rel, from: first) }
        try step("a relationship's end freed") { w.editor.transact { $0.update(first, as: Bond.self) { $0.props.to = nil } } }
        try step("a third relationship drawn") { w.relate(ann, bo) }
        try step("a relationship drawn at Bo") { w.relate(bo, w.ground) }
        try step("the mark taken off") { w.editor.transact { $0.update(w.rel) { $0[RelationshipProperty.self] = nil } } }
        try step("the relationship type deleted") { w.editor.transact { $0.delete([w.rel]) } }
        try step("the relationship type no type") { w.editor.removeType(w.rel) }
        try step("the far note deleted") { w.editor.transact { $0.delete([w.ground]) } }
        try step("the end type no type") { w.editor.removeType(w.feature) }
        try step("the end type deleted") { w.editor.transact { $0.delete([w.feature]) } }
        try step("the end type marked a relationship type") { w.editor.transact { $0.update(w.feature) { $0[RelationshipProperty.self] = true } } }
        try step("the end type renamed") { w.editor.transact { $0.update(w.layer) { $0[TitleProperty.self] = "Tier" } } }
        try step("the note deleted") { w.editor.transact { $0.delete([ann]) } }
        // A second relationship type of the same notes, with a rule of its own.
        let owns = w.editor.addRelationshipType("owns", at: CGPoint(x: 240, y: 300))
        try agree("a second relationship type")
        try step("its end drawn, ruled") { w.editor.addBond(w.feature, owns, name: "owned", rule: needed) }
        let ownsEnd = w.editor.addBond(w.feature, owns, name: "owned", rule: needed)
        try step("its end named as the first's row") { w.editor.transact { $0.update(ownsEnd, as: Bond.self) { $0.props.text = MentionText(plain: "layer") } } }
        try step("a relationship given the second type too") { w.editor.addTypeLink(owns, to: first) }
        try step("a relationship given the second type instead") { w.editor.transact { $0.update(first) { $0[IsAProperty.self] = [TypeLink(owns)] } } }
    },
    test("Only one, a far note related through a pill, made private, and picked again: the pill the old arrow ran to is kept for the new one, and one Undo returns the file") {
        let s = try RelationScene.drawn()
        let end = try require(s.index.graph.sides(of: s.rel).from.first).carrier
        s.editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = EndRule(needed: false, onlyOne: true) } }
        s.setOpen(s.awayLayer)
        let old = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        let pill = try require(s.relays().first).id
        s.setOpen(s.awayLayer, false)
        s.editor.undoHistory.seal()
        let start = try s.bytes()
        expect(s.index.candidates(for: try s.featureRow(), of: s.note)?.contains(s.awayLayer) == true, "the far note, private now, is offered again")
        let made = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()), "the pick")
        expect(s.editor.document[old] == nil, "the old arrow went")
        expectEqual(s.relays().map(\.id), [pill], "its pill is the new arrow's")
        expectEqual(s.editor.document[made]?.typed(as: Bond.self)?.props.to, pill)
        expectEqual(s.index.relations(of: s.note, in: try s.featureRow()).map(\.arrow), [made])
        s.editor.undo()
        expect(try s.bytes() == start, "one Undo, byte for byte")
    },
    test("a type related to itself with two names: a pick in the Only one row replaces what that row holds and leaves the other row's relationship") {
        let editor = try typeEditorWithDraw()
        let person = editor.addSlipType(schema, title: "Person", at: CGPoint(x: 40, y: 40))
        let friendship = editor.addRelationshipType("Friendship", at: CGPoint(x: 440, y: 40))
        editor.addBond(person, friendship, name: "mentor", rule: onlyOne)
        editor.addBond(friendship, person, name: "mentees")
        let ann = editor.addSlip("Ann", of: [person], at: CGPoint(x: 40, y: 500))
        let bo = editor.addSlip("Bo", of: [person], at: CGPoint(x: 340, y: 500))
        let cy = editor.addSlip("Cy", of: [person], at: CGPoint(x: 640, y: 500))
        let dee = editor.addSlip("Dee", of: [person], at: CGPoint(x: 940, y: 500))
        let index = try require(editor.relationships)
        let rows = index.rows(for: [person], isType: false)
        let mentor = try require(rows.first { $0.key.label == .typed("mentor") }), mentees = try require(rows.first { $0.key.label == .typed("mentees") })
        expectEqual(mentor.rule, onlyOne)
        expectEqual(mentees.rule, EndRule())
        let annBo = editor.addBond(ann, bo, of: [friendship])
        let cyAnn = editor.addBond(cy, ann, of: [friendship])
        expectEqual(editor.issues(ann).map(\.message), [], "one in each row")
        let picked = try require(editor.relate(ann, to: dee, in: mentor), "the pick")
        expect(editor.document[annBo] == nil, "the mentor row's relationship is replaced")
        expect(editor.document[cyAnn] != nil, "the mentees row's stays")
        expectEqual(index.relations(of: ann, in: mentor).map(\.arrow), [picked])
        expectEqual(editor.issues(ann).map(\.message), [])
    },
    // The words of an Only one issue follow a rename through `rows: true` (the notes in `rowErrors`). A commit that renames the ruled
    // end and also changes the number of rows at the type (as one `canvas draw` run can) announces a layout and not `rows`.
    test("one commit that renames the ruled end and draws another end at the type: Validation's Only one issue says the row's new name") {
        let w = try World(rule: onlyOne)
        let ann = w.editor.addSlip("Ann", of: [w.feature], at: CGPoint(x: 40, y: 500))
        w.relate(ann, w.foundation)
        w.relate(ann, w.ground)
        expectEqual(w.kept(ann), ["layer has 2 notes, and should have at most 1"])
        let heard = RelationshipHeard(w.editor)
        let back = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: w.rel, to: w.feature, text: MentionText(plain: "back"))))
        w.editor.transact { transaction in
            transaction.update(w.fromEnd, as: Bond.self) { $0.props.text = MentionText(plain: "stage") }
            transaction.insert(back)
        }
        expectEqual(w.said(ann), ["stage has 2 notes, and should have at most 1"], "the check, asked")
        expectEqual(w.kept(ann), try w.fresh(ann), "Validation's kept issue (the index told rows \(String(describing: heard.last?.rows)), notes \(heard.last?.notes.count ?? -1), layout \(heard.last?.layout.count ?? -1))")
    },
    test("setEndRule on a locked end alone: nothing is written, no step is made, and it answers false") {
        let log = RefusalLog()
        let editor = try bondEditor(more: [FreezingPlugin(log: log)])
        let person = editor.addSlipType(schema, title: "Person"), employment = editor.addRelationshipType("Employment")
        let end = editor.addBond(person, employment, name: "jobs")
        editor.freeze([end])
        editor.undoHistory.seal()
        let name = editor.undoHistory.undoName, revision = editor.revision
        let wrote = editor.setEndRule([end], needed: true)
        expectEqual(editor.document[end]?[RelationshipEndProperty.self], nil, "not written")
        expectEqual(editor.undoHistory.undoName, name, "no step")
        expectEqual(editor.revision, revision, "no commit")
        expectEqual(wrote, false, "`True once something was written`")
        expectEqual(log.refusals.count, 1, "it shakes once: \(log.refusals)")
    },
    test("a locked old arrow refuses the Only one pick whole and shakes once") {
        let log = RefusalLog()
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: log)])
        let end = try require(s.index.graph.sides(of: s.rel).from.first).carrier
        s.editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = EndRule(needed: false, onlyOne: true) } }
        let second = s.addLayerNote("Second")
        let first = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        s.editor.freeze([first])
        log.refusals = []
        expectEqual(s.editor.relate(s.note, to: second, in: try s.featureRow()), nil)
        expectEqual(log.refusals.count, 1, "the shakes: \(log.refusals)")
    },
])
