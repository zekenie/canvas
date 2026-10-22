import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Mentions
import TestKit
import Types

// What a type's note shows where its rows go (`RowBook.spot`), through every state of the read, and what
// each state asks of the note's layout: no commit, so no step, whatever the model says.

@MainActor
private func rowsHeight(_ count: Int) -> CGFloat { TypesStyle.rowsLead + CGFloat(count) * TypesStyle.rowHeight }

/// A type slip as `/is-a type` leaves one, taken as in step: the starter, no words, untitled.
@MainActor private func placeSlip(_ b: SyncBench) -> ShapeID {
    b.editor.addSlipType(TypeSchemaProperty.starter)
}

/// The person writing a slip's words (a keystroke, or the lot).
@MainActor private func typeSlipWords(_ b: SyncBench, _ id: ShapeID, _ text: String) {
    b.editor.transact { $0.update(id, as: RowSlip.self) { $0.props.text = MentionText(plain: text); RowSlipStyle.fit(&$0.props) } }
}

private let noFieldsSchema = #"{"type": "object"}"#

@MainActor private func spot(_ b: SyncBench, _ id: ShapeID) throws -> RowSpot? { try require(b.editor.rowBook).spot(of: id) }

@MainActor private func extentHeight(_ b: SyncBench, _ id: ShapeID) throws -> CGFloat? {
    try require(b.editor.rowBook).extent(of: try require(b.editor.document[id]))?.height
}

