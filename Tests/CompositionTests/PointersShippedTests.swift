import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CanvasUI
import CoreGraphics
import Find
import LanguageModels
import Mentions
import Queries
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Validation
import Topology
import Types

// Pointers as shipped: an Order note whose `customer` is one mention token naming a Person note, copied,
// pasted, cut, deleted and queried around, with the shipped clipboard (a pasteboard of the test's own).

private let orderFrame = CGRect(x: 100, y: 100, width: 200, height: 200)
private let annFrame = CGRect(x: 500, y: 100, width: 200, height: 200)

/// An empty board as shipped, its clipboard on `pasteboard`, with Person and Order as type notes.
@MainActor private func typedBoard(_ pasteboard: NSPasteboard) -> EditorHarness {
    let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
    h.editor.addTypeNote(FieldFixtures.person.schema, title: "Person", frame: CGRect(x: 0, y: 800, width: 200, height: 200), id: FieldFixtures.personID)
    h.editor.addTypeNote(FieldFixtures.order.schema, title: "Order", frame: CGRect(x: 300, y: 800, width: 200, height: 200), id: FieldFixtures.orderID)
    return h
}

extension CanvasEditor {
    /// A Person note titled `name`, in a transaction of its own.
    fileprivate func addPerson(_ name: String, at frame: CGRect = annFrame, id: ShapeID = ShapeID()) -> ShapeID {
        var note = ShapeRecord(id: id, StickyNote(frame: frame, text: ""))
        note[TitleProperty.self] = name
        note[IsAProperty.self] = [TypeLink(FieldFixtures.personID)]
        transact { $0.insert(note) }
        return id
    }

    /// An Order whose customer is `person`, its value written as the writer writes one (`FieldLink`).
    fileprivate func addOrder(customer person: ShapeID, named name: String, at frame: CGRect = orderFrame) -> ShapeID {
        var note = ShapeRecord(StickyNote(frame: frame, text: ""))
        note[IsAProperty.self] = [TypeLink(FieldFixtures.orderID)]
        note[FieldValuesProperty.self] = FieldValues(["customer": FieldLink(target: person, stored: name).value])
        transact { $0.insert(note) }
        return note.id
    }

    fileprivate func customer(_ id: ShapeID) -> FieldLink? { document[id]?[FieldValuesProperty.self]?["customer"].flatMap(FieldLink.init) }
}

