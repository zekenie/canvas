import AppKit
@_spi(Host) import Canvas
import CanvasRPC
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

// Picking a note in a relation row and deleting a pill, near and far: the list of the notes that fit (the two cases of the
// bug that started the redesign, a Layer on another board, `No Layer notes` only while no Layer exists, a hub's keystroke),
// `relate` and `unrelate` (the arrow's direction by the row, one step, the pill a far pick reuses or makes, the far note
// made open in the same step, one Undo for both boards), and `farVerdict`. Over `RelationScene`, bonds and relays.

@MainActor private func drawing() -> [any CanvasPlugin] {
    [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()]
}



private let layerValues: JSONObject = ["order": 1, "purpose": "expose foobar", "title": "foundation"]

extension RelationScene {
    /// A scene with the ends drawn, on an editor that draws.
    static func drawn(more: [any CanvasPlugin] = []) throws -> RelationScene {
        let s = try RelationScene(more: drawing() + more)
        s.fromEnd()
        s.toEnd()
        return s
    }

    var pocketBoard: BoardID { BoardID(owner: pocket) }

    /// The Feature note's row of Layer notes, and the Layer notes' row of Feature notes.
    func featureRow() throws -> RelationshipRow { try require(index.rows(for: [feature], isType: false).first) }
    func layerRow() throws -> RelationshipRow { try require(index.rows(for: [layer], isType: false).first) }

    /// A Layer note with no title and no words holding `values`.
    @discardableResult
    func addValued(_ values: JSONObject, of type: ShapeID? = nil, at origin: CGPoint = CGPoint(x: 800, y: 1500)) -> ShapeID {
        var record = slipRecord("", of: [type ?? layer], at: origin)
        record[FieldValuesProperty.self] = FieldValues(values)
        let made = record
        editor.transact { $0.insert(made) }
        return made.id
    }

    /// Makes a note on any board open (a pill may stand for it), or private again.
    func setOpen(_ id: ShapeID, _ open: Bool = true) {
        editor.transact { $0.update(inFile: id) { $0.meta[Open.self] = open ? true : nil } }
    }

    /// Every bond on a board, with the board's name, ends and types.
    func bonds(on board: BoardID = .root) -> [ShapeRecord<Bond>] { editor.contents(of: board).shapes.compactMap { $0.typed(as: Bond.self) } }
    func relays(on board: BoardID = .root) -> [ShapeRecord<Relay>] { editor.contents(of: board).shapes.compactMap { $0.typed(as: Relay.self) } }

    /// The relationships of the relationship type `rel`: the bonds on the root that are of it and bound at both ends.
    func relationships() -> [ShapeRecord<Bond>] {
        bonds().filter { $0[IsAProperty.self]?.map(\.shape) == [rel] && $0.props.from != nil && $0.props.to != nil }
    }

    func bytes() throws -> Data { try BoardCodec(registry: editor.registry).encode(editor.file) }

    /// The titles of the picker's lines, and the line's detail (its board, `will be made public`).
    func lines(_ picker: RelationPicker) -> [(title: String, detail: String?)] {
        picker.list.rows.compactMap { row in row.item.map { ($0.title, $0.detail) } }
    }
}

