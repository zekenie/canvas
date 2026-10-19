import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import TestKit

// The host's part of the card (`editor.card`): `CanvasView` puts the plugin's view under its rect, over the
// editing view, the minimap and the zoom and under the popover, keeps it there as the camera moves, gives
// it the keyboard, and closes it on a press anywhere else in the window. CanvasTests' `CardTests` hold the
// editor's part.

/// What the card's tool and key handler heard.
@MainActor private final class CardLog {
    var pointer: [String] = []
    var keys: [String] = []
    var commands: [String] = []
}

private final class CardTool {
    let log: CardLog
    init(log: CardLog) { self.log = log }
}

extension CardTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) { log.pointer.append("moved") }
    func pointerExited(in editor: CanvasEditor) { log.pointer.append("exited") }
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) { log.pointer.append("modifiers \(modifiers.contains(.shift))") }
}

/// A view in the probe that takes the keyboard: one of the "fields" of a card.
private final class Stop: NSView {
    override var acceptsFirstResponder: Bool { true }
}

/// A canvas 800 × 600 in an unshown window with an editable card at (100, 100, 200, 100), a tool that logs
/// what it hears, a key handler and the delete and select-all commands that log theirs, and a probe card
/// about the card's shape: hung from a rect at (100, 100), 120 × 22 unless told, wanting 200 × 120.
@MainActor private final class Rig {
    let h: EditorHarness
    let canvas: CanvasView
    let window: NSWindow
    let shape: ShapeID
    let log = CardLog()
    let probe = CardProbe(frame: .zero)
    let closings = ClosingLog()

    init() throws {
        let log = log
        h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), Contributor(id: "probe") {
            $0.tool(ToolDescriptor(id: "card-probe", label: "Probe", systemImage: "circle")) { _ in CardTool(log: log) }
            $0.defaultTool("card-probe")
            $0.keyStrokes { _, stroke in log.keys.append(stroke.characters); return true }
            $0.command("scrap", title: "Delete", answering: .delete) { _ in log.commands.append("delete") }
            $0.command("pick-all", title: "Select All", answering: .selectAll) { _ in log.commands.append("selectAll") }
        }])
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        shape = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        window.makeFirstResponder(canvas)
    }

    @discardableResult
    func show(at rect: CGRect = CGRect(x: 100, y: 100, width: 120, height: 22), about: ShapeID? = nil, step: String? = nil) -> Bool {
        h.editor.showCard(probeCard("c", about: about ?? shape, anchor: rect, stepName: step, probe: probe, closings: closings))
    }

    /// What `canvas.hitTest` finds at a point of the canvas (view points).
    func hit(_ point: CGPoint) -> NSView? {
        canvas.superview.flatMap { $0.convert(point, from: canvas) }.flatMap { canvas.hitTest($0) }
    }

    func down(_ point: CGPoint) -> NSEvent { mouse(.leftMouseDown, at: point, in: canvas) }

    /// The box around the probe, in the canvas's subviews.
    var host: NSView? { probe.superview?.superview }
}