@MainActor let pointersShippedTests = Suite("Pointers, as shipped", [
    test("an Order copied with the Person it points at points at the copy; copied alone, at her; pasted into another file, at nothing, with the name it holds") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        let ann = h.editor.addPerson("Ann Lee")
        let order = h.editor.addOrder(customer: ann, named: "Ann Lee")

        h.editor.selectedShapeIDs = [order, ann]
        h.editor.copySelection()
        var before = h.editor.document
        h.editor.paste()
        let both = h.editor.shapes(since: before)
        let annCopy = try require(both.first { $0[TitleProperty.self] != nil }?.id)
        let orderCopy = try require(both.first { $0[TitleProperty.self] == nil }?.id)
        expectEqual(h.editor.customer(orderCopy), FieldLink(target: annCopy, stored: "Ann Lee"), "the copy's pointer names the copy, its name kept")
        expectEqual(h.editor.customer(order)?.target, ann, "the original's as it was")

        h.editor.selection = order
        h.editor.copySelection()
        before = h.editor.document
        h.editor.paste()
        let alone = try require(h.editor.shapes(since: before).first?.id)
        expectEqual(h.editor.customer(alone)?.target, ann, "still the Person it pointed at")
        expectEqual(h.editor.fieldBook?.resolution(of: try require(h.editor.customer(alone))).isLive, true)

        let other = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        other.editor.paste()
        let pasted = try require(other.editor.document.shapes.first { $0[FieldValuesProperty.self] != nil }?.id)
        let held = try require(other.editor.customer(pasted))
        expectEqual(held.target, ann, "the token is kept")
        expectEqual(other.editor.fieldBook?.resolution(of: held), .missing, "no shape of that file has the id")
        expectEqual(other.editor.fieldBook?.shown(held), "Ann Lee")
    },

    test("an Order and the Person it points at, cut and pasted, are the same notes and the pointer is live; the Person cut alone leaves the pointer dashed until she's pasted") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        let ann = h.editor.addPerson("Ann Lee")
        let order = h.editor.addOrder(customer: ann, named: "Ann Lee")
        let book = try require(h.editor.fieldBook)
        let link = try require(h.editor.customer(order))
        h.editor.selectedShapeIDs = [order, ann]
        h.editor.cutSelection()
        h.editor.paste()
        expectEqual(Set(h.editor.document.shapes.map(\.id)).isSuperset(of: [order, ann]), true, "moved, not copied")
        expectEqual(h.editor.customer(order), link)
        expectEqual(book.resolution(of: link).isLive, true)

        h.editor.selection = ann
        h.editor.cutSelection()
        expectEqual(book.resolution(of: link), .missing)
        expectEqual(book.shown(link), "Ann Lee", "the name it holds")
        expectEqual(h.editor.customer(order), link, "nothing written to the Order")
        h.editor.paste()
        expectEqual(book.resolution(of: link).isLive, true, "she's back, by the same id")
    },

    test("deleting the Person writes nothing to the Order: the pointer shows the name it holds; undo brings her back, and redo takes her again") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        let ann = h.editor.addPerson("Ann Lee")
        let order = h.editor.addOrder(customer: ann, named: "Ann Lee")
        let stored = try require(h.editor.document[order])
        let book = try require(h.editor.fieldBook)
        let link = try require(h.editor.customer(order))
        h.editor.transact("Delete") { $0.delete([ann]) }
        expectEqual(h.editor.document[order], stored)
        expectEqual(book.resolution(of: link), .missing)
        expectEqual(book.shown(link), "Ann Lee")
        h.editor.undo()
        expectEqual(book.resolution(of: link).isLive, true)
        expectEqual(h.editor.document[order], stored)
        h.editor.redo()
        expectEqual(book.resolution(of: link), .missing)
    },

    test("the queries: :edge-to follows field-link, and mention takes it in unless the query says only; :mentions and mentioners(of:) leave it out, and the Connections tab lists it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        let ann = h.editor.addPerson("Ann Lee")
        let order = h.editor.addOrder(customer: ann, named: "Ann Lee")
        let queries = try require(h.editor.queries)
        @MainActor func ids(_ query: String) throws -> [ShapeID] { try storyAnswer(query, on: queries).get().rows.map(\.id) }
        expectEqual(try ids(#":edge-to("Ann Lee", field-link)"#), [order])
        expectEqual(try ids(#":edge-to("Ann Lee", mention)"#), [order], "a child of mention")
        expectEqual(try ids(#":edge-to("Ann Lee", only mention)"#), [])
        expectEqual(try ids(#":edge-from(sticky-note, field-link)"#).contains(ann), true, "the target is the end of one")
        expectEqual(try ids(#":mentions("Ann Lee")"#), [], "mention exactly")
        expectEqual(h.editor.mentions?.mentioners(of: ann), [])
        expectEqual(try require(h.editor.topology).edges(of: order, .outgoing, types: .only(FieldLinkEdge.id)).map(\.slot), ["customer"])
        // The Connections tab lists a pointer as a mention, both ways; it has no text to quote.
        let toAnn = try h.editor.connections(of: ann)
        expectEqual(toAnn.map(\.title), ["Mentioned By"])
        expectEqual(toAnn.first?.rows.map(\.id), [order])
        expectEqual(toAnn.first?.rows.first?.caption, nil)
        let fromOrder = try h.editor.connections(of: order)
        expectEqual(fromOrder.map(\.title), ["Mentions"])
        expectEqual(fromOrder.first?.rows.map(\.id), [ann])
        expectEqual(fromOrder.first?.rows.first?.name, "Ann Lee")
    },
    test("the check: a Person deleted is a warning on the Order, orange and no red, and undone it is none; pasted into another file, the same warning; a Person who is no longer one is an error") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        let ann = h.editor.addPerson("Ann Lee")
        let order = h.editor.addOrder(customer: ann, named: "Ann Lee")
        @MainActor func issues(_ editor: CanvasEditor, _ id: ShapeID) -> [(Severity, String)] {
            _ = editor.validation?.results
            return (editor.validation?.result(for: id)?.issues ?? []).map { ($0.severity, $0.message) }
        }
        // The Order needs line items, which is no issue.
        expectEqual(issues(h.editor, order).count, 0)
        h.editor.transact("Delete") { $0.delete([ann]) }
        let warned = issues(h.editor, order)
        expectEqual(warned.map(\.0), [.warning])
        expectEqual(warned.map(\.1), ["customer links to “Ann Lee”, which is gone"])
        expectEqual(h.editor.fieldChecks?.fullCheck(of: try require(h.editor.document[order])).isWrong, false, "never red")
        h.editor.undo()
        expectEqual(issues(h.editor, order).count, 0)

        h.editor.selection = order
        h.editor.copySelection()
        let other = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        other.editor.addTypeNote(FieldFixtures.person.schema, title: "Person", frame: CGRect(x: 0, y: 800, width: 200, height: 200), id: FieldFixtures.personID)
        other.editor.addTypeNote(FieldFixtures.order.schema, title: "Order", frame: CGRect(x: 300, y: 800, width: 200, height: 200), id: FieldFixtures.orderID)
        other.editor.paste()
        let pasted = try require(other.editor.document.shapes.first { $0[FieldValuesProperty.self] != nil }?.id)
        expectEqual(issues(other.editor, pasted).map(\.0), [.warning], "no shape of that file has the id: dashed, and a warning")

        h.editor.removeTypeLink(FieldFixtures.personID, from: ann)
        let wrong = issues(h.editor, order)
        expectEqual(wrong.map(\.0), [.error])
        expectEqual(wrong.map(\.1), ["customer links to “Ann Lee”, which isn’t a Person"])
    },

    test("⌘F finds a pointer by the name it shows in the Order's row, and after the Person is renamed by the new name") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        h.editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let ann = h.editor.addPerson("Ann Lee")
        let order = h.editor.addOrder(customer: ann, named: "Ann")
        let find = try require(h.editor.find)
        find.open()
        @MainActor func search(_ query: String) throws {
            find.query = query
            while find.isIndexing { h.wait(0) }
            _ = try awaitResult { await find.settled() }
        }
        try search("lee")
        expect(find.results.map(\.id).contains(order), "the Order is found by her live name, not the one its token holds")
        expectEqual(find.texts(of: order), ["Ann Lee"])
        let hit = try require(find.results.first { $0.id == order }?.first)
        let row = try require(h.editor.rowBook?.rows(of: order).first { $0.name == "customer" })
        let mark = try require(find.rects(of: hit, in: order).first)
        expect(row.rect.insetBy(dx: -2.5, dy: -1).contains(mark), "marked on the customer row")
        h.editor.transact("Rename") { $0.update(ann) { $0[TitleProperty.self] = "Anna Lex" } }
        try search("lex")
        expect(find.results.map(\.id).contains(order), "found by the new name")
        expectEqual(find.texts(of: order), ["Anna Lex"])
        try search("lee")
        expect(!find.results.map(\.id).contains(order), "and no longer by the old one")
        find.close()
    },

    test("a pick in a real Order's row on the canvas view: typing finds the Person on any board, Return writes the token, one step, and the Order is checked and copied as pointing at her") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = typedBoard(pasteboard)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        h.editor.viewportDidResize(to: CGSize(width: 900, height: 700))
        let ann = h.editor.addPerson("Ann Lee", at: CGRect(x: 600, y: 100, width: 200, height: 200))
        let anders = h.editor.addPerson("Anders Holm", at: CGRect(x: 600, y: 400, width: 200, height: 200))
        var note = ShapeRecord(StickyNote(frame: orderFrame, text: "Order for Ann."))
        note[IsAProperty.self] = [TypeLink(FieldFixtures.orderID)]
        let order = note.id
        h.editor.transact { $0.insert(note) }
        expect(h.editor.beginEditing(order))
        window.press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        window.type("anders")
        window.pressReturn()
        expectEqual(h.editor.customer(order), FieldLink(target: anders, stored: "Anders Holm"), "the token names the note, with the name it shows")
        expectEqual(h.editor.undoHistory.undoName, "Change Customer")
        expect(h.editor.customer(order)?.target != ann)
        expectEqual(h.editor.fieldBook?.resolution(of: try require(h.editor.customer(order))).isLive, true)
        expect(h.editor.fieldChecks?.check(of: try require(h.editor.document[order])).isWrong == false, "a Person: no error")
        h.editor.endEditing()
        h.editor.undo()
        expectEqual(h.editor.customer(order), nil, "one undo takes the pick")
    },
])
