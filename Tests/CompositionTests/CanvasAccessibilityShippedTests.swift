import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Frames
import Geometry
import Locking
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Validation

// What VoiceOver hears on the canvas as the app ships it: the board's shapes as layout items said by
// their titles and kinds (Titles' name first), then what else plugins say (a note's words, Locking's
// "locked", Validation's issues, what a frame or a subboard holds), in Tab's reading order (Selection's),
// the selection its focus as Tab moves it and a part of it as ⌥Tab does, a press that selects as Tab
// does, each part's element pressing the part, Show Menu popping the selection's menu, a refusal
// announced, and the board named for its owner.

/// Gives a note titled Checkout an error, for its description.
private struct CheckoutErrorPlugin: CanvasPlugin {
    var id: PluginID { "checkout-error" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.validate(StickyNote.self) { note, _ in note[TitleProperty.self] == "Checkout" ? [.error("Not paid")] : [] }
    }
}

extension NestedWindow {
    /// The canvas's shape elements, as VoiceOver gets them.
    var shapeElements: [NSAccessibilityElement] {
        (canvas.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }.filter { $0.accessibilityRole() == .layoutItem }
    }

    /// The shape element VoiceOver reads with this label.
    func shapeElement(_ label: String) throws -> NSAccessibilityElement {
        try require(shapeElements.first { $0.accessibilityLabel() == label }, "no element “\(label)” in \(shapeElements.compactMap { $0.accessibilityLabel() })")
    }
}

extension NestedWindow {
    /// The inner board (T's), its two notes titled Checkout and Payment and a third, Receipt, below the
    /// first: three stops in reading order.
    func checkoutBoard() throws -> (checkout: ShapeID, payment: ShapeID, receipt: ShapeID) {
        expect(editor.showBoard(nest.tBoard))
        let (checkout, payment) = nest.notes(on: 3)
        var receipt = ShapeRecord(StickyNote(frame: CGRect(x: 80, y: 420, width: 200, height: 200), text: MentionText(plain: "Done")))
        receipt[TitleProperty.self] = "Receipt"
        editor.transact("Name Notes") { t in
            t.insert(receipt)
            t.update(checkout) { $0[TitleProperty.self] = "Checkout" }
            t.update(payment) { $0[TitleProperty.self] = "Payment" }
        }
        return (checkout, payment, receipt.id)
    }
}