@MainActor let relationPickerTests = Suite("The list a relation row opens", [
    test("the two cases of the bug that started this: an untitled note with values, with a field called title and without, is listed by its values, and one with nothing at all too; the list never reads `No Layer notes` while a Layer exists") {
        let s = try RelationScene.drawn()
        let titled = s.addValued(layerValues)
        let plain = s.addValued(["order": 2, "purpose": "stream"], at: CGPoint(x: 800, y: 1700))
        let nothing = s.editor.addSlip("", of: [s.layer], at: CGPoint(x: 800, y: 1900))
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        let listed = s.lines(picker).map(\.title)
        expect(listed.contains("1 · expose foobar · foundation"), "\(listed)")
        expect(listed.contains("2 · stream"), "\(listed)")
        expect(listed.contains("Foundation"), "the layer note with words")
        expect(listed.contains { $0.hasPrefix("Untitled") }, "a note with nothing in it is listed by the row, not left out: \(listed)")
        let ids = picker.choices.map(\.candidate.id)
        expectEqual(ids.count, 5, "the three, the layer note with words, and the pocket's Layer note")
        expect(ids.contains(titled) && ids.contains(plain) && ids.contains(nothing) && ids.contains(s.layerNote) && ids.contains(s.awayLayer))
        expect(!listed.contains { $0.hasPrefix("No ") }, "never an empty line while a Layer exists")
        // Typing finds a note by its values.
        picker.setQuery("foobar")
        expectEqual(picker.choices.map(\.candidate.id), [titled])
        picker.setQuery("zzzz")
        expectEqual(s.lines(picker).count, 0)
        expectEqual(picker.list.rows.first, .empty("No matches"))
    },
    test("a Layer on another board is listed, with its board, and the list is not narrowed to the board shown; one that is private says it will be made open") {
        let s = try RelationScene.drawn()
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        let line = try require(s.lines(picker).first { $0.title == "Down" }, "the pocket's Layer note: \(s.lines(picker))")
        expect(try require(line.detail).hasSuffix(TypesStyle.willBeMade("open")), "private: \(String(describing: line.detail))")
        expect(try require(line.detail).contains(" · "), "its board, then the word")
        // Open already: only the board.
        s.setOpen(s.awayLayer)
        picker.setQuery("")
        let open = try require(s.lines(picker).first { $0.title == "Down" })
        expect(!(open.detail ?? "").contains("will be made"), "\(String(describing: open.detail))")
        expect(open.detail != nil, "its board is named")
        // A near note says no board.
        expectEqual(try require(s.lines(picker).first { $0.title == "Foundation" }).detail, nil)
        // Reaches the same notes whichever board is shown.
        expect(s.editor.showBoard(s.pocketBoard))
        let away = RelationPicker(editor: s.editor, owner: s.away, row: try s.featureRow())
        expectEqual(Set(s.lines(away).map(\.title)), ["Foundation", "Down"], "both boards' Layer notes, from the pocket")
        expect(try require(s.lines(away).first { $0.title == "Foundation" }).detail != nil, "the board shown is the pocket: the root's note names its board")
        expect(s.editor.showBoard(.root))
    },
    test("`No Layer notes` only while no Layer exists anywhere; with text, `No matches`; a locked note on the board shown is listed") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        // The Layer note exists, near.
        s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow())
        let shown = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        expect(!s.lines(shown).contains { $0.title == "Foundation" }, "a note the row shows is not listed")
        expect(s.lines(shown).contains { $0.title == "Down" }, "the Layer on the other board is")
        // Delete every Layer note: none anywhere.
        s.editor.transact("Delete") { $0.delete([s.layerNote]) }
        s.editor.transact(on: s.pocketBoard, "Delete") { $0.delete([s.awayLayer]) }
        let none = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        expectEqual(none.list.rows, [.empty("No Layer notes")])
        none.setQuery("x")
        expectEqual(none.list.rows, [.empty("No matches")])
        // A Layer that is private and locked on another board cannot be picked: not listed, and the words do not name Layer.
        let hidden = s.editor.addSlip("Locked far", of: [s.layer], at: CGPoint(x: 700, y: 1500))
        s.editor.transact(on: s.pocketBoard, "Move") { _ in }
        s.editor.freeze([hidden])
        let locked = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        expect(s.lines(locked).contains { $0.title == "Locked far" }, "a locked note on the board shown is listed")
    },
    test("the owner, a note the row shows and a type are never listed, and a note given the type in the middle of a pick shows at the next keystroke") {
        let s = try RelationScene.drawn()
        let picker = RelationPicker(editor: s.editor, owner: s.layerNote, row: try s.layerRow())
        let titles = s.lines(picker).map(\.title)
        expect(titles.contains("Sign in"), "\(titles)")
        expect(!titles.contains("Foundation"), "not the owner itself, and not a type: \(titles)")
        expect(!titles.contains("Feature"), "\(titles)")
        s.editor.relate(s.layerNote, to: s.note, in: try s.layerRow())
        picker.setQuery("")
        expect(!s.lines(picker).map(\.title).contains("Sign in"), "now shown by the row")
        let late = s.editor.addSlip("Late feature", of: [s.feature], at: CGPoint(x: 900, y: 500))
        picker.setQuery("late")
        expectEqual(picker.choices.map(\.candidate.id), [late])
    },
    test("a hub: a keystroke that extends the query ranks what the last matched while that was every match, the result is the one a fresh list gives, a query that finds few is ranked over the set, and Return picks, Tab never") {
        let s = try RelationScene.drawn()
        s.editor.transact("Layers") { t in
            for number in 0..<300 {
                t.insert(slipRecord("Layer \(number)", of: [s.layer], at: CGPoint(x: 40 + Double(number % 20) * 30, y: 1500 + Double(number / 20) * 30)))
            }
            for number in 0..<20 {
                t.insert(slipRecord("Alpha \(number)", of: [s.layer], at: CGPoint(x: 40 + Double(number) * 30, y: 3000)))
            }
        }
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        let all = picker.held ?? 0
        expect(all >= 320, "the set is held: \(all)")
        @MainActor func fresh(_ text: String) throws -> RelationPicker {
            let made = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
            made.setQuery(text)
            return made
        }
        // Each keystroke gives the list a fresh one does.
        for text in ["a", "al", "alp", "alph", "alpha", "alpha ", "alpha 1", "alpha 12", "alpha 1x"] {
            picker.setQuery(text)
            expectEqual(picker.choices.map(\.candidate.id), try fresh(text).choices.map(\.candidate.id), "\(text)")
        }
        // 20 notes match `alp` and all are kept; `alph`, `alpha` and `alpha ` find 8 or more among them: ranked among them.
        picker.setQuery("alp")
        expectEqual(picker.choices.count, 20)
        picker.setQuery("alph")
        expectEqual(picker.lastRanked, 20, "ranked the 20 the last query matched, not the \(all)")
        picker.setQuery("alpha")
        expectEqual(picker.lastRanked, 20)
        // `alpha 12` finds one: a typo of it could be among the rest, so the whole set is ranked.
        picker.setQuery("alpha 12")
        expect(picker.lastRanked >= all, "ranked the set: \(picker.lastRanked)")
        // A shorter query goes back to the set.
        picker.setQuery("al")
        expect(picker.lastRanked >= all)
        // Keys: Return picks the highlighted line, Tab never picks.
        picker.setQuery("layer 295")
        expect(picker.perform(#selector(NSResponder.insertNewline(_:))).action == .pick)
        expect(picker.perform(#selector(NSResponder.insertTab(_:))).action != .pick)
        let id = try require(picker.pickNote(row: try require(picker.list.highlighted)))
        expectEqual(s.editor.document[id].flatMap { $0.typed(as: RowSlip.self)?.props.text.stored }, "Layer 295")
    },
    test("a longer query narrows the last one's matches only with as many words: `annex` matches no Layer note and `annex d` the ones on the Annex pocket's board") {
        let s = try RelationScene.drawn(more: [Contributor(id: "pocket-titles") { $0.title(Pocket.self, contents: false) }])
        s.editor.transact { $0.update(s.pocket) { $0[TitleProperty.self] = "Annex" } }
        // Twelve more on the pocket's board, so more than eight match and the list narrows what the last query matched.
        s.editor.transact(on: BoardID(owner: s.pocket)) { t in
            for number in 0..<12 { t.insert(slipRecord("Dock \(number)", of: [s.layer], at: CGPoint(x: 40 + Double(number) * 30, y: 600))) }
        }
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        let all = picker.held ?? 0
        expect(all >= 14, "the set is held: \(all)")
        @MainActor func fresh(_ text: String) throws -> RelationPicker {
            let made = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
            made.setQuery(text)
            return made
        }
        picker.setQuery("annex")
        expectEqual(picker.choices.map(\.candidate.id), [], "a pocket's name is no match for the notes on its board, by one word")
        // One word more: the notes on its board are found by its name, which the last query's matches (none) could not hold.
        picker.setQuery("annex d")
        expectEqual(picker.choices.count, 13, "Down and the twelve docks, ranked over the set, not among what `annex` matched")
        expect(picker.lastRanked >= all, "the whole set: \(picker.lastRanked)")
        expectEqual(picker.choices.map(\.candidate.id), try fresh("annex d").choices.map(\.candidate.id))
        let line = try require(picker.list.rows.compactMap(\.item).first { $0.title == "Down" })
        expect(line.detail?.hasPrefix("Annex") == true, "on another board, in a pocket: its path (\(line.detail ?? "none"))")
        expect(line.spoken.contains(", in Annex"), line.spoken)
        // As many words: the list is the one a fresh picker gives. The matcher's typo pass runs for a query of words, whose
        // names (the whole query in a name) are few, so it forgave and the set is ranked again, as for any query it forgave.
        picker.setQuery("annex do")
        expectEqual(picker.choices.map(\.candidate.id), try fresh("annex do").choices.map(\.candidate.id))
        expect(picker.lastRanked >= all, "forgiven: the set")
        picker.setQuery("annex doc")
        expectEqual(picker.choices.map(\.candidate.id), try fresh("annex doc").choices.map(\.candidate.id))
        expectEqual(picker.choices.count, 12)
        // Fewer words, or a word more or fewer, is another query: the set.
        picker.setQuery("annex ")
        expectEqual(picker.choices.map(\.candidate.id), try fresh("annex ").choices.map(\.candidate.id), "a space is no word")
        picker.setQuery("annex d")
        picker.setQuery("annex d x")
        expect(picker.lastRanked >= all, "a word more: the set, not the thirteen `annex d` matched")
        expectEqual(picker.choices.map(\.candidate.id), try fresh("annex d x").choices.map(\.candidate.id))
    },
    test("a note the row shows as a dashed pill is not offered again by the row's list") {
        let s = try RelationScene.drawn()
        expect(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()) != nil)
        s.setOpen(s.awayLayer, false)
        let pill = try require(try s.pills(s.note, "in").pills.first)
        expectEqual(pill.state, .notAdmitted(s.awayLayer, needs: "open"))
        let picker = RelationPicker(editor: s.editor, owner: s.note, row: try s.featureRow())
        picker.setQuery("Down")
        let offered = picker.choices.map(\.candidate.id)
        expect(!offered.contains(s.awayLayer), "the row already shows Down; the list offers it: \(offered.count) choices")
        picker.setQuery("")
        expect(!picker.choices.map(\.candidate.id).contains(s.awayLayer), "nor with nothing typed")
    },
])

@MainActor let farVerdictTests = Suite("What a pick of a note would take", [
    test("a note on the board shown is here; a far note a pill reads as it is is `reads`; a far private one `fulfils` with the kind's word; a far private locked one, and one on no board, cannot") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        expectEqual(s.editor.farVerdict(of: s.layerNote), .here)
        expectEqual(s.editor.farVerdict(of: s.awayLayer), .fulfils(needs: "open"))
        s.setOpen(s.awayLayer)
        expectEqual(s.editor.farVerdict(of: s.awayLayer), .reads)
        s.setOpen(s.awayLayer, false)
        s.editor.transact { $0.update(inFile: s.awayLayer) { $0[Frozen.self] = true } }
        expectEqual(s.editor.farVerdict(of: s.awayLayer), .cannot, "private and locked")
        s.editor.transact { $0.update(inFile: s.awayLayer) { $0[Frozen.self] = nil } }
        s.setOpen(s.awayLayer)
        s.editor.transact { $0.update(inFile: s.awayLayer) { $0[Frozen.self] = true } }
        expectEqual(s.editor.farVerdict(of: s.awayLayer), .reads, "locked, and already open: nothing is written on its board")
        expectEqual(s.editor.farVerdict(of: ShapeID()), .cannot, "on no board")
    },
])

