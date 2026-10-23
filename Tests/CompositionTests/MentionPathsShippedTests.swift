import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import LanguageModels
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import TextEditing
import Titles

// The `@` picker as shipped finds a note by its path and says where each is: two notes called Checkout in two frames, and a
// third in a frame inside the first; `@cart checkout` lists the one in Cart first, then the one in the frame inside it, and not
// the one in Orders; `@checkout` lists all three, each row saying its frame.

@MainActor private func titledNote(_ title: String, at origin: CGPoint, in container: ShapeID?) -> AnyShapeRecord {
    var note = AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(origin: origin, size: CGSize(width: 160, height: 100)), text: MentionText(plain: title))))
    note[TitleProperty.self] = title
    return note.copy(as: note.id, container: container)
}

@MainActor private func frame(_ title: String, _ rect: CGRect, in container: ShapeID? = nil, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Frame(frame: rect)))
    record[TitleProperty.self] = title
    return record.copy(as: id, container: container)
}

@MainActor let mentionPathsShippedTests = Suite("Mentions by path, as shipped", [
    test("@cart checkout lists the Checkout in Cart first, then the one in the frame inside it, and not the one in Orders; @checkout lists the three, each row saying its frame") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        defer { withExtendedLifetime(canvas) {} }
        editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        let cart = ShapeID(), express = ShapeID(), orders = ShapeID()
        let inCart = titledNote("Checkout", at: CGPoint(x: 40, y: 40), in: cart), inExpress = titledNote("Checkout", at: CGPoint(x: 60, y: 260), in: express)
        let inOrders = titledNote("Checkout", at: CGPoint(x: 460, y: 40), in: orders)
        // An empty note for each thing typed: a second `@` in a word opens nothing.
        let typed = (0..<3).map { AnyShapeRecord(ShapeRecord(StickyNote(frame: CGRect(x: 440 + 120 * CGFloat($0), y: 300, width: 100, height: 100), text: ""))) }
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [
            frame("Cart", CGRect(x: 20, y: 20, width: 380, height: 480), id: cart), frame("Express", CGRect(x: 40, y: 200, width: 340, height: 280), in: cart, id: express),
            frame("Orders", CGRect(x: 440, y: 20, width: 300, height: 200), id: orders), inCart, inExpress, inOrders,
        ] + typed)))
        /// What the picker lists for `query` typed in an empty note: each row's shape, its detail and what a screen reader says.
        @MainActor func lines(_ query: String, in note: ShapeID) throws -> (view: MentionTextView<AnyMentionable>, rows: [(id: ShapeID, detail: String?, spoken: String)]) {
            editor.selection = note
            expect(editor.beginEditing(note))
            let view = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
            window.type("@" + query)
            let picker = try require(view.picker, "the picker is open after typing: \(view.string.debugDescription)")
            let rows = picker.list.rows.compactMap(\.item)
            return (view, zip(picker.rows.compactMap(\.candidate), rows).map { ($0.id, $1.detail, $1.spoken) })
        }
        let byPath = try lines("cart checkout", in: typed[0].id)
        defer { editor.endEditing() }
        expectEqual(byPath.rows.map(\.id), [inCart.id, inExpress.id], "Cart's own first, the one a frame further in after it; Orders' is no match")
        expectEqual(byPath.rows.map(\.detail), ["Cart", "Cart › Express"])
        expectEqual(byPath.rows.map(\.spoken), ["Checkout, Note, in Cart, 1 of 2", "Checkout, Note, in Cart › Express, 2 of 2"])
        // Picking the first mentions the Checkout in Cart, whichever others are called alike.
        window.pressReturn()
        expect(byPath.view.picker == nil, "a pick closes it")
        expectEqual(byPath.view.mentionText.mentioned, [inCart.id], "the pill is for the Checkout in Cart")
        editor.endEditing()
        let all = try lines("checkout", in: typed[1].id)
        expectEqual(Set(all.rows.map(\.id)), [inCart.id, inExpress.id, inOrders.id])
        expectEqual(Dictionary(uniqueKeysWithValues: all.rows.map { ($0.id, $0.detail) }),
                    [inCart.id: "Cart", inExpress.id: "Cart › Express", inOrders.id: "Orders"], "each told apart by its frame")
    },
])
