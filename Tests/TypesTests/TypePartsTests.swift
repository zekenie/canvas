import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Selection
import TestKit
import Titles
import Types

// What Types draws that a click acts on, reached by keys (keyboard navigation's P1 and P3): the rows of a type's note and of a
// read-only note that is one are parts of the shape (⌥Tab, Selection's `ShapeParts`), in the rows' order and titled by their
// names, and a part's press is the click's; Retry is a part and a command; Is a ▸ goes to every type a note is; VoiceOver hears
// what a shape is; the Types tab's minus says which type it removes. Over slips; the keys themselves, on the shipped notes, are
// CompositionTests' (`TypesKeysShippedTests`).

@MainActor
private struct Parts {
    let b: SyncBench
    let log = RefusalLog()
    var editor: CanvasEditor { b.editor }
    var book: RowBook { editor.rowBook! }

    init() throws {
        let log = log
        b = try SyncBench(more: [RowSlipsPlugin(), FreezingPlugin(log: log)])
        b.editor.viewportDidResize(to: CGSize(width: 1_400, height: 900))
    }

    /// The titles of the shape's parts that are its rows' (not a chip's).
    func rowParts(_ id: ShapeID) -> [String] {
        let rows = Set(book.rows(of: id).map(\.name))
        return editor.shapeParts(of: id).map(\.title).filter { rows.contains($0) }
    }

    /// ⌥Tab until the part titled `title` has the keyboard; fails if it never does.
    func focus(_ title: String, file: StaticString = #fileID, line: UInt = #line) {
        for _ in 0..<40 where editor.focusedPart?.title != title { editor.focusAdjacentPart(.next) }
        expectEqual(editor.focusedPart?.title, title, file: file, line: line)
    }
}

