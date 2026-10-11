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
    test("a new type is blank: nothing under its words, 200 wide as stored, and the first words typed are blank too until a read has answered") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = placeSlip(b)
        expectEqual(try spot(b, id), nil)
        expectEqual(try extentHeight(b, id), nil)
        expectEqual(b.editor.laidOut(id)?.width, 240)
        typeSlipWords(b, id, "a pet in my household")
        expect(b.sync.isWaiting(id))
        expectEqual(try spot(b, id), nil, "`No fields` would flash under the caret and widen the note at the first keystroke")
        expectEqual(b.editor.laidOut(id)?.width, 240)
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
    test("a type with rows read again stays rows through the wait and the call, and through a failure") {
        let b = try SyncBench(more: [RowSlipsPlugin()])
        let id = b.editor.addSlipType(pet, words: "a pet in my household", title: "Pet")
        let rows = try extentHeight(b, id)
        expectEqual(rows, rowsHeight(3))
        typeSlipWords(b, id, "a pet in my home")
        expect(b.sync.isWaiting(id))
        expectEqual(try spot(b, id), .rows, "through the wait")
        b.model.holdsAnswers = true
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(try spot(b, id), .rows, "through the call: no bars")
        b.model.release()
        spinRunLoop(until: { !b.isUpdating(id) })
        expect(b.status(id) != .idle)
        expectEqual(try spot(b, id), .rows, "and a failure says nothing on the note")
        expectEqual(try extentHeight(b, id), rowsHeight(3))
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
])
