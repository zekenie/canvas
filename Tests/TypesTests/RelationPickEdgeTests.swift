import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import TextEditing
import Titles
import Topology
import Types
import Validation

@MainActor private func drawing() -> [any CanvasPlugin] {
    [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()]
}

@MainActor private func ids(_ picker: RelationPicker) -> [ShapeID] { picker.choices.map(\.candidate.id) }

@MainActor let relationPickEdgeTests = Suite("The row's list and its picks, at their edges", [
    test("a query that begins with a space lists what a fresh list lists for it (Space pressed in the open list, then letters)") {
        let s = try RelationScene.drawn()
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        for text in [" ", " f", " fo", " fou"] {
            picker.setQuery(text)
            let fresh = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
            fresh.setQuery(text)
            expectEqual(ids(picker), ids(fresh), "typed up to `\(text)`: \(s.lines(picker).map(\.title)) against a fresh list's \(s.lines(fresh).map(\.title)); the rows: \(picker.list.rows.first.map { "\($0)" } ?? "none")")
        }
    },
    test("a row on both sides whose two sides hold different types: every note the list offers, picked, gives a relationship that fits") {
        let s = try RelationScene(more: drawing())
        // `rel` runs from Feature or Layer, to Feature; Feature's two ends share the typed name `peer`, so they are one row.
        s.editor.addBond(s.feature, s.rel, name: "peer")
        s.editor.addBond(s.rel, s.feature, name: "peer")
        s.editor.addBond(s.layer, s.rel)
        let row = try require(s.index.rows(for: [s.feature], isType: false).first { $0.key.label == .typed("peer") })
        expectEqual(row.sides, [.from, .to])
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: row)
        expect(ids(picker).contains(s.layerNote), "the Layer note is offered: \(s.lines(picker).map(\.title))")
        let arrow = try require(s.editor.relate(s.note, to: s.layerNote, in: row))
        let bond = try require(s.editor.document[arrow]?.typed(as: Bond.self))
        let fit = try require(s.index.graph.fit(of: s.rel, from: .note(try require(bond.props.from)), to: .note(try require(bond.props.to))))
        expect(fit.holds, "the arrow the pick drew is a misfit: from \(bond.props.from == s.note ? "the Feature note" : "the Layer note") to \(bond.props.to == s.note ? "the Feature note" : "the Layer note"), fit \(fit)")
        expectEqual(s.editor.issues(arrow).filter { $0.severity == .error }.map(\.message), [], "no red on an arrow the row's own list drew")
    },
    test("a far private pick that reuses the note's pill: one step, one Undo returns both boards byte for byte, Redo repeats") {
        let s = try RelationScene.drawn()
        let other = s.editor.addRelationshipType("on", at: CGPoint(x: 700, y: 40))
        s.editor.addBond(s.feature, other)
        s.editor.addBond(other, s.layer)
        s.setOpen(s.awayLayer)
        expect(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()) != nil)
        // Private again by a path with no guard: the pill stays, dashed.
        s.setOpen(s.awayLayer, false)
        s.editor.undoHistory.seal()
        let start = try s.bytes(), file = s.editor.file
        let second = try require(s.index.rows(for: [s.feature], isType: false).first { $0.key.type == other })
        expectEqual(s.editor.farVerdict(of: s.awayLayer), .fulfils(needs: "open"))
        let steps = s.editor.undoHistory.undoName
        expect(s.editor.relate(s.note, to: s.awayLayer, in: second) != nil, "picked")
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        expectEqual(s.relays().count, 1, "the pill is reused")
        expectEqual(s.editor.file.record(s.awayLayer)?.meta[Open.self], true)
        let done = try s.bytes()
        s.editor.undo()
        expect(try s.bytes() == start, "bytes after undo")
        expect(s.editor.file == file, "file after undo")
        expectEqual(s.editor.undoHistory.undoName, steps)
        s.editor.redo()
        expect(try s.bytes() == done, "bytes after redo")
    },
    test("deletes: one that leaves the pill, then one that empties it, are two steps, each undone exactly; a delete from the far note's own row") {
        let s = try RelationScene.drawn()
        let other = s.editor.addRelationshipType("on", at: CGPoint(x: 700, y: 40))
        s.editor.addBond(s.feature, other)
        s.editor.addBond(other, s.layer)
        let second = try require(s.index.rows(for: [s.feature], isType: false).first { $0.key.type == other })
        let a = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        let b = try require(s.editor.relate(s.note, to: s.awayLayer, in: second))
        s.editor.undoHistory.seal()
        let both = try s.bytes(), bothFile = s.editor.file
        expect(s.editor.unrelate([a], shaking: s.note))
        expectEqual(s.relays().count, 1, "the pill another arrow holds stays")
        let one = try s.bytes(), oneFile = s.editor.file
        expect(s.editor.unrelate([b], shaking: s.note))
        expectEqual(s.relays().count, 0, "emptied: it goes")
        expectEqual(s.editor.file.record(s.awayLayer)?.meta[Open.self], true, "the far note stays open")
        let none = try s.bytes()
        s.editor.undo()
        expect(try s.bytes() == one && s.editor.file == oneFile, "the second delete undone")
        s.editor.undo()
        expect(try s.bytes() == both && s.editor.file == bothFile, "the first delete undone")
        s.editor.redo()
        s.editor.redo()
        expect(try s.bytes() == none, "both redone")
        s.editor.undo()
        s.editor.undo()
        // From the far note's own board: the arrows are on the root, which is not shown.
        expect(s.editor.showBoard(s.pocketBoard))
        s.editor.undoHistory.seal()
        let pills = try s.pills(s.awayLayer, "feature").pills
        expectEqual(pills.map(\.target), [s.note], "the far note's row reads the relationship drawn on the root")
        let steps = s.editor.undoHistory.undoName
        expect(s.editor.unrelate([a, b], shaking: s.awayLayer))
        expectEqual(s.editor.board, s.pocketBoard)
        expectEqual(s.editor.undoHistory.undoName, "Remove Relationship")
        expectEqual(s.relays(on: .root).count, 0)
        s.editor.undo()
        expectEqual(s.editor.board, s.pocketBoard, "undo does not switch boards")
        expect(try s.bytes() == both && s.editor.file == bothFile, "the far delete undone")
        expectEqual(s.editor.undoHistory.undoName, steps)
        expect(s.editor.showBoard(.root))
    },
    test("refusals change nothing and open no step: a locked pill the delete would empty; a locked far private note; a far note on a locked board") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        s.setOpen(s.awayLayer)
        let arrow = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        let pill = try require(s.relays().first).id
        s.editor.freeze([pill])
        s.editor.undoHistory.seal()
        let locked = try s.bytes(), steps = s.editor.undoHistory.undoName
        expect(!s.editor.unrelate([arrow], shaking: s.note), "the pill it would empty is locked")
        expect(try s.bytes() == locked)
        expectEqual(s.editor.undoHistory.undoName, steps)
        expect(!s.editor.undoHistory.canUndo || s.editor.undoHistory.undoName == steps)
        s.editor.freeze([pill], false)
        // A far private note that is locked is not picked.
        s.editor.transact(on: s.pocketBoard) { $0.insert(slipRecord("Shut", of: [s.layer], at: CGPoint(x: 0, y: 800))) }
        let shut = try require(s.editor.contents(of: s.pocketBoard).shapes.last).id
        s.editor.transact { $0.update(inFile: shut) { $0[Frozen.self] = true } }
        s.editor.undoHistory.seal()
        let before = try s.bytes(), stepsBefore = s.editor.undoHistory.undoName
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        expect(!s.lines(picker).map(\.title).contains("Shut"), "left out of the list: \(s.lines(picker).map(\.title))")
        expectEqual(s.editor.relate(s.note, to: shut, in: try s.featureRow()), nil)
        expect(try s.bytes() == before)
        expectEqual(s.editor.undoHistory.undoName, stepsBefore)
    },
    test("the list is whole over three boards: titled notes, notes with words, notes with values only and notes with nothing, near and far, each with its board; none that does not fit; the empty words") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        // A third board.
        let attic = ShapeID()
        s.editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: attic, Pocket(CGRect(x: 300, y: 1200, width: 100, height: 100))))) }
        let atticBoard = BoardID(owner: attic)
        expect(s.editor.showBoard(atticBoard))
        expect(s.editor.showBoard(.root))
        @MainActor func valued(_ values: JSONObject, title: String? = nil) -> AnyShapeRecord {
            var record = slipRecord("", of: [s.layer], at: CGPoint(x: 0, y: 300))
            if !values.isEmpty { record[FieldValuesProperty.self] = FieldValues(values) }
            if let title { record[TitleProperty.self] = title }
            return record
        }
        let nearValues = valued(["order": 3]), nearNothing = valued([:]), nearTitled = valued([:], title: "Titled near")
        let farValues = valued(["order": 4]), farNothing = valued([:]), farTitled = valued([:], title: "Titled far")
        let atticWords = slipRecord("Attic words", of: [s.layer], at: CGPoint(x: 0, y: 0)), atticValues = valued(["order": 5]), atticNothing = valued([:])
        let stranger = slipRecord("A feature elsewhere", of: [s.feature], at: CGPoint(x: 300, y: 300))
        s.editor.transact { t in for r in [nearValues, nearNothing, nearTitled] { t.insert(r) } }
        s.editor.transact(on: s.pocketBoard) { t in for r in [farValues, farNothing, farTitled] { t.insert(r) } }
        s.editor.transact(on: atticBoard) { t in for r in [atticWords, atticValues, atticNothing, stranger] { t.insert(r) } }
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        let listed = Set(ids(picker))
        let fitting: [(String, ShapeID)] = [("near words", s.layerNote), ("near values", nearValues.id), ("near nothing", nearNothing.id), ("near titled", nearTitled.id),
                                            ("far words", s.awayLayer), ("far values", farValues.id), ("far nothing", farNothing.id), ("far titled", farTitled.id),
                                            ("attic words", atticWords.id), ("attic values", atticValues.id), ("attic nothing", atticNothing.id)]
        for (name, id) in fitting { expect(listed.contains(id), "\(name) is not listed: \(s.lines(picker))") }
        expectEqual(listed.count, fitting.count, "nothing else: \(s.lines(picker))")
        expect(!listed.contains(stranger.id) && !listed.contains(s.away))
        // Each far line says its board; no near line does. (Lines called alike say their kind first, near or far: Mentions' rule.)
        let near: Set<ShapeID> = [s.layerNote, nearValues.id, nearNothing.id, nearTitled.id]
        for (index, choice) in picker.choices.enumerated() {
            let detail = picker.list.rows[index].item?.detail
            if near.contains(choice.candidate.id) { expect(detail == nil || detail == "row-slip", "\(choice.candidate.appearance.label): \(detail ?? "")") }
            else { expect(detail != nil && !(detail ?? "").isEmpty, "a far line with no board: \(choice.candidate.appearance.label)") }
        }
        // Typed: by values on another board, and the unnamed by their placeholder.
        picker.setQuery("5")
        expectEqual(ids(picker), [atticValues.id])
        picker.setQuery("untitled")
        expectEqual(Set(ids(picker)), [nearNothing.id, farNothing.id, atticNothing.id])
        // Every Layer but ones that cannot be picked: the words do not say there is no Layer.
        s.editor.transact { $0.delete([s.layerNote, nearValues.id, nearNothing.id, nearTitled.id]) }
        s.editor.transact(on: atticBoard) { $0.delete([atticWords.id, atticValues.id, atticNothing.id]) }
        for id in [s.awayLayer, farValues.id, farNothing.id, farTitled.id] { s.editor.transact { $0.update(inFile: id) { $0[Frozen.self] = true } } }
        let shut = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        expectEqual(shut.list.rows, [.empty("No notes")], "Layers exist and none can be picked")
    },
    test("narrowing against a fresh list over a hub with look-alike names, values and nothing: extends, shrinks, changes wholesale, with a commit in between") {
        let s = try RelationScene.drawn()
        let words = ["Alpha", "Alphabet", "Alpine", "Beta", "Albatross", "Layer", "Player", "Relay", "Delay", "Alp ha", "Gamma ray", "Gram", "Grammar", "Hal 9000", "Halo"]
        s.editor.transact("Layers") { t in
            for number in 0..<240 {
                t.insert(slipRecord("\(words[number % words.count]) \(number)", of: [s.layer], at: CGPoint(x: 40 + Double(number % 20) * 30, y: 1500 + Double(number / 20) * 30)))
            }
            for number in 0..<12 {
                var record = slipRecord("", of: [s.layer], at: CGPoint(x: 40 + Double(number) * 30, y: 3000))
                if number % 2 == 0 { record[FieldValuesProperty.self] = FieldValues(["purpose": .string("alpha value \(number)")]) }
                t.insert(record)
            }
        }
        s.editor.transact(on: s.pocketBoard, "Far layers") { t in
            for number in 0..<60 { t.insert(slipRecord("\(words[number % words.count]) far \(number)", of: [s.layer], at: CGPoint(x: Double(number) * 30, y: 600))) }
        }
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        @MainActor func check(_ text: String) throws {
            picker.setQuery(text)
            let fresh = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
            fresh.setQuery(text)
            expectEqual(ids(picker), ids(fresh), "`\(text)`: \(s.lines(picker).map(\.title).prefix(6)) against \(s.lines(fresh).map(\.title).prefix(6))")
            expectEqual(picker.list.rows.count, fresh.list.rows.count, "`\(text)` rows")
        }
        let runs: [[String]] = [
            ["a", "al", "alp", "alph", "alpha", "alpha ", "alpha 1", "alpha 12", "alpha 120", "alpha 12", "alpha 1", "alpha"],
            ["g", "gr", "gra", "gram", "gramm", "gramma", "grammar", "grammar 1", "grammar 12"],
            ["h", "ha", "hal", "hal ", "hal 9", "hal 90", "halo", "halo 1", "halo 14"],
            ["u", "un", "unt", "unti", "untit", "untitl", "untitle", "untitled", "untitled n"],
            ["alpha v", "alpha va", "alpha val", "alpha valu", "alpha value", "alpha value 4"],
            ["pla", "play", "plaey", "plaeyr", "plaeyr 2"],
            ["rel", "rela", "relay", "relay f", "relay fa", "relay far", "relay far 2", "delay far 2", "d", ""],
            ["x", "xa", "xal", "xalp", "xalph", "xalpha"],
            ["al", "alp", "alpi", "alpin", "alpine", "alpine 1", "alpine 17", "alpine 177"],
        ]
        for run in runs { for text in run { try check(text) } }
        // A commit in the middle of a query: a note of the type added.
        try check("alb")
        try check("alba")
        let late = s.editor.addSlip("Albatross late", of: [s.layer], at: CGPoint(x: 900, y: 500))
        try check("albat")
        expect(ids(picker).contains(late), "the note added mid-query is listed at the next keystroke")
    },
    test("an open side lists any note of a kind that draws rows, near and far, but the owner, a type, a relationship type and a note the row shows; and none it cannot pick") {
        let s = try RelationScene(more: drawing() + [FreezingPlugin(log: RefusalLog())])
        s.fromEnd()
        let row = try require(s.index.rows(for: [s.feature], isType: false).first)
        expect(row.others.isEmpty, "the other side is open")
        let plain = s.editor.addSlip("Plain", at: CGPoint(x: 900, y: 500))
        let kinds = Set(s.editor.registry.kinds.filter { s.editor.registry.typeRows(of: $0) != nil })
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: row, kinds: kinds)
        let listed = Set(ids(picker))
        for (name, id) in [("a typed note", s.layerNote), ("an untyped note", plain), ("a far note", s.awayLayer), ("a far note of the owner's type", s.away)] {
            expect(listed.contains(id), "\(name) is not listed: \(s.lines(picker).map(\.title))")
        }
        for (name, id) in [("the owner", s.note), ("a type", s.feature), ("a type", s.layer), ("the relationship type", s.rel)] {
            expect(!listed.contains(id), "\(name) is listed")
        }
        // A far private locked note is left out, as on a typed side.
        s.editor.transact { $0.update(inFile: s.awayLayer) { $0[Frozen.self] = true } }
        picker.setQuery("")
        expect(!ids(picker).contains(s.awayLayer), "a note that cannot be picked is listed on an open side")
        picker.setQuery("down")
        expect(!ids(picker).contains(s.awayLayer), "and typed for")
        // Shown by the row: gone from the list.
        expect(s.editor.relate(s.note, to: plain, in: row) != nil)
        picker.setQuery("")
        expect(!ids(picker).contains(plain), "a note the row shows is listed again")
    },
test("a refused pick and a refused delete are refused once: services hear one refusal, and the note shakes for it") {
    let log = RefusalLog()
    let s = try RelationScene.drawn(more: [FreezingPlugin(log: log)])
    let arrow = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
    log.refusals = []
    s.editor.freeze([s.note])
    expectEqual(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()), nil)
    expectEqual(log.refusals, [[s.note]], "a read-only note")
    s.editor.freeze([s.note], false)
    log.refusals = []
    s.editor.transact { $0.update(inFile: s.awayLayer) { $0[Frozen.self] = true } }
    expectEqual(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()), nil)
    expectEqual(log.refusals, [[s.note]], "a far note that cannot be picked")
    log.refusals = []
    s.editor.freeze([arrow])
    expect(!s.editor.unrelate([arrow], shaking: s.note))
    expectEqual(log.refusals, [[s.note]], "a locked arrow")
    log.refusals = []
    expect(!s.editor.unrelate([ShapeID()], shaking: s.note))
    expectEqual(log.refusals, [[s.note]], "an arrow that is gone")
},
])