@MainActor let cardViewTests = Suite("Card", [
    test("it hangs 4 points under its rect, left edges together; above when there is no room below; 8 points in from the edges") {
        let rig = try Rig()
        expect(rig.show())
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 126, width: 200, height: 120))
        expect(rig.canvas.cardView === rig.probe)
        // No room below: above, 4 points over the rect.
        rig.h.editor.moveCard(to: CGRect(x: 100, y: 500, width: 120, height: 22))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 376, width: 200, height: 120))
        // At the right edge, 8 points in.
        rig.h.editor.moveCard(to: CGRect(x: 700, y: 100, width: 120, height: 22))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 592, y: 126, width: 200, height: 120))
        // Taller than the room: cut to it, 8 points from the bottom edge.
        rig.probe.wants = CGSize(width: 200, height: 520)
        rig.h.editor.moveCard(to: CGRect(x: 100, y: 100, width: 120, height: 22))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 126, width: 200, height: 466))
        // And on the side with more room: above.
        rig.probe.wants = CGSize(width: 200, height: 600)
        rig.h.editor.moveCard(to: CGRect(x: 100, y: 500, width: 120, height: 22))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 8, width: 200, height: 488))
    },
    test("it stays under what the host covers of the canvas's top") {
        let rig = try Rig()
        rig.h.editor.coveredTop = { _ in 100 }
        rig.probe.wants = CGSize(width: 200, height: 600)
        expect(rig.show(at: CGRect(x: 100, y: 500, width: 120, height: 22)))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 108, width: 200, height: 388), "from 8 points under the cover")
        // Its rect half under the cover is in view still; the card hangs below it.
        rig.probe.wants = CGSize(width: 200, height: 120)
        rig.h.editor.moveCard(to: CGRect(x: 100, y: 90, width: 120, height: 22))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 116, width: 200, height: 120))
        // Wholly under it, it is out of view, and the card closes.
        rig.h.editor.moveCard(to: CGRect(x: 100, y: 20, width: 120, height: 22))
        expectEqual(rig.closings.closings, [.leftView])
    },
    test("it follows its rect as the camera pans and zooms, and its size in points doesn't change; the plugin is asked with the room") {
        let rig = try Rig()
        expect(rig.show())
        rig.probe.forgetAsked()
        rig.h.editor.camera.pan(by: CGSize(width: -50, height: -20))
        expectEqual(rig.canvas.cardFrame, CGRect(x: 50, y: 106, width: 200, height: 120), "the rect is at (50, 80) now")
        rig.h.editor.camera = Camera()
        rig.h.editor.camera.setZoom(2, around: .zero)
        expectEqual(rig.canvas.cardFrame, CGRect(x: 200, y: 200 + 44 + 4, width: 200, height: 120), "the rect is 240 × 44 at (200, 200)")
        rig.h.editor.camera.setZoom(0.5, around: .zero)
        expectEqual(rig.canvas.cardFrame, CGRect(x: 50, y: 50 + 11 + 4, width: 200, height: 120))
        expectEqual(rig.probe.asked.last, CGSize(width: 784, height: 592 - (50 + 11 + 4)), "the room below the rect, across the clear view")
        expect(rig.probe.asked.contains(CGSize(width: 784, height: CGFloat.greatestFiniteMagnitude)), "and how tall it would like to be")
    },
    test("it is over the editing view and the minimap and the zoom, and under a popover shown before it or after") {
        let rig = try Rig()
        let editor = rig.h.editor
        rig.canvas.showsMinimap = true
        expect(editor.beginEditing(rig.shape))
        let editing = try require(rig.canvas.descendants(CardField.self).first)
        @MainActor func popover() { editor.hoverPopover(CanvasPopover(id: "p", anchor: CGRect(x: 0, y: 0, width: 10, height: 10), text: NSAttributedString(string: "p"))) }
        popover(); rig.h.wait(600)
        expect(rig.canvas.popoverView != nil)
        expect(rig.show(about: rig.shape))
        @MainActor func order() throws -> (card: Int, popover: Int) {
            let subviews = rig.canvas.subviews
            let minimap = try require(subviews.firstIndex { $0 === rig.canvas.minimap }), zoom = try require(subviews.firstIndex { $0 === rig.canvas.zoomIndicator })
            let editingView = try require(subviews.firstIndex { $0 === editing })
            let card = try require(subviews.firstIndex { $0 === rig.host })
            expect(card > minimap && card > zoom && card > editingView, "over the minimap, the zoom and the editing view")
            return (card, try require(subviews.firstIndex { $0 === rig.canvas.popoverView }))
        }
        var places = try order()
        expect(places.popover > places.card, "a popover shown before it")
        editor.closeCard()
        editor.hoverPopover(nil)
        expect(rig.show(about: rig.shape))
        popover(); rig.h.wait(600)
        places = try order()
        expect(places.popover > places.card, "and after")
        // A minimap that shows after the card shows under it.
        rig.canvas.showsMinimap = false
        rig.canvas.showsMinimap = true
        _ = try order()
    },
    test("clicks: inside the bubble they are the plugin's view's; in the shadow's margin the canvas's; the tool hears the pointer leave once, and move again off it") {
        let rig = try Rig()
        let canvas = rig.canvas
        expect(rig.show())
        expect(rig.hit(CGPoint(x: 150, y: 200)) === rig.probe)
        expect(rig.hit(CGPoint(x: 96, y: 200)) === canvas, "the shadow's margin")
        expect(rig.hit(CGPoint(x: 150, y: 250)) === canvas, "under the bubble, in its shadow")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 600, y: 400), in: canvas))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 200), in: canvas, time: 1.1))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 160, y: 200), in: canvas, time: 1.2))
        expectEqual(rig.log.pointer, ["moved", "exited"])
        expect(NSCursor.current === NSCursor.arrow, "the arrow over it")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 600, y: 400), in: canvas, time: 1.3))
        expectEqual(rig.log.pointer, ["moved", "exited", "moved"])
    },
    test("the keyboard goes to the plugin's view as it shows, and back to the canvas, or to the editing view, as it closes") {
        let rig = try Rig()
        expect(rig.show())
        expect(rig.window.firstResponder === rig.probe)
        rig.h.editor.closeCard()
        expect(rig.window.firstResponder === rig.canvas, "closed with nothing edited")
        // While editing: the editing view's.
        expect(rig.h.editor.beginEditing(rig.shape))
        let field = try require(rig.canvas.descendants(CardField.self).first)
        expect(rig.show())
        expect(rig.window.firstResponder === rig.probe)
        rig.h.editor.closeCard()
        expect((rig.window.firstResponder as? NSTextView)?.delegate === field, "the field's own editor has it: \(String(describing: rig.window.firstResponder))")
        // Replaced by a card that names nothing: the canvas has it, not the old view.
        rig.h.editor.endEditing()
        expect(rig.show())
        let other = CardProbe(frame: .zero)
        expect(rig.h.editor.showCard(CanvasCard(id: "other", anchor: CGRect(x: 100, y: 100, width: 10, height: 10), view: other, size: { _ in CGSize(width: 50, height: 50) })))
        expect(rig.window.firstResponder === rig.canvas)
    },
    test("a key the plugin's view doesn't take stops at the card: no tool letter, no Delete and no Select All reach the canvas") {
        let rig = try Rig()
        expect(rig.show())
        rig.window.press("x")
        expectEqual(rig.probe.keys, ["x"])
        rig.probe.takes = { _ in false }
        rig.window.press("y")
        rig.window.press("\u{7f}", code: 51)
        rig.window.pressReturn()
        expectEqual(rig.probe.keys, ["x"])
        expectEqual(rig.log.keys, [], "the canvas's key handler heard nothing")
        // A key binding's command the view passed on, and a menu's action sent to the first responder.
        rig.probe.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        rig.probe.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        expect(!rig.probe.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil))
        expect(!rig.probe.tryToPerform(#selector(CanvasView.delete(_:)), with: nil))
        expect(rig.window.firstResponder === rig.probe)
        expectEqual(rig.log.keys, [])
        expectEqual(rig.log.commands, [], "neither Delete nor Select All")
        // The canvas's own, with the keyboard back on it.
        rig.h.editor.closeCard()
        rig.canvas.selectAll(nil)
        rig.canvas.delete(nil)
        expectEqual(rig.log.commands, ["selectAll", "delete"])
    },
    test("a modifier change on the plugin's view reaches the editor; a scroll and a pinch over it don't move the board") {
        let rig = try Rig()
        expect(rig.show())
        let flags = try require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 1, windowNumber: rig.window.windowNumber,
                                                 context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        rig.probe.flagsChanged(with: flags)
        expectEqual(rig.log.pointer, ["modifiers true"])
        let camera = rig.h.editor.camera
        let scroll = try require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 30, wheel2: 30, wheel3: 0).flatMap { NSEvent(cgEvent: $0) })
        rig.probe.scrollWheel(with: scroll)
        rig.probe.magnify(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 200), in: rig.canvas))
        expectEqual(rig.h.editor.camera, camera)
        expect(rig.canvas.cardView === rig.probe, "and neither closes it")
    },
    test("a press elsewhere in the window closes it; one inside it, or on the rect it hangs from, doesn't") {
        let rig = try Rig()
        let canvas = rig.canvas
        expect(rig.show(at: CGRect(x: 100, y: 400, width: 120, height: 22)))
        canvas.pressBeganInWindow(rig.down(CGPoint(x: 150, y: 500)))
        expect(rig.h.editor.card != nil, "inside the bubble")
        canvas.pressBeganInWindow(rig.down(CGPoint(x: 150, y: 410)))
        expect(rig.h.editor.card != nil, "on its rect")
        canvas.pressBeganInWindow(rig.down(CGPoint(x: 600, y: 300)))
        expect(rig.h.editor.card == nil)
        expectEqual(rig.closings.closings, [.pressedElsewhere])
        // On the editing view.
        rig.closings.closings = []
        expect(rig.h.editor.beginEditing(rig.shape))
        expect(rig.show(at: CGRect(x: 500, y: 400, width: 120, height: 22)))
        canvas.pressBeganInWindow(rig.down(CGPoint(x: 150, y: 150)))
        expectEqual(rig.closings.closings, [.pressedElsewhere], "on the editing view")
        rig.h.editor.endEditing()
        // Of another window.
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        expect(rig.show(at: CGRect(x: 100, y: 400, width: 120, height: 22)))
        canvas.pressBeganInWindow(mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: try require(other.contentView)))
        expect(rig.h.editor.card != nil, "an event of another window")
    },
    test("a press on a view the host put over the canvas closes it, where that view is over its rect too") {
        let rig = try Rig()
        try cover(rig.canvas)
        expect(rig.show(at: CGRect(x: 300, y: 10, width: 120, height: 22)))
        rig.canvas.pressBeganInWindow(rig.down(CGPoint(x: 150, y: 400)))
        expectEqual(rig.closings.closings, [.pressedElsewhere], "away from it")
        rig.closings.closings = []
        expect(rig.show(at: CGRect(x: 300, y: 10, width: 120, height: 22)))
        rig.canvas.pressBeganInWindow(rig.down(CGPoint(x: 350, y: 20)))
        expectEqual(rig.closings.closings, [.pressedElsewhere], "on the cover over its rect")
    },
    test("a press on the canvas closes it through the editor, and on its rect leaves it, with no monitor in the way") {
        let rig = try Rig()
        let canvas = rig.canvas
        expect(rig.show())
        canvas.mouseDown(with: rig.down(CGPoint(x: 110, y: 110)))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 110, y: 110), in: canvas, time: 1.1))
        expect(rig.h.editor.card != nil)
        canvas.mouseDown(with: rig.down(CGPoint(x: 600, y: 400)))
        expectEqual(rig.closings.closings, [.pressedElsewhere])
        expect(canvas.cardView == nil)
        expect(!canvas.subviews.contains { $0 === rig.host }, "taken down")
    },
    test("the window's press monitor is on while a card shows: a press that reaches the app closes it, one in its bubble or on its rect doesn't, and it is off when none shows") {
        let rig = try Rig()
        expect(rig.show(at: CGRect(x: 100, y: 400, width: 120, height: 22)))
        NSApp.sendEvent(rig.window.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 500), time: 1))
        NSApp.sendEvent(rig.window.mouse(.leftMouseDown, at: CGPoint(x: 150, y: 410), time: 1.1))
        expect(rig.h.editor.card != nil)
        NSApp.sendEvent(rig.window.mouse(.rightMouseDown, at: CGPoint(x: 600, y: 300), time: 1.2))
        expectEqual(rig.closings.closings, [.pressedElsewhere])
        expect(rig.show(at: CGRect(x: 100, y: 400, width: 120, height: 22)))
        rig.h.editor.closeCard()
        NSApp.sendEvent(rig.window.mouse(.leftMouseDown, at: CGPoint(x: 600, y: 300), time: 1.3))
        expectEqual(rig.closings.closings, [.pressedElsewhere, .asked], "nothing showing: nothing heard")
        // A card shown before the canvas is in a window is watched once it is.
        let bare = try Rig()
        let canvas = bare.canvas
        bare.window.contentView = NSView()
        expect(bare.show())
        bare.window.contentView = canvas
        NSApp.sendEvent(bare.window.mouse(.leftMouseDown, at: CGPoint(x: 600, y: 400), time: 2))
        expectEqual(bare.closings.closings, [.pressedElsewhere])
    },
    test("a card that changes size is laid out at the new size; a card taken down leaves the pointer on the canvas") {
        let rig = try Rig()
        expect(rig.show())
        rig.probe.wants = CGSize(width: 260, height: 300)
        rig.h.editor.cardDidResize()
        expectEqual(rig.canvas.cardFrame, CGRect(x: 100, y: 126, width: 260, height: 300))
        rig.canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 200), in: rig.canvas))
        rig.h.editor.closeCard()
        rig.canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 200), in: rig.canvas, time: 1.1))
        expectEqual(rig.log.pointer, ["exited", "moved"])
        // Closed: the frame is whatever the box was; nothing is laid out for it.
        expect(rig.canvas.cardFrame == nil)
    },
])