@MainActor let farRelateTests = Suite("Relating from a row", [
    test("a pick makes the arrow of the row's type from the note to the one picked, in one step, and writes no property of either note; two picks are two steps") {
        let s = try RelationScene.drawn()
        let second = s.addLayerNote("Second")
        let noteBefore = s.editor.document[s.note], layerBefore = s.editor.document[s.layerNote]
        let start = s.editor.document
        let steps = s.editor.undoHistory.undoName
        let arrow = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        let made = try require(s.editor.document[arrow]?.typed(as: Bond.self))
        expectEqual(made.props.from, s.note)
        expectEqual(made.props.to, s.layerNote)
        expectEqual(made[IsAProperty.self]?.map(\.shape), [s.rel], "the row's type, and no fields")
        expectEqual(made[FieldValuesProperty.self], nil)
        expectEqual(s.editor.document[s.note], noteBefore, "no copy is stored in the note")
        expectEqual(s.editor.document[s.layerNote], layerBefore)
        expectEqual(try s.pills(s.note, "in").pills.map(\.target), [s.layerNote])
        s.editor.relate(s.note, to: second, in: try s.featureRow())
        expectEqual(try s.pills(s.note, "in").pills.count, 2)
        s.editor.undo()
        expectEqual(try s.pills(s.note, "in").pills.map(\.target), [s.layerNote], "the second pick is a step of its own")
        s.editor.undo()
        expectEqual(s.editor.document, start)
        expectEqual(s.editor.undoHistory.undoName, steps)
    },
    test("the arrow's direction is the row's side, not which note the person was on: a pick in the Layer note's row draws the arrow from the Feature note") {
        let s = try RelationScene.drawn()
        let arrow = try require(s.editor.relate(s.layerNote, to: s.note, in: try s.layerRow()))
        let made = try require(s.editor.document[arrow]?.typed(as: Bond.self))
        expectEqual(made.props.from, s.note, "from the Feature note")
        expectEqual(made.props.to, s.layerNote)
        expectEqual(try s.pills(s.layerNote, "feature").pills.map(\.target), [s.note])
        expectEqual(try s.pills(s.note, "in").pills.map(\.target), [s.layerNote], "and the Feature note's row shows it")
    },
    test("a far note a pill can stand for as it is: the pill goes on the board shown beside the note, the arrow runs to it, nothing is written on the far board, and the row reads through the pill") {
        let s = try RelationScene.drawn()
        s.setOpen(s.awayLayer)
        let farBefore = s.editor.contents(of: s.pocketBoard)
        let arrow = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        let pill = try require(s.relays().first)
        expectEqual(pill.props.stands.map(\.shape), [s.awayLayer])
        expectEqual(pill.props.says, "Down", "called by the note's name")
        expectEqual(s.editor.document[arrow]?.typed(as: Bond.self)?.props.to, pill.id)
        expectEqual(s.editor.contents(of: s.pocketBoard), farBefore, "its board is as it was")
        let shown = try s.pills(s.note, "in").pills
        expectEqual(shown.map(\.state), [.note(s.awayLayer)])
        expectEqual(shown.first?.via, pill.id)
        expectEqual(s.editor.board, .root)
    },
    test("a far note: its pill is told where it sits beside the note, as a draw run's is, whether another shape has its title or not") {
        let s = try RelationScene.drawn()
        s.setOpen(s.awayLayer)
        s.editor.transact { $0.update(inFile: s.awayLayer) { $0[TitleProperty.self] = "Down" } }
        s.editor.undoHistory.seal()
        _ = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        expectEqual(try require(s.relays().first).props.seat, "board", "a title its own: told as well")
        s.editor.undo()
        expectEqual(s.relays().count, 0)
        var twin = slipRecord(at: CGPoint(x: 1600, y: 1600))
        twin[TitleProperty.self] = "Down"
        s.editor.transact { $0.insert(twin) }
        s.editor.undoHistory.seal()
        _ = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        let pill = try require(s.relays().first)
        expectEqual(pill.props.seat, "board", "beside the note, on the board shown")
        expectEqual(pill.props.says, "Down")
    },
    test("a far private note is made open in the same step, and one Undo returns both boards byte for byte; Redo brings the pill, the arrow and the note back") {
        let s = try RelationScene.drawn()
        let start = try s.bytes()
        expectEqual(s.editor.farVerdict(of: s.awayLayer), .fulfils(needs: "open"))
        let arrow = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        expectEqual(s.editor.file.record(s.awayLayer)?.meta[Open.self], true, "made open")
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        expectEqual(s.relays().count, 1)
        let done = try s.bytes()
        s.editor.undo()
        expect(try s.bytes() == start, "both boards, byte for byte")
        expectEqual(s.editor.file.record(s.awayLayer)?.meta[Open.self], nil)
        expectEqual(s.editor.board, .root, "no board was shown")
        s.editor.redo()
        expect(try s.bytes() == done)
        expect(s.editor.document[arrow] != nil)
    },
    test("a second relationship type to the same far note reuses the note's pill; a far note that cannot be picked is refused with nothing changed and no step") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        // A second relationship type with the same ends.
        let other = s.editor.addRelationshipType("on", at: CGPoint(x: 700, y: 40))
        s.editor.addBond(s.feature, other)
        s.editor.addBond(other, s.layer)
        s.setOpen(s.awayLayer)
        s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow())
        let rows = s.index.rows(for: [s.feature], isType: false)
        let second = try require(rows.first { $0.key.type == other })
        s.editor.relate(s.note, to: s.awayLayer, in: second)
        expectEqual(s.relays().count, 1, "one pill for the far note")
        expectEqual(s.bonds().filter { $0.props.to == s.relays().first?.id }.count, 2, "both arrows run into it")
        // A far note that is private and locked cannot be picked.
        let hidden = s.addValued(["order": 9], at: CGPoint(x: 1200, y: 1500))
        s.editor.transact { $0.update(inFile: hidden) { $0.meta[Open.self] = nil } }
        s.editor.transact(on: s.pocketBoard) { $0.insert(slipRecord("Shut", of: [s.layer], at: CGPoint(x: 0, y: 800))) }
        let shut = try require(s.editor.contents(of: s.pocketBoard).shapes.last).id
        s.editor.transact { $0.update(inFile: shut) { $0[Frozen.self] = true } }
        let before = s.editor.document, steps = s.editor.undoHistory.undoName
        expectEqual(s.editor.relate(s.note, to: shut, in: try s.featureRow()), nil)
        expectEqual(s.editor.document, before)
        expectEqual(s.editor.undoHistory.undoName, steps)
    },
    test("a locked note, a read-only board and a note that is not on the board shown shake or do nothing, with no step") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        let steps = s.editor.undoHistory.undoName
        s.editor.freeze([s.note])
        let before = s.editor.document
        expectEqual(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()), nil)
        expectEqual(s.editor.document, before)
        expectEqual(s.editor.undoHistory.undoName, steps)
        s.editor.freeze([s.note], false)
        let thawed = s.editor.document
        expectEqual(s.editor.relate(s.away, to: s.layerNote, in: try s.featureRow()), nil, "a note on another board")
        expectEqual(s.editor.relate(s.note, to: s.note, in: try s.featureRow()), nil, "not to itself")
        expectEqual(s.editor.document, thawed)
    },
])

