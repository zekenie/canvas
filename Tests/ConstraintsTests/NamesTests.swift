import AppKit
import DetailPanel
import Selection
import SlashCommands
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Constraints
import CoreGraphics
import Foundation
import LanguageModels
import Queries
import TestKit
import Palette
import Observation
import Titles

// A constraint remembers which shapes the titles in its query named when it was written (`names`, by id), and is judged by
// those shapes whatever they are called now: bound by the writer as it writes a query it didn't have, part of the value,
// coded as `{"Alpha": "<id>"}` and left out while there are none, read leniently. Fixtures only: corrals, and tiles
// titled by their labels; `"Alpha"` is the query that accepts the tile of that name.

private let pen = CGRect(x: 100, y: 100, width: 400, height: 300)
private let alphaOnly = Constraint(says: "only Alpha", query: #""Alpha""#)

private func decoded(_ json: String) throws -> ConstraintList {
    try JSONDecoder().decode(ConstraintList.self, from: Data(json.utf8))
}

@MainActor private func rename(_ id: ShapeID, to title: String?, on h: EditorHarness) {
    h.editor.transact("Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
}

@MainActor let namesTests = Suite("Constraints: what a query's titles named, by id", [
    test("names are coded as an object of ids by title, left out while there are none, and part of the value") {
        let alpha = ShapeID()
        let bound = Constraint(says: "only Alpha", query: #""Alpha""#, names: ["Alpha": alpha])
        let json = try JSONValue(encoding: ConstraintList([bound, onlyTiles]))
        expectEqual(json.compactText, "[{\"names\":{\"Alpha\":\"\(alpha)\"},\"query\":\"\\\"Alpha\\\"\",\"reach\":\"children\",\"says\":\"only Alpha\"},"
                    + #"{"query":"tile","reach":"children","says":"only tiles"}]"#, "none, none written: as it always was")
        let again = try JSONDecoder().decode(ConstraintList.self, from: try JSONEncoder().encode(ConstraintList([bound, onlyTiles])))
        expectEqual(again.constraints, [bound, onlyTiles])
        expect(bound != Constraint(says: "only Alpha", query: #""Alpha""#), "the binding is part of what a constraint is")
        expectEqual(Set([bound, Constraint(says: "only Alpha", query: #""Alpha""#)]).count, 2)
        expectEqual(Constraint(says: "no query", query: nil, names: ["Alpha": alpha]).names, [:], "words not interpreted name nothing")
    },
    test("names read leniently: anything that isn't an object of ids reads as none, an entry whose id doesn't read is dropped") {
        let alpha = ShapeID()
        let list = try decoded("""
            [{"says": "a", "query": "tile", "names": "Alpha"},
             {"says": "b", "query": "tile", "names": ["Alpha"]},
             {"says": "c", "query": "tile", "names": {"Alpha": 7}},
             {"says": "d", "query": "tile", "names": null},
             {"says": "e", "query": "tile", "names": {"Alpha": "\(alpha)", "Beta": "not an id"}}]
            """)
        expectEqual(list.constraints.map(\.names), [[:], [:], [:], [:], ["Alpha": alpha]])
        expectEqual(list.constraints.map(\.says), ["a", "b", "c", "d", "e"], "no member is lost for it")
    },
    test("the writer binds a query's titles as it writes one the list didn't have: add, replace, setQuery, edit and the root's") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0)), beta = h.tile("Beta", at: CGPoint(x: 900, y: 100))
        let p = h.corral("Pen", pen)
        expect(h.writer.add(alphaOnly, to: .shape(p)))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Alpha": alpha], "add")
        expect(h.writer.replace(alphaOnly, with: Constraint(says: "only Beta", query: #""Beta""#), in: .shape(p)))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Beta": beta], "replace, a new query")
        let beta1 = try require(h.writer.constraints(of: .shape(p))?.first)
        expect(h.writer.setQuery(#":not("Alpha")"#, of: beta1, in: .shape(p)))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Alpha": alpha], "setQuery binds the new query, not the old")
        h.editor.transact("Constrain") { transaction in
            h.writer.edit(.shape(p), in: &transaction) { ConstraintWriter.adding(Constraint(says: "no Beta", query: #":not("Beta")"#), to: &$0) }
            h.writer.edit(.root, in: &transaction) { ConstraintWriter.adding(Constraint(says: "root Alpha", query: #":is("Alpha", "Beta")"#), to: &$0) }
        }
        expectEqual(h.writer.constraints(of: .shape(p))?.last?.names, ["Beta": beta], "edit")
        expectEqual(h.writer.constraints(of: .root)?.first?.names, ["Alpha": alpha, "Beta": beta], "the root's, a choice")
        expectEqual(h.file[RootConstraintsProperty.self].constraints.first?.names.count, 2)
    },
    test("a holder's list is written bound, through the one codec") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let sprint = h.add(Charter(CGRect(x: 0, y: 0, width: 200, height: 100), name: "Sprint"))
        expect(h.writer.add(alphaOnly, to: .shape(sprint)))
        expectEqual(h.writer.constraints(of: .shape(sprint))?.first?.names, ["Alpha": alpha])
        let list = try require(h.editor.document[sprint]?.typed(as: Charter.self)?.props.list)
        expect(list.contains("\(alpha)"), list)
    },
    test("a constraint the writer leaves as it was keeps its own names, and a query it keeps keeps them through a change of reach or words") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        rename(alpha, to: "Omega", on: h)
        // Another constraint written: the first is not bound again (Alpha is no longer called so).
        h.writer.add(onlyTiles, to: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Alpha": alpha])
        let first = try require(h.writer.constraints(of: .shape(p))?.first)
        h.writer.setReach(.descendants, of: first, in: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Alpha": alpha], "its reach changed")
        let deep = try require(h.writer.constraints(of: .shape(p))?.first)
        h.writer.replace(deep, with: Constraint(says: "only that one", query: deep.query, reach: .descendants), in: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Alpha": alpha], "its words changed, its query not")
        let words = try require(h.writer.constraints(of: .shape(p))?.first)
        expect(!h.writer.setQuery(words.query, of: words, in: .shape(p)), "the same query again changes nothing")
    },
    test("a title that names nothing, or two shapes, binds nothing, and what is written before the shape exists stays unbound") {
        let h = try constraintHarness()
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, [:], "no Alpha yet")
        h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, [:], "nothing writes it again by itself")
        let q = h.corral("Cage", CGRect(x: 600, y: 100, width: 200, height: 200))
        h.tile("Alpha", at: CGPoint(x: 900, y: 100))
        h.writer.add(alphaOnly, to: .shape(q))
        expectEqual(h.writer.constraints(of: .shape(q))?.first?.names, [:], "two tiles are called Alpha")
    },
    test("words not interpreted and a query with no title head are written with no names, and the file is not read for them") {
        let h = try constraintHarness()
        let p = h.corral("Pen", pen)
        h.writer.add(Constraint(says: "only whatever"), to: .shape(p))
        h.writer.add(onlyTiles, to: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.map(\.names), [[:], [:]])
    },

    test("a rename changes no verdict: what was accepted still is, nothing is flagged, no step is made, and nothing is asked again") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 200, y: 200)), beta = h.tile("Beta", at: CGPoint(x: 300, y: 200))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        h.editor.transact("Move in") { $0.setContainer(alpha, to: p); $0.setContainer(beta, to: p) }
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [beta], "Beta is not Alpha")
        let queries = try require(h.editor.queries)
        let whole = queries.standingWholeAsks, shape = queries.standingShapeAsks, judged = h.index.shapesJudged, walked = h.index.placesWalked
        let list = h.writer.constraints(of: .shape(p))
        rename(alpha, to: "Omega", on: h)
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [beta], "Omega is the shape the constraint named")
        expectEqual(h.issues(of: alpha), [], "no ring")
        expectEqual(h.issues(of: beta), ["Pen accepts only Alpha."], "the words are the person's")
        expectEqual(h.writer.constraints(of: .shape(p)), list, "nothing written")
        expectEqual(h.editor.undoHistory.undoName, "Rename", "no step of its own")
        expectEqual(queries.standingWholeAsks, whole, "no standing query asked anew")
        expect(queries.standingShapeAsks - shape <= 1, "the renamed shape alone, at most")
        expectEqual(h.index.placesWalked, walked, "no place walked")
        expectEqual(h.index.shapesJudged, judged, "no shape judged")
        expectEqual(h.index.constraintsRebound, 0)
        h.editor.undo()
        h.settle()
        expectEqual(h.editor.document[alpha]?[TitleProperty.self], "Alpha", "undone, exactly")
        expectEqual(h.breakers(of: .shape(p)), [beta])
        h.editor.redo()
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [beta])
        expectEqual(h.issues(of: alpha), [])
    },
    test("without names a list is judged by its titles as written: the same rename flags the shape") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 200, y: 200))
        let p = h.corral("Pen", pen, [alphaOnly])
        h.editor.transact("Move in") { $0.setContainer(alpha, to: p) }
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [])
        expectEqual(h.index.constraints(of: .shape(p)).map(\.constraint.names), [[:]], "written by hand: none")
        rename(alpha, to: "Omega", on: h)
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [alpha], "judged by a title nothing has")
    },
    test("a shape dropped in is judged by the shape the constraint named, whatever it is called") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let alpha = h.tile("Alpha", at: CGPoint(x: 600, y: 250)), beta = h.tile("Beta", at: CGPoint(x: 600, y: 350))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        rename(alpha, to: "Omega", on: h)
        h.settle()
        h.drop(from: CGPoint(x: 660, y: 290), to: CGPoint(x: 300, y: 250))
        expectEqual(h.editor.holder(of: alpha), p, "Omega is let in")
        expectEqual(log.refusals, [])
        h.drop(from: CGPoint(x: 660, y: 390), to: CGPoint(x: 300, y: 350))
        expectEqual(h.editor.holder(of: beta), nil, "Beta is refused")
        expectEqual(log.refusals, [[p]])
        expectEqual(h.editor.announcements.last, "Pen accepts only Alpha.")
    },
    test("the shape deleted: judged by the title as written, one query for the one that names it; its undo by the id again") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 200, y: 200)), beta = h.tile("Beta", at: CGPoint(x: 300, y: 200))
        let p = h.corral("Pen", pen), q = h.corral("Cage", CGRect(x: 600, y: 100, width: 200, height: 200)), r = h.corral("Yard", CGRect(x: 900, y: 100, width: 200, height: 200))
        h.writer.add(alphaOnly, to: .shape(p))
        h.writer.add(alphaOnly, to: .shape(q))
        h.writer.add(Constraint(says: "only Beta", query: #""Beta""#), to: .shape(r))
        let constraint = try require(h.writer.constraints(of: .shape(p))?.first)
        expectEqual(h.index.text(of: constraint), "#" + alpha.description.uppercased())
        expectEqual(h.index.text(of: try require(h.writer.constraints(of: .shape(r))?.first)), "#" + beta.description.uppercased())
        h.editor.transact("Move in") { $0.setContainer(beta, to: p) }
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [beta])
        let queries = try require(h.editor.queries)
        let rebound = h.index.constraintsRebound, walked = h.index.placesWalked, whole = queries.standingWholeAsks
        h.editor.transact("Delete") { $0.delete([alpha]) }
        h.settle()
        expectEqual(h.index.text(of: constraint), #""Alpha""#, "the title as written")
        expectEqual(h.index.constraintsRebound - rebound, 1, "one constraint read again")
        expectEqual(h.index.placesWalked - walked, 2, "the two places that have it, and no other")
        expectEqual(queries.standingWholeAsks - whole, 1, "one standing query asked: the title's")
        expectEqual(h.breakers(of: .shape(p)), [beta])
        // A tile now called Alpha is the one a title reads as.
        let again = h.tile("Alpha", at: CGPoint(x: 400, y: 200), in: p)
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [beta], "the new Alpha is accepted by the title")
        expectEqual(h.index.breaches(of: again), [])
        h.editor.transact("Delete") { $0.delete([again]) }
        for _ in 1...3 { h.editor.undo() }
        h.settle()
        expectEqual(h.index.text(of: constraint), "#" + alpha.description.uppercased(), "the delete undone: by id again")
        expectEqual(h.editor.document[alpha]?[TitleProperty.self], "Alpha")
        expectEqual(h.editor.document[beta]?.box != nil, true)
        expectEqual(h.index.constraintsRebound - rebound, 2, "away, back")
        expectEqual(h.index.text(of: try require(h.writer.constraints(of: .shape(r))?.first)), "#" + beta.description.uppercased(), "Yard's was never read again")
    },
    test("a commit that adds or removes a shape no constraint names reads no constraint again; a rename of a named shape neither") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        h.settle()
        let rebound = h.index.constraintsRebound, walked = h.index.placesWalked
        let other = h.tile("Gamma", at: CGPoint(x: 900, y: 200))
        h.editor.transact("Delete") { $0.delete([other]) }
        rename(alpha, to: "Delta", on: h)
        h.editor.transact("Move") { $0.moveBox(alpha, to: CGPoint(x: 950, y: 50)) }
        h.settle()
        expectEqual(h.index.constraintsRebound, rebound)
        expectEqual(h.index.placesWalked, walked)
    },
    test("a file put in place binds nothing again: the constraints it holds are judged by the ids they carry") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 200, y: 200))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        h.editor.transact("Move in") { $0.setContainer(alpha, to: p) }
        rename(alpha, to: "Omega", on: h)
        let file = h.file
        h.editor.replaceFile(with: file)
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [])
        expectEqual(h.index.text(of: try require(h.writer.constraints(of: .shape(p))?.first)), "#" + alpha.description.uppercased())
    },

    test("the panel shows the query with the titles the shapes have now, and focusing and leaving the box writes nothing") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(p)
        panel.window.spin { panel.boxes.count == 3 }
        expectEqual(panel.boxes[1].string, #""Alpha""#)
        rename(alpha, to: "Omega", on: h)
        panel.land()
        panel.window.spin { panel.boxes[1].string == #""Omega""# }
        expectEqual(panel.boxes[1].string, #""Omega""#, "a renamed shape shows its new name")
        let stored = h.list(of: p), revision = h.editor.revision
        panel.window.makeFirstResponder(panel.boxes[1])
        panel.window.settle()
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.settle()
        expectEqual(h.editor.revision, revision, "focusing and leaving it writes nothing")
        expectEqual(h.list(of: p), stored)
        expectEqual(stored.first?.query, #""Alpha""#, "the stored query is as it was written")
        expectEqual(h.index.state(of: try require(stored.first)), .standing)
    },
    test("a query written in the box is bound again as it reads now: a name a shape was renamed from names what it names now") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0)), beta = h.tile("Beta", at: CGPoint(x: 900, y: 100))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        rename(alpha, to: "Omega", on: h)
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(p)
        panel.window.spin { panel.boxes.count == 3 && panel.boxes[1].string == #""Omega""# }
        // Written as shown plus another: bound again, both by what they name now.
        panel.window.makeFirstResponder(panel.boxes[1])
        panel.boxes[1].selectAll(nil)
        panel.window.type(#":is("Omega", "Beta")"#)
        panel.window.makeFirstResponder(panel.boxes[2])
        panel.window.settle()
        let written = try require(h.list(of: p).first)
        expectEqual(written.query, #":is("Omega", "Beta")"#, "stored as it reads now")
        expectEqual(written.names, ["Omega": alpha, "Beta": beta])
        expectEqual(h.editor.undoHistory.undoName, "Change Constraint")
        // The old title typed back: it names nothing now, so it is bound to nothing.
        // The panel as it is when a person comes back to it.
        panel.window.close()
        let again = ConstraintsPanelWindow(h)
        defer { again.window.close() }
        try again.show(p)
        again.window.spin { again.boxes.count == 3 && again.boxes[1].string == #":is("Omega", "Beta")"# }
        again.window.makeFirstResponder(again.boxes[1])
        again.boxes[1].selectAll(nil)
        again.window.type(#""Alpha""#)
        again.window.makeFirstResponder(again.boxes[2])
        again.window.settle()
        expectEqual(h.list(of: p).first?.query, #""Alpha""#)
        expectEqual(h.list(of: p).first?.names, [:], "as written: judged by the title, which nothing has")
    },
    test("a list from elsewhere shows its query with the titles now, read-only") {
        let given = Given()
        let h = try constraintHarness(given)
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let charter = h.add(Charter(CGRect(x: 900, y: 200, width: 200, height: 100), name: "Sprint"))
        h.writer.add(alphaOnly, to: .shape(charter))
        let pen = h.corral("Pen", CGRect(x: 100, y: 100, width: 400, height: 300))
        given.lists[pen] = [ConstraintSource(holder: charter, swatch: Swatch(RGB(hex: 0x4465E9)),
                                             constraints: h.writer.constraints(of: .shape(charter)) ?? [])]
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.settle()
        rename(alpha, to: "Omega", on: h)
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(pen)
        panel.window.spin { panel.boxes.count == 2 }
        expectEqual(panel.boxes.map(\.string), [#""Omega""#, ""])
        expectEqual(panel.boxes.map(\.isEditable), [false, true])
    },

    test("a copy of a container names the copies of the shapes copied with it, as `is` does, and keeps the names of the rest") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0)), beta = h.tile("Beta", at: CGPoint(x: 900, y: 100))
        let p = h.corral("Pen", pen)
        h.writer.add(Constraint(says: "those two", query: #":is("Alpha", "Beta")"#), to: .shape(p))
        let record = try require(h.editor.document[p])
        expect(h.editor.registry.namingKinds.contains(Corral.kind), "a kind that holds a list names shapes")
        let copyOfAlpha = ShapeID()
        let alone = try require(record.remappingReferences({ $0 == alpha ? copyOfAlpha : nil }, in: h.editor.shapeContext))
        expectEqual(alone.ownConstraints.first?.names, ["Alpha": copyOfAlpha, "Beta": beta], "the copy of Alpha, and Beta as it was")
        expectEqual(alone.ownConstraints.first?.query, #":is("Alpha", "Beta")"#, "the query is as it was")
        let none = try require(record.remappingReferences({ _ in nil }, in: h.editor.shapeContext))
        expectEqual(none.ownConstraints, record.ownConstraints, "nothing copied along: every name kept")
        var seen: [ShapeID] = []
        record[ConstraintsProperty.self]?.forEachNamedShape { seen.append($0) }
        expectEqual(Set(seen), [alpha, beta])
    },
    test("a list written without names (an agent's, typed by hand) is judged by its titles as written, and a pasted one whose ids the file lacks too") {
        let h = try constraintHarness()
        let ghost = ShapeID()
        let alpha = h.tile("Alpha", at: CGPoint(x: 200, y: 200))
        let p = h.corral("Pen", pen, [Constraint(says: "only Alpha", query: #""Alpha""#, names: ["Alpha": ghost])])
        h.editor.transact("Move in") { $0.setContainer(alpha, to: p) }
        h.settle()
        expectEqual(h.index.text(of: try require(h.writer.constraints(of: .shape(p))?.first)), #""Alpha""#, "the id names nothing in this file: the title as written")
        expectEqual(h.breakers(of: .shape(p)), [], "Alpha is accepted by its title")
    },

    test("a holder that won't take a list: the write is refused and says so, as a refused change is: it shakes, a word is heard, no step") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let draft = h.add(Charter(CGRect(x: 0, y: 0, width: 200, height: 100), name: "Sprint", list: "not json yet"))
        let revision = h.editor.revision, step = h.editor.undoHistory.undoName
        expectEqual(h.writer.tryAdd(onlyTiles, to: .shape(draft)), .refused)
        expect(!h.writer.add(onlyTiles, to: .shape(draft)))
        expectEqual(log.refusals, [[draft], [draft]], "the holder shakes")
        expectEqual(h.editor.announcements, ["Can't add a constraint to Sprint.", "Can't add a constraint to Sprint."])
        expectEqual(h.editor.revision, revision, "nothing written")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        // What changes nothing is not a refusal.
        let plain = h.add(Charter(CGRect(x: 300, y: 0, width: 200, height: 100), name: "Ward"))
        h.writer.add(onlyTiles, to: .shape(plain))
        let said = h.editor.announcements.count
        expectEqual(h.writer.tryAdd(onlyTiles, to: .shape(plain)), .unchanged)
        expectEqual(h.editor.announcements.count, said)
        expectEqual(log.refusals.count, 2)
    },
    test("in the panel the holder shakes and a word is heard, the add box keeps the words, and Return again lands them once the list can") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let draft = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint", list: "not json yet"))
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(draft)
        panel.window.spin { panel.boxes.count == 1 }
        panel.type("tile", in: panel.boxes[0])
        panel.land()
        expectEqual(log.refusals, [[draft]], "the holder shakes")
        expectEqual(h.editor.announcements.last, "Can't add a constraint to Sprint.")
        expectEqual(panel.boxes[0].string, "tile", "the words stay in the box")
        expectEqual(h.list(of: draft), [])
        // The list is JSON now: committing the words again writes them.
        h.editor.transact("Fix") { $0.update(inFile: draft, as: Charter.self) { $0.props.list = "[]" } }
        panel.window.makeFirstResponder(panel.boxes[0])
        panel.window.pressReturn()
        panel.land()
        expectEqual(h.list(of: draft), [Constraint(says: "tile", query: "tile")])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(log.refusals, [[draft]], "no second refusal")
    },
    test("/constrain on a holder that won't take it says why in the bar and writes nothing; the other lists are written, the holder shakes") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log, model: ScriptedLanguageModel())
        let draft = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint", list: "not json yet"))
        let pen = h.corral("Pen", CGRect(x: 100, y: 100, width: 400, height: 300))
        let revision = h.editor.revision
        expectEqual(try h.constrain("tile", on: .selection([draft])), .failed("Can't add a constraint to Sprint."))
        expectEqual(h.editor.revision, revision, "nothing written, no step")
        expectEqual(log.refusals, [[draft]])
        expectEqual(try h.constrain("tile", on: .selection([draft, pen])), .failed("Can't add a constraint to Sprint."))
        expectEqual(h.list(of: pen), [Constraint(says: "tile", query: "tile")], "the one that could take it has it")
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        let other = h.add(Charter(CGRect(x: 800, y: 300, width: 100, height: 80), name: "Ward", list: "nope"))
        expectEqual(try h.constrain("tile", on: .selection([draft, other])), .failed("Can't add a constraint to 2 of the shapes."))
    },

    test("a shape on a pocket's board is bound too, and deleting the pocket takes it out of the file: its constraints are read again") {
        let h = try constraintHarness()
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        let inner = ShapeID()
        let record = AnyShapeRecord(ShapeRecord(id: inner, Tile(CGRect(x: 0, y: 0, width: 120, height: 80), label: "Deep")))
        var titled = record
        titled[TitleProperty.self] = "Deep"
        h.editor.transact(on: BoardID(owner: drawer)) { $0.insert(titled) }
        let p = h.corral("Pen", pen)
        h.writer.add(Constraint(says: "only Deep", query: #""Deep""#), to: .shape(p))
        let constraint = try require(h.writer.constraints(of: .shape(p))?.first)
        expectEqual(constraint.names, ["Deep": inner], "the file's, not only the board shown")
        expectEqual(h.index.text(of: constraint), "#" + inner.description.uppercased())
        h.editor.transact("Delete") { $0.delete([drawer]) }
        h.settle()
        expectEqual(h.index.text(of: constraint), #""Deep""#, "the shape went with its board")
        h.editor.undo()
        h.settle()
        expectEqual(h.index.text(of: constraint), "#" + inner.description.uppercased(), "and came back")
    },

    test("words typed in the panel's add box land bound, as the model's query reads the titles then; so does /constrain") {
        let model = ScriptedLanguageModel(answers: [#""Alpha""#, #":not("Beta")"#])
        let h = try constraintHarness(model: model)
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0)), beta = h.tile("Beta", at: CGPoint(x: 900, y: 100))
        let p = h.corral("Pen", pen, [onlyTiles])
        let panel = ConstraintsPanelWindow(h)
        defer { panel.window.close() }
        try panel.show(p)
        panel.window.spin { panel.boxes.count == 3 }
        panel.type("only Alpha", in: panel.boxes[2])
        panel.land(after: model, answers: 1)
        expectEqual(h.list(of: p).map(\.query), ["tile", #""Alpha""#])
        expectEqual(h.list(of: p).last?.names, ["Alpha": alpha], "an interpretation landing")
        expectEqual(try h.constrain("everything but Beta", on: .selection([p])), .done)
        expectEqual(h.list(of: p).last?.names, ["Beta": beta], "/constrain's landing")
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
    },

    test("an own list that names nothing beside an inherited one that does, with the same words and query: each judges") {
        let given = Given()
        let h = try constraintHarness(given)
        let alpha = h.tile("Alpha", at: CGPoint(x: 200, y: 200))
        let charter = h.add(Charter(CGRect(x: 900, y: 200, width: 200, height: 100), name: "Sprint"))
        h.writer.add(alphaOnly, to: .shape(charter))
        let inherited = try require(h.writer.constraints(of: .shape(charter)))
        expectEqual(inherited.first?.names, ["Alpha": alpha])
        // The place's own, written by hand (as `canvas draw` writes one): no names.
        let p = h.corral("Pen", pen, [alphaOnly])
        given.lists[p] = [ConstraintSource(holder: charter, swatch: Swatch(RGB(hex: 0x4465E9)), constraints: inherited)]
        h.index.inheritedConstraintsDidChange(of: [p])
        h.editor.transact("Move in") { $0.setContainer(alpha, to: p) }
        h.settle()
        expectEqual(h.index.judged(of: .shape(p)).count, 2, "two constraints that judge differently are both kept")
        rename(alpha, to: "Omega", on: h)
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [alpha], "the own list names Alpha by its title, which Omega no longer has")
        rename(alpha, to: "Alpha", on: h)
        h.settle()
        expectEqual(h.breakers(of: .shape(p)), [], "named again, both are met")
    },

    test("a shape going makes two constraints judge alike, and its undo apart: the place's list is read again") {
        let given = Given()
        let h = try constraintHarness(given)
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let charter = h.add(Charter(CGRect(x: 900, y: 200, width: 200, height: 100), name: "Sprint"))
        h.writer.add(alphaOnly, to: .shape(charter))
        let inherited = try require(h.writer.constraints(of: .shape(charter)))
        let p = h.corral("Pen", pen, [alphaOnly])
        given.lists[p] = [ConstraintSource(holder: charter, swatch: Swatch(RGB(hex: 0x4465E9)), constraints: inherited)]
        h.index.inheritedConstraintsDidChange(of: [p])
        h.settle()
        expectEqual(h.index.judged(of: .shape(p)).count, 2, "by the id, and by the title")
        h.editor.transact("Delete") { $0.delete([alpha]) }
        h.settle()
        expectEqual(h.index.judged(of: .shape(p)).count, 1, "both by the title: one")
        h.editor.undo()
        h.settle()
        expectEqual(h.index.judged(of: .shape(p)).count, 2, "apart again")
    },

    test("a second constraint with the query of a bound one is bound as it is: its names copied") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let p = h.corral("Pen", pen)
        expect(h.writer.add(alphaOnly, to: .shape(p)))
        expect(h.writer.add(Constraint(says: "also Alpha", query: alphaOnly.query), to: .shape(p)))
        let list = try require(h.writer.constraints(of: .shape(p)))
        expectEqual(list.map(\.names), [["Alpha": alpha], ["Alpha": alpha]])
    },
    test("setReach, and new words for the query a list has, don't bind a list written without names") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let p = h.corral("Pen", pen, [alphaOnly])
        let c = try require(h.writer.constraints(of: .shape(p))?.first)
        expectEqual(c.names, [:])
        h.writer.setReach(.descendants, of: c, in: .shape(p))
        let after = try require(h.writer.constraints(of: .shape(p))?.first)
        expectEqual(after.reach, .descendants)
        expectEqual(after.names, [:], "a query it had is not bound by a reach change")
        h.writer.replace(after, with: Constraint(says: "just Alpha", query: #""Alpha""#, reach: .descendants), in: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, [:], "nor by new words")
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.says, "just Alpha")
        // A different query is bound.
        h.writer.setQuery(#""Alpha""# + ", tile", of: try require(h.writer.constraints(of: .shape(p))?.first), in: .shape(p))
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Alpha": alpha])
    },

    test("a title the box showed for a shape the constraint named keeps that shape when another part of the query is edited") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let beta = h.tile("Beta", at: CGPoint(x: 900, y: 200))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        rename(alpha, to: "Beta", on: h)
        let c = try require(h.writer.constraints(of: .shape(p))?.first)
        let boxes = try require(h.editor.constraintBoxes)
        expectEqual(boxes.shown(c), #""Beta""#, "shown by the title it has now, which two shapes have")
        expectEqual(boxes.write(#":is("Beta", tile)"#, of: c, in: p), nil)
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Beta": alpha], "the one it named, not both")
        _ = beta
        // A title the person typed that names several is bound to none.
        let again = try require(h.writer.constraints(of: .shape(p))?.first)
        expectEqual(boxes.write(#":is("Beta", "Gamma")"#, of: again, in: p), nil)
        expectEqual(h.writer.constraints(of: .shape(p))?.first?.names, ["Beta": alpha], "an unchanged head keeps its shape")
    },

    test("a commit reads no constraint again unless it brings a shape one names into the file or takes it out") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0))
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        let inner = ShapeID()
        var titled = AnyShapeRecord(ShapeRecord(id: inner, Tile(CGRect(x: 0, y: 0, width: 120, height: 80), label: "Deep")))
        titled[TitleProperty.self] = "Deep"
        h.editor.transact(on: BoardID(owner: drawer)) { $0.insert(titled) }
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        h.writer.add(Constraint(says: "only Deep", query: #""Deep""#), to: .shape(p))
        h.settle()
        let read = h.index.constraintsRead
        let other = h.tile("Gamma", at: CGPoint(x: 900, y: 200))
        rename(other, to: "Delta", on: h)
        h.editor.transact("Move") { $0.moveBox(other, to: CGPoint(x: 950, y: 250)) }
        h.editor.transact("Delete") { $0.delete([other]) }
        rename(alpha, to: "Omega", on: h)
        h.editor.transact("Move") { $0.moveBox(alpha, to: CGPoint(x: 950, y: 50)) }
        h.editor.transact(on: BoardID(owner: drawer)) { $0.update(inner) { $0[TitleProperty.self] = "Other" } }
        h.editor.transact(on: BoardID(owner: drawer)) { $0.moveBox(inner, to: CGPoint(x: 10, y: 10)) }
        h.settle()
        expectEqual(h.index.constraintsRead - read, 0, "no add, remove, rename or move of a shape reads a constraint: of the shown board, or another's")
        h.editor.transact("Delete") { $0.delete([alpha]) }
        h.settle()
        expectEqual(h.index.constraintsRead - read, 1, "the one constraint that names the shape that went")
    },

    test("what shows a constraint's titles is told of an edit to a shape it names, and of no other commit") {
        let h = try constraintHarness()
        let alpha = h.tile("Alpha", at: CGPoint(x: 900, y: 0)), other = h.tile("Gamma", at: CGPoint(x: 900, y: 200))
        let p = h.corral("Pen", pen)
        h.writer.add(alphaOnly, to: .shape(p))
        let c = try require(h.writer.constraints(of: .shape(p))?.first)
        let boxes = try require(h.editor.constraintBoxes)
        final class Told: @unchecked Sendable { var count = 0 }
        let told = Told()
        withObservationTracking({ MainActor.assumeIsolated { _ = boxes.shown(c) } }, onChange: { told.count += 1 })
        h.editor.transact("Move") { $0.moveBox(other, to: CGPoint(x: 950, y: 250)) }
        rename(other, to: "Delta", on: h)
        h.tile("New", at: CGPoint(x: 900, y: 600))
        h.settle()
        expectEqual(told.count, 0, "an unrelated commit tells nothing")
        rename(alpha, to: "Omega", on: h)
        h.settle()
        expectEqual(told.count, 1, "a rename of the shape it names does")
        expectEqual(boxes.shown(c), #""Omega""#)
    },
])