@MainActor let rowSpotTests = Suite("A type's rows' spot", [
    test("a new type is blank: nothing under its words, as wide as stored, and the first words typed are blank too until a read has answered") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        let stored = try require(b.editor.document[id]?.box)
        expectEqual(try spot(b, id), nil)
        expectEqual(try extentHeight(b, id), nil)
        expectEqual(b.editor.laidOut(id), stored)
        typeSlipWords(b, id, "a pet in my household")
        expect(b.sync.isWaiting(id))
        expectEqual(try spot(b, id), nil, "`No fields` would flash under the caret at the first keystroke")
        expectEqual(b.editor.laidOut(id), b.editor.document[id]?.box, "no rows under the words typed")
    },
    test("reading once the call is out: three bars, the note laid out for them with no commit; rows when it lands") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        typeSlipWords(b, id, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        let revision = b.editor.revision, layout = b.editor.layoutRevision
        b.sync.commit(id)
        expectEqual(try spot(b, id), .reading)
        expectEqual(try extentHeight(b, id), rowsHeight(3))
        expectEqual(b.editor.laidOut(id)?.width, 320)
        expectEqual(b.editor.revision, revision, "no commit")
        expect(b.editor.layoutRevision > layout, "the layout moved")
        spinRunLoop(until: { b.model.waiting == 1 })
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(try spot(b, id), .rows)
        expectEqual(try require(b.editor.rowBook).rows(of: id).map(\.name), ["name", "species", "birth year"])
        expectEqual(b.editor.undoHistory.undoName, "Update Schema", "the read is a step of its own")
    },
    test("a note made a type with words is read at once, on the scheduler's next turn: the bars show") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = b.editor.addSlip("a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.editor.makeType(id)
        expectEqual(try spot(b, id), nil, "white, nothing under the words until the read starts")
        b.scheduler.advance(by: .zero)
        expectEqual(try spot(b, id), .reading)
        expectEqual(b.editor.laidOut(id)?.width, 320)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(try spot(b, id), .rows)
    },
    test("`No fields` when the model answers a schema with none; editing the words reads again") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        typeSlipWords(b, id, "a thing")
        b.sync(id, answer: noFieldsSchema)
        expectEqual(try spot(b, id), .noFields)
        expectEqual(try extentHeight(b, id), rowsHeight(1))
    },
    test("the reason and Retry for a server error, and Retry reads again") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        typeSlipWords(b, id, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(try spot(b, id), .failed(LanguageModelError.overloaded.message, action: .retry))
        expectEqual(try extentHeight(b, id), rowsHeight(1))
        b.model.queue(petSchema)
        b.sync.retry(id)
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(try spot(b, id), .rows)
    },
    test("`No API key` and Settings for a missing key, and a key saved reads again") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        typeSlipWords(b, id, "a pet in my household")
        b.model.queue(.noKey)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(try spot(b, id), .failed("No API key", action: .settings))
        b.model.queue(petSchema)
        NotificationCenter.default.post(name: .languageModelKeyDidChange, object: nil)
        spinRunLoop(until: { b.model.requests.count == 2 && b.status(id) == .idle })
        expectEqual(try spot(b, id), .rows)
    },
    test("a key refused reads `API key rejected` with Settings") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        typeSlipWords(b, id, "a pet in my household")
        b.model.queue(.unauthorized)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(try spot(b, id), .failed("API key rejected", action: .settings))
    },
    test("a schema too long for the model to write says so, with nothing to try again") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let long = #"{"type": "object", "description": ""# + String(repeating: "x", count: 40_000) + #""}"#
        let id = b.editor.addSlipType(long, words: "a very long type")
        typeSlipWords(b, id, "a very long type, edited")
        b.sync.commit(id)
        expectEqual(try spot(b, id), .failed(TypeSyncFailure.tooLongMessage, action: nil))
        expectEqual(try extentHeight(b, id), rowsHeight(1))
    },
    test("with no language model at all the spot reads `No language model`, with no button") {
        let plugins = typePlugins().filter { !($0 is LanguageModelsPlugin) } + [RowSlipsPlugin()]
        let harness = try EditorHarness { scheduler in CanvasEditor(registry: try Registry(plugins: plugins), file: CanvasFile(root: CanvasDocument()), scheduler: scheduler) }
        let editor = harness.editor
        let id = editor.addSlip("a pet in my household")
        editor.makeType(id)
        harness.scheduler.advance(by: .zero)
        expectEqual(try require(editor.rowBook).spot(of: id), .failed(TypeSyncFailure.noModelMessage, action: nil))
    },
    test("a type with rows read again stays rows through the wait and the call; a failure says why at their foot, one row more, until a read answers") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = b.editor.addSlipType(pet, words: "a pet in my household", title: "Pet")
        let book = try require(b.editor.rowBook)
        let rows = try extentHeight(b, id)
        expectEqual(rows, rowsHeight(3))
        typeSlipWords(b, id, "a pet in my home")
        expect(b.sync.isWaiting(id))
        expectEqual(try spot(b, id), .rows, "through the wait")
        expectEqual(book.foot(of: id), nil)
        let announced = b.editor.layoutRevision
        b.model.holdsAnswers = true
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(try spot(b, id), .rows, "through the call: no bars")
        expectEqual(book.foot(of: id), nil, "and nothing at the foot: the rows are the last good ones")
        expectEqual(try extentHeight(b, id), rowsHeight(3))
        expectEqual(b.editor.layoutRevision, announced, "the wait ending and the call going out lay nothing out")
        let revision = b.editor.revision, height = try require(b.editor.laidOut(id)).height
        b.model.release()
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(try spot(b, id), .rows, "the rows stay")
        expectEqual(book.foot(of: id), .failed(LanguageModelError.overloaded.message, action: .retry), "and the reason is under them, with Retry")
        expectEqual(try extentHeight(b, id), rowsHeight(4))
        expectEqual(b.editor.laidOut(id)?.height, height + TypesStyle.rowHeight, "laid out a row taller")
        expectEqual(b.editor.revision, revision, "with no commit")
        expectEqual(book.rows(of: id).count, 3, "the rows are the fields' alone")
        let retry = try require(book.actionRect(of: id))
        let last = try require(book.rows(of: id).last)
        expect(retry.minY >= last.rect.maxY, "Retry is past the last row")
        // Typed in while it says so: the transaction lays the note out for what it shows after it.
        typeSlipWords(b, id, "a pet in my home, still")
        let typed = try require(b.editor.document[id]?.box).height
        let shown = try require(extentHeight(b, id))
        expectEqual(b.editor.laidOut(id)?.height, typed + shown)
        b.model.holdsAnswers = false
        b.model.queue(petSchema)
        b.sync.retry(id)
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(book.foot(of: id), nil, "read: the foot goes")
        expectEqual(try extentHeight(b, id), rowsHeight(3))
        expectEqual(b.editor.laidOut(id)?.height, try require(b.editor.document[id]?.box).height + rowsHeight(3))
    },
    test("a type with no rows whose read failed, then given fields by hand: laid out for what it shows at each turn, and the reason gone once a read answers") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let book = try require(b.editor.rowBook)
        let id = placeSlip(b)
        typeSlipWords(b, id, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(try spot(b, id), .failed(LanguageModelError.overloaded.message, action: .retry))
        @MainActor func fits(_ message: String) {
            let box = b.editor.document[id]?.box?.height ?? 0
            let rows = b.editor.document[id].flatMap { book.extent(of: $0)?.height } ?? 0
            expectEqual(b.editor.laidOut(id)?.height, box + rows, message)
        }
        b.typeSchema(id, pet)
        expectEqual(try spot(b, id), .rows)
        fits("the fields written by hand")
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(book.foot(of: id), nil)
        expectEqual(try extentHeight(b, id), rowsHeight(3))
        fits("read")
    },
    test("under a type's rows: `No API key` and Settings… for words read with no key, and nothing for words the model failed to write") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let book = try require(b.editor.rowBook)
        let id = b.editor.addSlipType(pet, words: "a pet in my household", title: "Pet")
        typeSlipWords(b, id, "a pet in my home, and its vet")
        b.model.queue(.noKey)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(try spot(b, id), .rows)
        expectEqual(book.foot(of: id), .failed("No API key", action: .settings))
        expect(book.actionRect(of: id) != nil, "Settings… is there to click")

        // The schema edited and the words not written from it: the rows say what the schema says, so nothing is said under them.
        let other = b.editor.addSlipType(pet, words: "a pet in my household", title: "Pet", at: CGPoint(x: 440, y: 40))
        b.typeSchema(other, pet.replacingOccurrences(of: "\"species\"", with: "\"kind\""))
        b.model.queue(.overloaded)
        b.sync.commit(other)
        spinRunLoop(until: { !b.isUpdating(other) })
        guard case .failed(let failure) = b.status(other) else { return expect(false, "it failed: \(b.status(other))") }
        expectEqual(failure.writing, .words)
        expectEqual(book.foot(of: other), nil)
        expectEqual(book.actionRect(of: other), nil)
    },
    test("a type too long to rewrite, with its rows, says so at their foot when its words change, with nothing to click") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let book = try require(b.editor.rowBook)
        let fields = (0..<60).map { #""field\#($0)": {"type": "string", "description": "\#(String(repeating: "x", count: 600))"}"# }
        let long = #"{"type": "object", "properties": {"# + fields.joined(separator: ", ") + "}}"
        expect(long.utf8.count > 34_000)
        let id = b.editor.addSlipType(long, words: "a very long type")
        let rows = try require(extentHeight(b, id))
        typeSlipWords(b, id, "a very long type, edited")
        b.sync.commit(id)
        expectEqual(try spot(b, id), .rows)
        expectEqual(book.foot(of: id), .failed(TypeSyncFailure.tooLongMessage, action: nil))
        expectEqual(try extentHeight(b, id), rows + TypesStyle.rowHeight)
        expectEqual(book.actionRect(of: id), nil)
    },
    test("an agent-made type with words and an empty schema says `No fields`") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let record = slipTypeRecord(noFieldsSchema, words: "words nobody read")
        b.editor.transact { transaction in
            transaction.byAgent = true
            transaction.insert(record)
        }
        expectEqual(try spot(b, record.id), .noFields)
    },
    test("each change of state lays the note out again with no commit: 3, 1, 1 and nothing rows tall for reading, `No fields`, a reason and blank") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        let stored = try require(b.editor.document[id]?.box).height
        @MainActor func height() -> CGFloat { b.editor.laidOut(id)?.height ?? 0 }
        expectEqual(height(), stored, "blank")
        typeSlipWords(b, id, "a thing")
        let typed = try require(b.editor.document[id]?.box).height
        expectEqual(height(), typed, "the first words, not answered")
        let revision = b.editor.revision
        b.model.holdsAnswers = true
        b.model.queue(noFieldsSchema)
        b.sync.commit(id)
        expectEqual(height(), typed + rowsHeight(3), "reading")
        expectEqual(b.editor.revision, revision, "no commit for it")
        spinRunLoop(until: { b.model.waiting == 1 })
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        b.model.holdsAnswers = false
        expectEqual(height(), typed + rowsHeight(1), "`No fields`")
        b.model.queue(.overloaded)
        b.sync.retry(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(height(), typed + rowsHeight(1), "a reason")
    },
    test("a relationship type has no rows whatever its words and its read say: it is a pill, so no bars and no reason need room, and its words are kept") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        b.editor.transact("Mark") { $0.update(id) { $0[RelationshipProperty.self] = true } }
        @MainActor func extent() -> RowsExtent? { b.editor.shapeContext.layoutInput(TypeRows.extent, for: id) }
        @MainActor func pill() -> TypePill? { b.editor.shapeContext.layoutInput(TypeRows.pill, for: id) }
        expectEqual(extent(), nil)
        expect(pill() != nil, "no words, no fields: a pill")
        typeSlipWords(b, id, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        expectEqual(extent(), nil, "while a read is out: no bars")
        expect(pill() != nil)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        b.model.holdsAnswers = false
        expectEqual(extent(), nil, "with the fields read: no rows")
        expectEqual(pill()?.fields, 3, "but the count")
        expectEqual(b.editor.document[id]?.typed(as: RowSlip.self)?.props.text.stored, "a pet in my household", "its words are kept")
        let failing = placeSlip(b)
        b.editor.transact("Mark") { $0.update(failing) { $0[RelationshipProperty.self] = true } }
        typeSlipWords(b, failing, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(failing)
        spinRunLoop(until: { !b.isUpdating(failing) })
        expectEqual(b.editor.shapeContext.layoutInput(TypeRows.extent, for: failing), nil, "a failed read: no reason drawn")
        expect(b.editor.shapeContext.layoutInput(TypeRows.pill, for: failing) != nil)
    },
    test("a relationship type is never read with no words: a read out when they are cleared is dropped and writes nothing, and a failure is not kept once they are cleared") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        b.editor.transact("Mark") { $0.update(id) { $0[RelationshipProperty.self] = true } }
        typeSlipWords(b, id, "a pet in my household")
        b.model.holdsAnswers = true
        b.sync.commit(id)
        expect(b.isUpdating(id), "with words it is read as any type is")
        typeSlipWords(b, id, "")
        expectEqual(b.status(id), .idle, "the words cleared: the read is dropped")
        b.model.holdsAnswers = false
        b.settle()
        expectEqual(b.editor.shapeContext.layoutInput(TypeRows.pill, for: id)?.fields, 0, "the dropped read writes nothing")
        let failing = placeSlip(b)
        b.editor.transact("Mark") { $0.update(failing) { $0[RelationshipProperty.self] = true } }
        typeSlipWords(b, failing, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(failing)
        spinRunLoop(until: { !b.isUpdating(failing) })
        typeSlipWords(b, failing, "")
        expectEqual(b.status(failing), .idle, "the words cleared after a failed read: no failure is kept for them")
    },
])