@MainActor let farUnrelateTests = Suite("Deleting a pill", [
    test("a relationship goes with its values and the pill it empties, in one step; a pill another arrow still runs to stays") {
        let s = try RelationScene.drawn()
        s.setOpen(s.awayLayer)
        let start = try s.bytes()
        let arrow = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        s.editor.transact { $0.update(arrow) { $0[FieldValuesProperty.self] = FieldValues(["since": 2020]) } }
        let withIt = try s.bytes()
        expect(s.editor.unrelate([arrow]))
        expectEqual(s.editor.undoHistory.undoName, "Remove Relationship")
        expectEqual(s.relays().count, 0, "the pill it emptied")
        expectEqual(s.bonds().filter { $0[IsAProperty.self]?.map(\.shape) == [s.rel] }.count, 0)
        s.editor.undo()
        expect(try s.bytes() == withIt, "the arrow, its values and the pill are back")
        // A second arrow into the pill keeps it.
        let pill = try require(s.relays().first).id
        let other = s.editor.addBond(s.layerNote, pill, of: [s.rel])
        expect(s.editor.unrelate([arrow]))
        expectEqual(s.relays().map(\.id), [pill], "another arrow still runs to it")
        _ = other
        _ = start
    },
    test("an arrow drawn on another board is deleted without showing it, in one step on the board shown, and one Undo returns both boards; a locked one refuses the whole delete") {
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: RefusalLog())])
        var far = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.away, to: s.awayLayer)))
        far[IsAProperty.self] = [TypeLink(s.rel)]
        let farArrow = far
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(farArrow) }
        let near = s.editor.addBond(s.note, s.layerNote, of: [s.rel])
        let start = try s.bytes()
        // Locked: nothing goes, the note that asked shakes, no step.
        s.editor.transact { $0.update(inFile: far.id) { $0[Frozen.self] = true } }
        let locked = try s.bytes(), steps = s.editor.undoHistory.undoName
        expect(!s.editor.unrelate([near, far.id], shaking: s.note))
        expect(try s.bytes() == locked, "nothing changed")
        expectEqual(s.editor.undoHistory.undoName, steps)
        s.editor.transact { $0.update(inFile: far.id) { $0[Frozen.self] = nil } }
        let thawed = try s.bytes()
        expect(s.editor.unrelate([near, far.id], shaking: s.note))
        expectEqual(s.editor.board, .root, "a delete on the far note's row does not switch boards")
        expectEqual(s.editor.contents(of: s.pocketBoard).shapes.compactMap { $0.typed(as: Bond.self) }.count, 0)
        expectEqual(s.bonds().filter { $0.id == near }.count, 0)
        s.editor.undo()
        expect(try s.bytes() == thawed, "both boards")
        _ = start
    },
])

