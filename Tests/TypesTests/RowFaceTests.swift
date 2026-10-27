import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import TestKit
import Types

// Clicks on a type's rows (`RowFace`): a row with `›` and a fold ask the field cards to open a read-only card, a
// `Choice` lists its options, Retry reads again and Settings… opens Settings; anywhere else a press is the
// note's. Over slips, which show rows where the memo shows none, in an editor driven as a person would.

/// A type of `count` text fields named from `prefix`.
private func fields(_ prefix: String, _ count: Int) -> String {
    let properties = (1...count).map { #""\#(prefix)\#($0)": {"type": "string"}"# }.joined(separator: ", ")
    return #"{"type": "object", "properties": {\#(properties)}}"#
}

private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@MainActor
private struct Bench {
    let b: SyncBench
    let log: RefusalLog
    var h: EditorHarness { b.harness }
    var editor: CanvasEditor { b.editor }
    var book: RowBook { editor.rowBook! }
    var refusals: [Set<ShapeID>] { log.refusals }

    init() throws {
        let log = RefusalLog()
        self.log = log
        b = try SyncBench(more: [RowSlipsPlugin(), FreezingPlugin(log: log)])
    }

    /// The person writing a slip's words.
    func typeWords(_ id: ShapeID, _ text: String) {
        editor.transact { $0.update(id, as: RowSlip.self) { $0.props.text = MentionText(plain: text); RowSlipStyle.fit(&$0.props) } }
    }

    /// A type of the shared fixtures as a slip, 40 from the left.
    @discardableResult
    func add(_ types: [FieldFixtures.TypeText]) -> [ShapeID] { editor.addFieldSlips(types) }

    func row(_ id: ShapeID, _ name: String) throws -> ShownRow {
        try require(book.rows(of: id).first { $0.name == name }, "a row \(name)")
    }

    /// A note that is each of the types (slips; the types are already on the board), holding these values.
    @discardableResult
    func note(_ types: [ShapeID], _ values: JSONObject = [:], at origin: CGPoint = CGPoint(x: 40, y: 600)) -> ShapeID {
        let id = editor.addSlip("Ann", of: types, at: origin)
        if !values.isEmpty { editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(values) } } }
        return id
    }

    func value(_ id: ShapeID, _ key: String) -> JSONValue? { editor.document[id]?[FieldValuesProperty.self]?.value(at: FieldPath(field: key)) }

    func click(_ point: CGPoint, count: Int = 1) { h.click(at: point, clickCount: count) }
    func middle(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

@MainActor let rowFaceTests = Suite("Clicks on a type's rows", [
    test("a click on a row with `›` selects the note and asks the field cards to open a read-only card under it, the row's rect with it") {
        let t = try Bench()
        let slips = t.add([FieldFixtures.address, FieldFixtures.everyKind.a])
        let id = slips[1]
        let venue = try t.row(id, "venue")
        expectEqual(venue.content, .kind(label: "2 fields", chip: nil, hasMore: true))
        t.click(t.middle(venue.rect))
        let request = try require(t.book.opened.last)
        expectEqual(t.book.opened.count, 1)
        expectEqual(request.shape, id)
        expectEqual(request.target, .field(FieldPath(field: "venue")))
        expectEqual(request.mode, .kinds)
        expect(request.isReadOnly)
        expectEqual(request.rowRect, venue.rect)
        expect(request.folded.isEmpty)
        expectEqual(t.editor.selection, id, "a click selects the note as any press does")
        expectEqual(request.rowRectNow?(), venue.rect, "where the row is now")
        // Anywhere in the row: its name too.
        t.click(CGPoint(x: venue.nameRect.minX + 4, y: venue.rect.midY))
        expectEqual(t.book.opened.count, 2)
        // Another type's fields opens too, and so does a row of a gone type's.
        t.click(t.middle(try t.row(id, "shipping address").rect))
        expectEqual(t.book.opened.last?.target, .field(FieldPath(field: "shippingAddress")))
        t.editor.transact("Delete") { $0.delete([slips[0]]) }
        t.click(t.middle(try t.row(id, "shipping address").rect))
        expectEqual(t.book.opened.count, 4, "a type that is gone still has its row")
    },
    test("the row's place now is asked while its card is open: gone once the row is") {
        let t = try Bench()
        let id = t.add([FieldFixtures.everyKind.a])[0]
        t.click(t.middle(try t.row(id, "venue").rect))
        let now = try require(t.book.opened.last?.rowRectNow)
        expectEqual(now(), try t.row(id, "venue").rect)
        t.editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(fields("a", 3)) } }
        expectEqual(now(), nil, "the field is gone")
    },
    test("a click on a fold opens its card with the rows it hides") {
        let t = try Bench()
        let id = t.add([FieldFixtures.wide(20)])[0]
        let more = try require(t.book.rows(of: id).last)
        expectEqual(more.name, "+12 more")
        t.click(t.middle(more.rect))
        let request = try require(t.book.opened.last)
        expectEqual(request.target, .fold)
        expectEqual(request.folded.map(\.field.name), (9...20).map { "f\($0)" })
        expectEqual(request.rowRect, more.rect)
        expectEqual(request.rowRectNow?(), more.rect)
    },
    test("a type that builds on another folds the other's rows under `from`: its click carries them, and the two folds are told apart") {
        let t = try Bench()
        let parent = ShapeID(), child = ShapeID()
        t.editor.transact { transaction in
            transaction.insert(slipTypeRecord(fields("a", 4), words: "A parent.", title: "Parent", at: CGPoint(x: 40, y: 40), id: parent))
            transaction.insert(slipTypeRecord(fields("b", 12), words: "A child.", title: "Child", at: CGPoint(x: 440, y: 40), id: child))
        }
        t.editor.addTypeLink(parent, to: child)
        let rows = t.book.rows(of: child)
        expectEqual(rows.first?.name, "from Parent")
        expectEqual(rows.last?.name, "+4 more")
        let from = try require(rows.first), more = try require(rows.last)
        t.click(t.middle(from.rect))
        expectEqual(t.book.opened.last?.folded.map(\.field.name), ["a1", "a2", "a3", "a4"])
        t.click(t.middle(more.rect))
        expectEqual(t.book.opened.last?.folded.map(\.field.name), ["b9", "b10", "b11", "b12"])
        let first = try require(t.book.opened.dropLast().last?.rowRectNow), second = try require(t.book.opened.last?.rowRectNow)
        expectEqual(first(), from.rect)
        expectEqual(second(), more.rect, "each asks for its own fold")
    },
    test("a click on `Choice` and on `Choices` queues a menu of the options under the value, each item disabled") {
        let t = try Bench()
        let id = t.add([FieldFixtures.everyKind.a])[0]
        for name in ["status", "roles"] {
            let row = try t.row(id, name)
            t.click(t.middle(row.valueRect))
            let queued = try require(t.editor.menuToPopUp, "a menu for \(name)")
            expectEqual(queued.rect, row.valueRect)
            expectEqual(queued.menu.items.map(\.title), name == "status" ? ["draft", "paid", "shipped"] : ["engineer", "designer", "manager"])
            expect(queued.menu.items.allSatisfy { !$0.isEnabled }, "read-only: none can be chosen")
            t.editor.menuDidPopUp()
        }
        expect(t.book.opened.isEmpty, "neither has a card")
    },
    test("`List of Text`, a link, a plain kind and the lead are the note's: a click selects it and opens nothing") {
        let t = try Bench()
        let kinds = t.add([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        for (id, name) in [(kinds[0], "tags"), (kinds[0], "name"), (kinds[0], "done"), (kinds[1], "customer"), (kinds[1], "guests")] {
            t.editor.selection = nil
            let row = try t.row(id, name)
            t.click(t.middle(row.rect))
            expectEqual(t.editor.selection, id, name)
            expect(t.editor.menuToPopUp == nil, "no menu for \(name)")
        }
        expect(t.book.opened.isEmpty)
        let block = try require(t.book.rowsRect(of: kinds[0]))
        t.editor.selection = nil
        t.click(CGPoint(x: block.midX, y: block.minY + 3))
        expectEqual(t.editor.selection, kinds[0], "the lead under the hairline")
        expect(t.book.opened.isEmpty)
    },
    test("a locked type's rows still open to be read, and its options still list") {
        let t = try Bench()
        let id = t.add([FieldFixtures.everyKind.a])[0]
        t.editor.freeze([id])
        t.click(t.middle(try t.row(id, "venue").rect))
        expectEqual(t.book.opened.count, 1)
        expect(try require(t.book.opened.last).isReadOnly)
        t.click(t.middle(try t.row(id, "status").valueRect))
        expect(t.editor.menuToPopUp != nil)
        expectEqual(t.refusals, [], "reading changes nothing, so nothing is refused")
    },
    test("a double-click on a `›` row or an options row runs the face's click again, and on a plain row it is the note's") {
        let t = try Bench()
        let id = t.add([FieldFixtures.everyKind.a])[0]
        let venue = try t.row(id, "venue")
        t.click(t.middle(venue.rect))
        t.click(t.middle(venue.rect), count: 2)
        expectEqual(t.book.opened.count, 2, "the second press of a fast pair opens it again, and begins no edit")
        t.editor.menuDidPopUp()
        t.click(t.middle(try t.row(id, "status").valueRect), count: 2)
        expect(t.editor.menuToPopUp != nil)
        let before = t.book.opened.count
        t.click(t.middle(try t.row(id, "name").rect), count: 2)
        expectEqual(t.book.opened.count, before)
    },
    test("zoomed out, where the note is a skeleton, a click on a row is the note's") {
        let t = try Bench()
        let id = t.add([FieldFixtures.everyKind.a])[0]
        let venue = try t.row(id, "venue")
        t.editor.camera.setZoom(0.2, around: .zero)
        t.click(t.h.view(t.middle(venue.rect)))
        expectEqual(t.editor.selection, id)
        expect(t.book.opened.isEmpty)
    },
    test("Retry reads again; on a locked type it shakes the note and asks nothing; Settings… opens Settings, locked or not") {
        let t = try Bench()
        let id = t.editor.addSlipType(TypeSchemaProperty.starter)
        t.typeWords(id, "a pet in my household")
        t.b.model.queue(.overloaded)
        t.b.sync.commit(id)
        spinRunLoop(until: { !t.b.isUpdating(id) })
        expectEqual(t.book.spot(of: id), .failed(LanguageModelError.overloaded.message, action: .retry))
        let retry = try require(t.book.actionRect(of: id))
        // A press elsewhere in the reason reads nothing.
        let block = try require(t.book.rowsRect(of: id))
        t.click(CGPoint(x: block.minX + 4, y: retry.midY))
        expectEqual(t.b.model.requests.count, 1)
        // Locked: shaken, and no call.
        t.editor.freeze([id])
        t.click(t.middle(retry))
        expectEqual(t.refusals, [[id]])
        expectEqual(t.b.model.requests.count, 1)
        t.editor.freeze([id], false)
        t.b.model.queue(petSchema)
        t.click(t.middle(retry))
        spinRunLoop(until: { t.b.status(id) == .idle })
        expectEqual(t.b.model.requests.count, 2, "read again")
        expectEqual(t.book.spot(of: id), .rows)
        // No key: Settings….
        let keyless = t.editor.addSlipType(TypeSchemaProperty.starter, at: CGPoint(x: 440, y: 40))
        t.typeWords(keyless, "a pet in my household")
        t.b.model.queue(.notSignedIn)
        t.b.sync.commit(keyless)
        spinRunLoop(until: { !t.b.isUpdating(keyless) })
        expectEqual(t.book.spot(of: keyless), .failed("Not signed in", action: .settings))
        let catcher = SettingsCatcher(), delegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = catcher
        defer { NSApplication.shared.delegate = delegate }
        let settings = try require(t.book.actionRect(of: keyless))
        t.click(t.middle(settings))
        expectEqual(catcher.shown, 1)
        t.editor.freeze([keyless])
        t.click(t.middle(settings))
        expectEqual(catcher.shown, 2, "locked or not")
        expectEqual(t.refusals, [[id]], "Settings… changes nothing")
        t.click(t.middle(settings), count: 2)
        expectEqual(catcher.shown, 2, "a double-click does nothing more")
    },
    test("Retry at the foot of a type's rows reads again; a press on the rows above it is theirs") {
        let t = try Bench()
        let id = t.editor.addSlipType(pet, words: "a pet in my household", title: "Pet")
        t.typeWords(id, "a pet in my home")
        t.b.model.queue(.overloaded)
        t.b.sync.commit(id)
        spinRunLoop(until: { !t.b.isUpdating(id) })
        expectEqual(t.book.spot(of: id), .rows)
        let retry = try require(t.book.actionRect(of: id))
        let last = try require(t.book.rows(of: id).last)
        t.click(CGPoint(x: last.rect.minX + 4, y: last.rect.midY))
        expectEqual(t.b.model.requests.count, 1, "a row is no Retry")
        t.b.model.queue(petSchema)
        t.click(t.middle(retry))
        spinRunLoop(until: { t.b.status(id) == .idle })
        expectEqual(t.b.model.requests.count, 2, "read again")
        expectEqual(t.book.foot(of: id), nil)
        expectEqual(t.book.actionRect(of: id), nil)
    },
    test("a click on a name only selects the note, also when it is the only one selected; a double-click on a name is the note's") {
        let t = try Bench()
        t.add([FieldFixtures.everyKind.a])
        let id = t.note([FieldFixtures.kindsAID], ["name": "Ann"])
        let name = try t.row(id, "name")
        t.click(CGPoint(x: name.nameRect.minX + 4, y: name.rect.midY))
        expectEqual(t.editor.selection, id)
        t.click(CGPoint(x: name.nameRect.minX + 4, y: name.rect.midY))
        expectEqual(t.editor.selection, id, "still selected, nothing started")
        expect(t.editor.editingShapeID == nil && t.editor.menuToPopUp == nil && t.book.opened.isEmpty)
        expectEqual(t.value(id, "name"), "Ann")
        // Also the names of rows with more in them, and of a box and a choice.
        for key in ["venue", "done", "status"] {
            t.click(t.middle(try t.row(id, key).nameRect))
            expect(t.editor.menuToPopUp == nil && t.book.opened.isEmpty, key)
        }
        t.click(t.middle(name.nameRect), count: 2)
        expect(t.editor.menuToPopUp == nil && t.book.opened.isEmpty)
    },
    test("a click on a box writes true, a second false, each a step named for the field; a double-click is two writes and begins no editing") {
        let t = try Bench()
        t.add([FieldFixtures.everyKind.a])
        let id = t.note([FieldFixtures.kindsAID])
        let done = try t.row(id, "done")
        expectEqual(t.value(id, "done"), nil)
        // On an unselected note, at once.
        expectEqual(t.editor.selection, nil)
        t.click(CGPoint(x: done.valueRect.minX + 4, y: done.rect.midY))
        expectEqual(t.value(id, "done"), true)
        expectEqual(t.editor.selection, id)
        expectEqual(t.editor.undoHistory.undoName, "Change Done")
        t.click(CGPoint(x: done.valueRect.minX + 4, y: done.rect.midY))
        expectEqual(t.value(id, "done"), false, "an unticked box that was ticked holds false, which is a value")
        expectEqual(t.editor.undoHistory.undoName, "Change Done")
        t.editor.undo()
        expectEqual(t.value(id, "done"), true, "each click is a step of its own")
        t.click(CGPoint(x: done.valueRect.minX + 4, y: done.rect.midY), count: 2)
        expectEqual(t.value(id, "done"), false, "the second press of a pair toggles it again")
        expect(t.editor.editingShapeID == nil)
        // Off the box itself, in the value column, is the note's.
        t.click(CGPoint(x: done.valueRect.maxX - 4, y: done.rect.midY))
        expectEqual(t.value(id, "done"), false)
    },
    test("a click on a choice queues its menu: the options, a check by the stored one, a separator, None; a pick writes the value and None clears the field") {
        let t = try Bench()
        t.add([FieldFixtures.everyKind.a])
        let id = t.note([FieldFixtures.kindsAID], ["status": "paid"])
        let status = try t.row(id, "status")
        t.click(t.middle(status.valueRect))
        let queued = try require(t.editor.menuToPopUp, "a menu")
        expectEqual(queued.rect, status.valueRect)
        expectEqual(queued.menu.outline, ["draft", "✓ paid", "shipped", "—", "None"])
        expectEqual(t.editor.selection, id)
        try queued.menu.choose("shipped")
        t.editor.menuDidPopUp()
        expectEqual(t.value(id, "status"), "shipped")
        expectEqual(t.editor.undoHistory.undoName, "Change Status")
        t.click(t.middle(status.valueRect))
        let again = try require(t.editor.menuToPopUp)
        expectEqual(again.menu.outline, ["draft", "paid", "✓ shipped", "—", "None"])
        try again.menu.choose("None")
        t.editor.menuDidPopUp()
        expectEqual(t.value(id, "status"), nil, "None clears the field")
        // A stored value that is no option is shown as itself and checks nothing.
        t.editor.transact { $0.update(id) { $0[FieldValuesProperty.self] = FieldValues(["status": "archived"]) } }
        t.click(t.middle(status.valueRect))
        expectEqual(try require(t.editor.menuToPopUp).menu.outline, ["draft", "paid", "shipped", "—", "None"])
        t.editor.menuDidPopUp()
        t.click(t.middle(status.valueRect), count: 2)
        expect(t.editor.menuToPopUp != nil, "a double-click pops it too")
    },
    test("a locked note: a box and a choice shake it and write nothing; a row with more opens a card to be read, with no shake; a typed value is refused") {
        let t = try Bench()
        t.add([FieldFixtures.everyKind.a])
        let id = t.note([FieldFixtures.kindsAID], ["done": true, "status": "paid"])
        t.editor.freeze([id])
        t.click(CGPoint(x: try t.row(id, "done").valueRect.minX + 4, y: try t.row(id, "done").rect.midY))
        expectEqual(t.refusals, [[id]], "the box shakes it")
        expectEqual(t.value(id, "done"), true)
        t.click(t.middle(try t.row(id, "status").valueRect))
        expectEqual(t.refusals, [[id], [id]], "the choice too")
        expect(t.editor.menuToPopUp == nil, "and pops nothing")
        expectEqual(t.value(id, "status"), "paid")
        t.click(t.middle(try t.row(id, "venue").valueRect))
        let request = try require(t.book.opened.last, "the card to be read")
        expect(request.isReadOnly)
        expectEqual(request.mode, .values)
        expectEqual(request.target, .field(FieldPath(field: "venue")))
        expectEqual(t.refusals.count, 2, "reading is no try")
        t.click(t.middle(try t.row(id, "name").valueRect))
        expectEqual(t.editor.editingShapeID, nil)
    },
    test("a row that reads `edited as JSON in the panel` asks for the panel and begins nothing, locked or not") {
        let t = try Bench()
        t.add([FieldFixtures.everyKind.b])
        let id = t.note([FieldFixtures.kindsBID])
        let anything = try t.row(id, "anything")
        expectEqual(anything.content, .summary(FieldWords.editedAsJSON))
        t.click(t.middle(anything.valueRect))
        let request = try require(t.book.opened.last)
        expectEqual(request.target, .field(FieldPath(field: "anything")))
        expectEqual(request.mode, .values)
        expect(t.editor.editingShapeID == nil)
        t.editor.freeze([id])
        t.click(t.middle(anything.valueRect), count: 2)
        expectEqual(t.book.opened.count, 2)
        expect(try require(t.book.opened.last).isReadOnly)
        expectEqual(t.refusals, [])
    },
    test("a row of a gone type has no face on its value, and a click on a slip's typed value is the note's; a typed value of a note being edited has a face of its own") {
        let t = try Bench()
        let types = t.add([FieldFixtures.address, FieldFixtures.everyKind.a, FieldFixtures.everyKind.b])
        let a = t.note([FieldFixtures.kindsAID], ["shippingAddress": ["street": "12 Main St"], "name": "Ann"], at: CGPoint(x: 40, y: 700))
        let b = t.note([FieldFixtures.kindsBID], at: CGPoint(x: 440, y: 700))
        t.editor.transact("Delete") { $0.delete([types[0]]) }
        expectEqual(try t.row(a, "shipping address").content, .gone(types[0]))
        for (id, key) in [(a, "shipping address"), (b, "customer")] {
            t.editor.selection = nil
            t.click(t.middle(try t.row(id, key).valueRect))
            expectEqual(t.editor.selection, id, key)
            expect(t.editor.menuToPopUp == nil && t.book.opened.isEmpty && t.editor.editingShapeID == nil, key)
        }
        // The slip is not edited in place, so the click only selects it; a note that is, begins in the row
        // (noteRowEditingTests).
        t.editor.selection = nil
        t.click(t.middle(try t.row(a, "name").valueRect))
        expectEqual(t.editor.selection, a)
        expect(t.book.opened.isEmpty)
    },
    test("a blank type has no faces") {
        let t = try Bench()
        let blank = t.editor.addSlipType(TypeSchemaProperty.starter)
        t.click(CGPoint(x: 100, y: 60))
        expectEqual(t.editor.selection, blank)
        expect(t.book.opened.isEmpty && t.editor.menuToPopUp == nil)
    },
])
