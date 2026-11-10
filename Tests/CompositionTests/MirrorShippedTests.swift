import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import Locking
import References
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import TextEditing
import Titles
import Types

// Mirrors with the shipped kinds (issue 24): typing into a note through its mirror on another board, the note's own step
// undone without leaving; Return; a frame's notes typed into through the frame's mirror; a subboard's board opened from its
// mirror; a locked original refused, the mirror shaking. On the gallery's boards (`mirrorCheckout`, `mirrorKinds`).

extension GalleryStage {
    /// A double-click at a world point, as the select tool hears one: a press and release, then the second.
    func doubleClick(atWorld world: CGPoint) {
        let point = viewPoint(world)
        press(at: point)
        release(at: point)
        editor.pointerDown(PointerEvent(location: point, timestamp: 4, clickCount: 2))
        editor.pointerUp(PointerEvent(location: point, timestamp: 5, clickCount: 2))
        window.settle()
    }

    /// The words of the note titled `title`, wherever it is.
    func words(of title: String) throws -> String {
        "\(try require(editor.shape(inFile: try shape(title))?.typed(as: StickyNote.self)).props.text)"
    }
}

@MainActor let mirrorShippedTests = Suite("Mirrors, shipped", [
    test("a double-click on a mirror's body types in the note on its board, at full strength; its step undone without leaving the board") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorCheckout(stage)
            try stage.expand(["Pricing rules"])
            try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
            let mirror = try stage.pill(for: "Pricing rules"), note = try stage.shape("Pricing rules")
            let checkout = stage.editor.board
            let frame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.doubleClick(atWorld: CGPoint(x: frame.midX, y: frame.maxY - 30))
            expectEqual(stage.editor.editingShapeID, note, "the note is edited")
            expectEqual(stage.editor.editingStandIn, mirror, "through its mirror")
            stage.window.type(" Gift cards never expire.")
            stage.window.settle()
            stage.editor.endEditing()
            let typed = try stage.words(of: "Pricing rules")
            expect(typed.hasSuffix("Gift cards never expire."), typed)
            expectEqual(stage.editor.board, checkout, "the board shown stays")
            stage.editor.undo()
            expectEqual(stage.editor.board, checkout, "undone from where it was typed, without leaving")
            let undone = try stage.words(of: "Pricing rules")
            expect(!undone.contains("Gift cards"), "the typing undone: \(undone)")
        }
    },
    test("Return on a selected mirror types into its original; a double-click on its pill re-points the pill") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorCheckout(stage)
            try stage.expand(["Pricing rules"])
            try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
            let mirror = try stage.pill(for: "Pricing rules")
            stage.editor.selectedShapeIDs = [mirror]
            expect(stage.editor.canOpenSelection([mirror]))
            stage.editor.openSelection([mirror])
            expectEqual(stage.editor.editingShapeID, try stage.shape("Pricing rules"), "Return opens what it shows")
            stage.editor.endEditing()
            let pill = try require(stage.editor.document[mirror]?.box)
            stage.doubleClick(atWorld: CGPoint(x: pill.midX, y: pill.midY))
            expectEqual(stage.editor.editingShapeID, mirror, "the pill itself is edited, to stand for something else")
            expectEqual(stage.editor.editingStandIn, nil)
        }
    },
    test("Return on a typed note's mirror edits it there: Tab goes to its first row, and a value typed in it is written on its board") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1400, height: 800)) { stage in
            try mirrorKinds(stage)
            try stage.expand(["Order #1042"])
            let mirror = try stage.pill(for: "Order #1042"), note = try stage.shape("Order #1042")
            let checkout = stage.editor.board
            let frame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.look(at: CGPoint(x: frame.minX - 40, y: frame.minY - 40))
            stage.editor.selectedShapeIDs = [mirror]
            stage.editor.openSelection([mirror])
            stage.window.settle()
            expectEqual(stage.editor.editingStandIn, mirror)
            let before = stage.editor.shape(inFile: note)?[FieldValuesProperty.self]
            let driver = KeyDriver(stage.window)
            driver.send(.tab)
            stage.window.settle()
            stage.window.type("9")
            stage.window.settle()
            stage.editor.endEditing()
            let after = stage.editor.shape(inFile: note)?[FieldValuesProperty.self]
            expect(after != before, "a row's value written through the mirror: \(String(describing: after))")
            expectEqual(stage.editor.board, checkout, "and the board shown stays")
        }
    },
    test("a locked original isn't typed into through its mirror: the mirror shakes") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorCheckout(stage)
            try stage.expand(["Pricing rules"])
            try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
            let mirror = try stage.pill(for: "Pricing rules"), note = try stage.shape("Pricing rules")
            let board = try require(stage.editor.file.board(containing: note))
            stage.editor.transact(on: board, "Lock") { $0.update(note) { $0[LockedProperty.self] = true } }
            let frame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.doubleClick(atWorld: CGPoint(x: frame.midX, y: frame.maxY - 30))
            expectEqual(stage.editor.editingShapeID, nil, "refused")
            expect(stage.editor.service(RefusalShake.self)?.isShaking == true, "the mirror shakes")
        }
    },
    test("⇧↩ typing through a mirror puts no note down on the mirror's board: the mirror shakes, and the typing goes on") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try mirrorCheckout(stage)
            try stage.expand(["Pricing rules"])
            try stage.look(at: "Confirm", inset: CGPoint(x: 60, y: 40))
            let mirror = try stage.pill(for: "Pricing rules"), note = try stage.shape("Pricing rules")
            let count = stage.editor.document.shapes.count
            stage.editor.selectedShapeIDs = [mirror]
            stage.editor.openSelection([mirror])
            stage.window.settle()
            expectEqual(stage.editor.editingStandIn, mirror)
            KeyDriver(stage.window).send(Chord(Key.return, .shift))
            stage.window.settle()
            expectEqual(stage.editor.document.shapes.count, count, "nothing put down on Checkout")
            expect(stage.editor.service(RefusalShake.self)?.isShaking == true, "the mirror shakes")
            expectEqual(stage.editor.editingShapeID, note, "still typing in the note")
        }
    },
    test("a relationship type's name typed through its mirror is written on its board") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1000, height: 700)) { stage in
            try stage.run("""
            subboard "Policies" size: 200x100
            subboard "Checkout" right of "Policies" size: 200x100
            """)
            try stage.run(#"sticky-note "Employment" in "Policies" relationship: true schema: "{\"type\": \"object\", \"properties\": {\"since\": {\"type\": \"string\"}}}""#)
            try stage.show(try stage.board(of: "Checkout"))
            try stage.run(#"sticky-note "Anchor" size: 120x60"#)
            try stage.run(#"edge "Anchor" -> "Employment" via: reference"#)
            let mirror = try stage.pill(for: "Employment"), type = try stage.shape("Employment")
            stage.editor.perform(.expandReference, on: [mirror])
            stage.settlePills()
            let checkout = stage.editor.board
            stage.editor.selectedShapeIDs = [mirror]
            stage.editor.openSelection([mirror])
            expectEqual(stage.editor.editingShapeID, type)
            expectEqual(stage.editor.editingStandIn, mirror)
            let pillEditor = try require(stage.editor.makeEditingView()?.view as? TypePillEditor)
            pillEditor.field.insertText(" at", replacementRange: NSRange(location: pillEditor.field.string.utf16.count, length: 0))
            stage.editor.endEditing()
            expectEqual(stage.editor.shape(inFile: type)?[TitleProperty.self], "Employment at")
            expectEqual(stage.editor.board, checkout, "the board shown stays")
        }
    },
    test("a frame's mirror shows its notes; a double-click on one types in that note, on its board") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1400, height: 800)) { stage in
            try mirrorKinds(stage)
            try stage.expand(["Refunds"])
            let mirror = try stage.pill(for: "Refunds"), note = try stage.shape("Refund window")
            let (_, transform) = try require(stage.editor.shown(through: mirror))
            let noteFrame = try require(stage.editor.frame(inFile: note))
            let middle = CGPoint(x: noteFrame.midX, y: noteFrame.midY).applying(transform)
            let mirrorFrame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.look(at: CGPoint(x: mirrorFrame.minX - 40, y: mirrorFrame.minY - 40))
            expectEqual(stage.editor.shownShape(at: middle, in: mirror)?.id, note, "the note is found where the mirror shows it")
            stage.doubleClick(atWorld: middle)
            expectEqual(stage.editor.editingShapeID, note)
            expectEqual(stage.editor.editingStandIn, mirror)
            stage.window.type(", or sixty for members")
            stage.window.settle()
            stage.editor.endEditing()
            let typed = try stage.words(of: "Refund window")
            expect(typed.contains("sixty for members"), typed)
        }
    },
    test("a subboard's mirror shows its card; a double-click on it opens the subboard's board, one step back") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1400, height: 800)) { stage in
            try mirrorKinds(stage)
            try stage.expand(["Stripe"])
            let mirror = try stage.pill(for: "Stripe"), stripe = try stage.shape("Stripe")
            let checkout = stage.editor.board
            let frame = try require(stage.editor.shapeContext.frame(of: mirror))
            stage.look(at: CGPoint(x: frame.minX - 40, y: frame.minY - 40))
            stage.doubleClick(atWorld: CGPoint(x: frame.midX, y: frame.maxY - 20))
            expectEqual(stage.editor.board, BoardID(owner: stripe), "Stripe's board")
            expect(stage.editor.canGoBack)
            stage.editor.goBack()
            expectEqual(stage.editor.board, checkout)
        }
    },
    test("zoomed out a mirror is its pill's block over its original's skeleton; a mirror of every kind draws without a refusal") {
        try GalleryStage.with(dark: false, size: CGSize(width: 1400, height: 800)) { stage in
            try mirrorKinds(stage)
            try stage.expand(["Order", "Order #1042", "Stripe", "Refunds"])
            for title in ["Order", "Order #1042", "Stripe", "Refunds"] {
                let mirror = try stage.pill(for: title)
                expectEqual(stage.editor.references?.state(of: mirror).map { $0.hasOriginal }, true, title)
                expect(stage.editor.shown(through: mirror) != nil, "\(title) shows its original")
            }
            stage.look(at: CGPoint(x: -100, y: 100), zoom: 0.3)
            expect(!isBlank(stage.picture()), "something is drawn zoomed out")
        }
    },
])