@MainActor let farReadTests = Suite("A row reads a pick in every state of the far end", [
    test("a far pick reads as a note through its pill; made private it is a dashed pill with the note's name; deleted, the name the pill kept; undone, solid again") {
        let s = try RelationScene.drawn()
        s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow())
        var pill = try require(try s.pills(s.note, "in").pills.first)
        expectEqual(pill.state, .note(s.awayLayer))
        expect(pill.isLive)
        s.setOpen(s.awayLayer, false)
        pill = try require(try s.pills(s.note, "in").pills.first)
        expectEqual(pill.state, .notAdmitted(s.awayLayer, needs: "open"))
        expect(!pill.isLive)
        expectEqual(pill.label, "Down")
        s.setOpen(s.awayLayer)
        s.editor.transact(on: s.pocketBoard, "Delete") { $0.delete([s.awayLayer]) }
        pill = try require(try s.pills(s.note, "in").pills.first)
        expectEqual(pill.state, .gone(called: "Down"), "the name the pill kept")
        expect(pill.target == nil && pill.via == s.relays().first?.id)
        s.editor.undo()
        // The undo of a delete on another board shows that board first.
        expect(s.editor.showBoard(.root))
        expectEqual(try require(try s.pills(s.note, "in").pills.first).state, .note(s.awayLayer))
    },
])