@MainActor let typePartsTests = Suite("Types' parts by keys", [
    test("a type's note: its rows with › and its folds, its choices and its relation rows are parts in the rows' order, titled by their names; ⌥Tab walks them round; a press opens the read-only card a click opens") {
        let t = try Parts()
        let id = t.editor.addFieldSlips([FieldFixtures.address, FieldFixtures.everyKind.a])[1]
        let rows = t.book.rows(of: id)
        let parts = t.rowParts(id)
        expect(!parts.isEmpty)
        // The rows' order, and each is a row a click acts on: with ›, or a choice's options.
        expectEqual(parts, rows.map(\.name).filter { parts.contains($0) }, "in the rows' order")
        for name in ["status", "roles", "venue", "shipping address"] { expect(parts.contains(name), "\(name) is a part: \(parts)") }
        for name in ["name", "price", "done"] { expect(!parts.contains(name), "\(name) answers no click: \(parts)") }
        // ⌥Tab from the shape: every part once, round to the first.
        t.editor.selection = id
        let all = t.editor.shapeParts(of: id).map(\.title)
        var walked: [String] = []
        for _ in all { t.editor.focusAdjacentPart(.next); walked.append(t.editor.focusedPart?.title ?? "") }
        expectEqual(walked, all)
        t.editor.focusAdjacentPart(.next)
        expectEqual(t.editor.focusedPart?.title, all.first, "round to the first")
        // The press is the click's: the venue row's card, to be read.
        t.focus("venue")
        expect(t.editor.pressFocusedPart())
        let request = try require(t.book.opened.last)
        expectEqual(request.target, .field(FieldPath(field: "venue")))
        expectEqual(request.mode, .kinds)
        expect(request.isReadOnly)
        expectEqual(t.editor.focusedPart?.title, "venue", "the focus stays on the part, so Escape out of the card lands on it")
        // A choice lists its options.
        t.focus("status")
        t.editor.pressFocusedPart()
        expectEqual(t.editor.menuToPopUp?.menu.items.map(\.title), ["draft", "paid", "shipped"])
    },
    test("a read-only note that is one: a row with more in it is a part whose press opens its card to be read; a note that can be edited lists no row: Return edits it") {
        let t = try Parts()
        let type = t.editor.addFieldSlips([FieldFixtures.address, FieldFixtures.everyKind.a])[1]
        let note = t.editor.addSlip("Ann", of: [type], at: CGPoint(x: 40, y: 600))
        expectEqual(t.rowParts(note), [], "editable: its rows are Tab's, inside its editing")
        t.editor.freeze([note])
        let parts = t.rowParts(note)
        expect(parts.contains("venue") && parts.contains("shipping address"), "\(parts)")
        expect(!parts.contains("name") && !parts.contains("done"), "a row typed in, or a box, would only shake: \(parts)")
        t.editor.selection = note
        t.focus("venue")
        t.editor.pressFocusedPart()
        let request = try require(t.book.opened.last)
        expectEqual(request.shape, note)
        expect(request.isReadOnly, "to be read")
        expectEqual(t.log.refusals, [], "reading is no try: nothing shakes")
    },
    test("Retry on a type whose read failed is a part, the words of its row, and a command in the selection's menu; it reads again; with nothing failed it is neither") {
        let t = try Parts()
        let id = t.editor.addSlipType(TypeSchemaProperty.starter)
        t.editor.selection = id
        expect(!t.editor.canPerform(.retryTypeSync), "nothing failed")
        t.editor.transact { $0.update(id, as: RowSlip.self) { $0.props.text = MentionText(plain: "a pet in my household"); RowSlipStyle.fit(&$0.props) } }
        t.b.model.queue(.overloaded)
        t.b.sync.commit(id)
        spinRunLoop(until: { !t.b.isUpdating(id) })
        let retry = try require(t.editor.shapeParts(of: id).first { $0.title == "Retry" })
        expectEqual(retry.rect, try require(t.book.actionRect(of: id)), "the words a click is on")
        let menu = try require(t.editor.menuForSelection(omitting: []))
        expect(menu.outline.contains("Retry"), "\(menu.outline)")
        expect(t.editor.canPerform(.retryTypeSync))
        t.b.model.queue(petSchema)
        t.focus("Retry")
        t.editor.pressFocusedPart()
        spinRunLoop(until: { t.b.status(id) == .idle })
        expectEqual(t.b.model.requests.count, 2, "read again")
        expect(t.editor.shapeParts(of: id).allSatisfy { $0.title != "Retry" })
        expect(!t.editor.canPerform(.retryTypeSync))
    },
    test("Is a ▸ goes to every type a note is, not only an arrow's relationship type") {
        let t = try Parts()
        let person = t.editor.addSlipType(TypeSchemaProperty.starter, title: "Person")
        let pet = t.editor.addSlipType(TypeSchemaProperty.starter, title: "Pet", at: CGPoint(x: 440, y: 40))
        let ann = t.editor.addSlip("Ann", of: [person, pet], at: CGPoint(x: 40, y: 600))
        t.editor.selection = ann
        let menu = try require(t.editor.menuForSelection(omitting: []))
        let isA = try require(menu.item(withTitle: "Is a")?.submenu)
        expect(isA.outline.contains("Go to “Person”") && isA.outline.contains("Go to “Pet”"), "\(isA.outline)")
        try menu.choose("Is a", "Go to “Pet”")
        expectEqual(t.editor.selectedShapeIDs, [pet])
    },
    test("VoiceOver hears what a shape is after its kind: the types a note is, and of a type that it is one") {
        let t = try Parts()
        let person = t.editor.addSlipType(TypeSchemaProperty.starter, title: "Person")
        let ann = t.editor.addSlip("Ann", of: [person], at: CGPoint(x: 40, y: 600))
        let label = try require(t.editor.accessibleDescription(of: ann)).label
        expect(label.contains("Person"), label)
        expect(try require(t.editor.accessibleDescription(of: person)).label.hasSuffix("Type"), "a type says it is one")
        t.editor.makeRelationshipTypes([person])
        expect(try require(t.editor.accessibleDescription(of: person)).label.contains("Relationship Type"))
    },
    test("each minus of the Types tab is named for the type it removes: Remove Type Person") {
        // SwiftUI's own labels aren't read from an unshown window's hosting view: the row names its minus with this.
        expectEqual(TypesStyle.removeType(named: "Person"), "Remove Type Person")
    },
])