@MainActor let canvasAccessibilityShippedTests = Suite("Canvas accessibility, shipped", [
    test("Tab walks three notes, and at each VoiceOver's focus is the note, said by its title and kind") {
        let w = try NestedWindow()
        defer { w.board.close() }
        _ = try w.checkoutBoard()
        let walk = w.walk()
        expectEqual(walk.press(.tab).id, "canvas/Checkout")
        let cycle = walk.expectCycle(["canvas/Checkout", "canvas/Payment", "canvas/Receipt"])
        walk.expectShows(cycle.stops)
        expectEqual(cycle.stops.map(\.label), ["Checkout, Note", "Payment, Note", "Receipt, Note"])
        expectEqual(cycle.stops.map(\.role), Array(repeating: NSAccessibility.Role.layoutItem.rawValue, count: 3))
        // VoiceOver's own way to the focus: the window's, through the canvas that has the keyboard (the
        // last stop shown).
        expectEqual(AccessibilityProbe.focused(in: w.window).map(AccessibilityProbe.label(of:)), "Receipt, Note")
    },
    test("the canvas is named for the board, its children the board's shapes; VoiceOver's press on one selects it, and several selected are counted") {
        let w = try NestedWindow()
        defer { w.board.close() }
        expect(w.editor.showBoard(w.nest.sBoard))
        expectEqual(w.canvas.accessibilityLabel(), "Plans", "the subboard that owns it")
        let (checkout, payment, _) = try w.checkoutBoard()
        expectEqual(w.canvas.accessibilityRole(), .layoutArea)
        let shapes = (w.canvas.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        let labels = shapes.compactMap { $0.accessibilityLabel() }
        expect(["Checkout, Note", "Payment, Note", "Receipt, Note"].allSatisfy(labels.contains), "\(labels)")
        let payments = try require(shapes.first { $0.accessibilityLabel() == "Payment, Note" })
        expect(payments.accessibilityPerformPress())
        expectEqual(w.editor.selectedShapeIDs, [payment])
        w.window.settle()
        expect(w.canvas.accessibilityPosts.contains(.focusedUIElementChanged))
        w.editor.selectedShapeIDs = [checkout, payment]
        w.window.settle()
        expectEqual(w.editor.announcements.last, "2 selected")
    },
    test("the canvas's children follow Tab's reading order, not paint order: a note put down last, above the rest, comes first") {
        let w = try NestedWindow()
        defer { w.board.close() }
        _ = try w.checkoutBoard()
        var header = ShapeRecord(StickyNote(frame: CGRect(x: 80, y: -300, width: 200, height: 200)))
        header[TitleProperty.self] = "Header"
        w.editor.transact("Add Header") { $0.insert(header) }
        let labels = w.shapeElements.compactMap { $0.accessibilityLabel() }
        expectEqual(Array(labels.prefix(4)), ["Header, Note", "Checkout, Note", "Payment, Note", "Receipt, Note"], "\(labels)")
        let walk = w.walk()
        expectEqual(walk.press(.tab).id, "canvas/Header")
        expectEqual(walk.expectCycle(["canvas/Header", "canvas/Checkout", "canvas/Payment", "canvas/Receipt"]).stops.map(\.label),
                    Array(labels.prefix(4)), "Tab's order is VoiceOver's")
        expectEqual(labels.count, 5, "the arrow, no Tab stop, is still a child while it's in view: \(labels)")
    },
    test("⌥Tab moves VoiceOver's focus to the part, said by its title and role, and Escape back to the shape") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (checkout, payment, receipt) = try w.checkoutBoard()
        w.editor.lock([checkout])
        let walk = w.partsWalk(names: [checkout: "Checkout", payment: "Payment", receipt: "Receipt"])
        walk.pending = []
        w.editor.selection = checkout
        w.window.settle()
        let part = walk.press(.optionTab)
        expectEqual(part.id, "canvas/Checkout/Locked")
        expectEqual(part.role, NSAccessibility.Role.button.rawValue)
        expectEqual(part.label, "Locked")
        expectEqual(AccessibilityProbe.focused(in: w.window).map(AccessibilityProbe.label(of:)), "Locked", "the window's way to the focus")
        // The note's parts are its lock chip and the arrow it is joined to Payment by (Connections').
        let cycle = walk.expectCycle(["canvas/Checkout/Locked", "canvas/Checkout/Arrow to Payment"], forward: .optionTab, back: .optionBackTab)
        walk.expectShows(cycle.stops, by: .optionTab)
        let posts = w.canvas.accessibilityPosts.count
        let back = walk.press(.escape)
        expectEqual(back.id, "canvas/Checkout")
        expectEqual(back.label, "Checkout, Note, locked")
        w.window.settle()
        expect(w.canvas.accessibilityPosts.dropFirst(posts).contains(.focusedUIElementChanged), "VoiceOver hears the focus went back")
    },
    test("a shape's parts are its element's children (its chips and its arrows), each pressing its part: the lock chip's unlocks the note, selected") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (checkout, _, _) = try w.checkoutBoard()
        w.editor.lock([checkout])
        let element = try w.shapeElement("Checkout, Note, locked")
        let parts = (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        expectEqual(parts.compactMap { $0.accessibilityLabel() }, ["Locked", "Arrow to Payment"], "the chip and the arrow it is joined by")
        expectEqual(parts.last?.accessibilityRole(), .link, "an arrow at the shape is a link")
        let chip = try require(parts.first)
        expectEqual(chip.accessibilityRole(), .button)
        expect(chip.accessibilityParent() as AnyObject === element, "the chip is the note's")
        expect(chip.accessibilityFrame().width > 0)
        expect(chip.accessibilityPerformPress())
        expect(!w.editor.isLocked(checkout))
        expectEqual(w.editor.undoHistory.undoName, "Unlock")
        expectEqual(w.editor.selectedShapeIDs, [checkout], "pressed as ⌥Tab and Return would press it")
    },
    test("VoiceOver's Show Menu on a shape selects it and pops the selection's menu under it") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (checkout, payment, _) = try w.checkoutBoard()
        w.editor.selectedShapeIDs = [checkout]
        let element = try w.shapeElement("Payment, Note")
        expect(element.accessibilityPerformShowMenu())
        expectEqual(w.editor.selectedShapeIDs, [payment])
        let waiting = try require(w.editor.menuToPopUp)
        expect(waiting.menu.items.contains { $0.title == "Lock" }, "\(waiting.menu.items.map(\.title))")
        expectEqual(waiting.rect, w.editor.shapeContext.bounds(of: [payment]))
    },
    test("a note reads its title, kind, states and issues, its words with mentions by name its value; a frame and a subboard read what they hold") {
        let w = try NestedWindow(extra: [CheckoutErrorPlugin()])
        defer { w.board.close() }
        let (checkout, payment, receipt) = try w.checkoutBoard()
        w.editor.transact("Words") { t in
            t.update(checkout, as: StickyNote.self) { $0.props.text = MentionText([.text("Pay with "), .mention(payment, label: "Old name"), .text(".")]) }
        }
        w.editor.lock([checkout])
        let note = try require(w.editor.accessibleDescription(of: checkout))
        expectEqual(note.label, "Checkout, Note, 1 error, locked", "Validation comes before Locking in the list")
        expectEqual(note.value, "Pay with Payment.", "the mention by its shape's name now")
        let element = try w.shapeElement("Checkout, Note, 1 error, locked")
        expectEqual(element.accessibilityValue() as? String, "Pay with Payment.")
        let frame = w.frame(holding: [payment, receipt])
        expectEqual(w.editor.accessibleDescription(of: frame)?.label, "Sprint, Frame")
        expectEqual(w.editor.accessibleDescription(of: frame)?.value, "2 shapes")
        expect(w.editor.showBoard(.root))
        expectEqual(w.editor.accessibleDescription(of: w.nest.s)?.label, "Plans, Subboard")
        expectEqual(w.editor.accessibleDescription(of: w.nest.s)?.value, "4 shapes", "two notes, an arrow and a subboard")
    },
    test("Delete held on a locked note announces Locked once, however many repeats the key sends") {
        let w = try NestedWindow()
        defer { w.board.close() }
        let (checkout, _, _) = try w.checkoutBoard()
        w.editor.lock([checkout])
        w.editor.selection = checkout
        w.window.makeFirstResponder(w.canvas)
        let before = w.editor.announcements.count
        KeyDriver(w.window).hold(.delete, repeats: 12)
        expect(w.editor.document[checkout] != nil)
        expectEqual(Array(w.editor.announcements.dropFirst(before)), ["Locked"])
    },
])