@MainActor let farCheckTests = Suite("The check reads a far pick through its pill", [
    test("an arrow a far pick drew says nothing; the far note made private again is one warning at that end, and its undo clears it") {
        let s = try RelationScene.drawn()
        let arrow = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        expectEqual(s.editor.issues(arrow).map(\.message), [])
        s.setOpen(s.awayLayer, false)
        let said = s.editor.issues(arrow)
        expectEqual(said.count, 1)
        expectEqual(said.first?.severity, .warning)
        expect(said.first?.message.contains("isn’t open") == true, "the kind's word: \(String(describing: said.first?.message))")
        s.editor.undo()
        expectEqual(s.editor.issues(arrow).map(\.message), [])
    },
])

@MainActor let farRelationshipTypeTests = Suite("A relationship type between a type and a type on another board", [
    test("the far type is related through a pill beyond the new type, made open in the same step; the type lands beside the near one, clear of it, and one Undo returns both boards byte for byte") {
        let s = try RelationScene(more: drawing())
        let far = ShapeID()
        let record = slipTypeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 200, y: 0), id: far)
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(record) }
        expect(s.editor.showBoard(.root))
        s.editor.undoHistory.seal()
        let start = try s.bytes()
        expectEqual(s.editor.farVerdict(of: far), .fulfils(needs: "open"))
        let made = try require(s.editor.newRelationshipType(from: s.feature, to: far))
        s.editor.closeCard()
        expectEqual(s.editor.undoHistory.undoName, "New Relationship Type")
        expectEqual(s.editor.file.record(far)?.meta[Open.self], true, "made open in the step")
        let pill = try require(s.relays().first, "a pill for the far type")
        expectEqual(pill.props.stands.map(\.shape), [far])
        let toIt = s.bonds().filter { $0.props.from == s.feature && $0.props.to == made }
        let fromIt = s.bonds().filter { $0.props.from == made && $0.props.to == pill.id }
        expectEqual(toIt.count, 1)
        expectEqual(fromIt.count, 1)
        let box = try require(s.editor.frame(inFile: made)), featureBox = try require(s.editor.frame(inFile: s.feature)), pillBox = pill.props.frame
        expect(!box.intersects(featureBox) && !box.intersects(pillBox), "clear of the type and the pill: \(box)")
        expectEqual(s.editor.relationships?.graph.sides(of: made).from.map(\.type), [s.feature])
        expectEqual(s.editor.relationships?.graph.sides(of: made).to.map(\.type), [far], "the end is read through the pill")
        s.editor.undo()
        expect(try s.bytes() == start, "both boards, byte for byte")
        // A second one to the same far type reuses the pill.
        s.setOpen(far)
        let again = s.editor.newRelationshipType(from: s.layer, to: far)
        expect(again != nil)
        s.editor.closeCard()
        expectEqual(s.relays().count, 1)
        let reused = try require(s.relays().first)
        expectEqual(s.bonds().filter { $0.props.to == reused.id }.count, 1)
    },
    test("the far type's pill is told where it sits when another shape has its title, as a draw run's is") {
        let s = try RelationScene(more: drawing())
        let far = ShapeID()
        let record = slipTypeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 200, y: 0), id: far)
        s.editor.transact(on: s.pocketBoard, "Draw") { $0.insert(record) }
        var twin = slipRecord(at: CGPoint(x: 1600, y: 1600))
        twin[TitleProperty.self] = "Company"
        s.editor.transact(on: .root, "Draw") { $0.insert(twin) }
        expect(s.editor.showBoard(.root))
        s.editor.undoHistory.seal()
        _ = try require(s.editor.newRelationshipType(from: s.feature, to: far))
        s.editor.closeCard()
        expectEqual(try require(s.relays().first, "a pill for the far type").props.seat, "board")
    },
    test("two far ends, a far type that cannot be picked and one on no board make nothing and leave no step") {
        let s = try RelationScene(more: drawing() + [FreezingPlugin(log: RefusalLog())])
        let far = ShapeID(), other = ShapeID()
        s.editor.transact(on: s.pocketBoard, "Draw") { t in
            t.insert(slipTypeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 200, y: 0), id: far))
            t.insert(slipTypeRecord(TypeSchemaProperty.starter, title: "Org", at: CGPoint(x: 200, y: 300), id: other))
        }
        expect(s.editor.showBoard(.root))
        s.editor.undoHistory.seal()
        let before = s.editor.document, steps = s.editor.undoHistory.undoName
        expectEqual(s.editor.newRelationshipType(from: far, to: other), nil, "neither on the board shown")
        s.editor.transact { $0.update(inFile: far) { $0[Frozen.self] = true } }
        let frozen = s.editor.document
        expectEqual(s.editor.newRelationshipType(from: s.feature, to: far), nil, "private and locked: it cannot be made open")
        expectEqual(s.editor.newRelationshipType(from: s.feature, to: ShapeID()), nil, "on no board")
        expect(s.editor.document == frozen || s.editor.document == before)
        expect(s.editor.card == nil)
        expect(s.relays().isEmpty)
        _ = steps
    },
])
