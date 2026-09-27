@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

/// The hand beside the select tool: it leaves the selection alone and shows none of its chrome.
@MainActor let handTests = Suite("Hand", [
    test("Select V leads the toolbar, before the core's Hand H; the editor starts in select, and Escape in the hand returns to it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), CardsPlugin()])
        expectEqual(h.editor.registry.tools.map(\.id), [.select, .hand, ToolID(placing: Card.kind)])
        expectEqual(h.editor.registry.tools.map { h.editor.registry.help(for: $0) }, ["Select (V)", "Hand (H)", "Card"])
        expectEqual(h.editor.registry.tools[0].label, "Select")
        expectEqual(h.editor.currentToolID, .select)
        h.key("h"); h.escape()
        expectEqual(h.editor.currentToolID, .select)
    },
    test("H selects the hand: open hand; closed while pressed and dragging; no hover outlines or handles") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), KnobsPlugin()])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))   // its handle is at (50, 50)
        h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = knob
        let size = CGSize(width: 400, height: 200)
        let inSelect = renderBitmap(h.editor, size: size)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, AnyHashable(0))
        expect(h.key("h"))
        expectEqual(h.editor.hoveredHandle, nil, "the switch drops the hovered handle")
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(h.editor.cursor, .openHand)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredHandle, nil)
        h.move(to: CGPoint(x: 250, y: 50))
        expectEqual(h.editor.hovered, nil)
        let inHand = renderBitmap(h.editor, size: size)
        expect(changedPixels(inSelect, inHand, in: CGRect(x: 40, y: 40, width: 20, height: 20)) > 0, "select draws the handle; the hand doesn't")
        expectEqual(changedPixels(inSelect, inHand, in: CGRect(x: 190, y: 0, width: 120, height: 120)), 0, "no hover outline on the box")
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.cursor, .closedHand)
        h.drag(to: CGPoint(x: 70, y: 60))
        expectEqual(h.editor.cursor, .closedHand)
        h.release(after: 200)
        expectEqual(h.editor.cursor, .openHand)
        expectEqual(h.editor.selection, knob)
    },
    test("a hand click selects, deselects and moves nothing; a press on a shape pans instead") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selection = a
        let revision = h.editor.revision
        h.key("h")
        h.press(at: CGPoint(x: 500, y: 500)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [a])
        // A quick 4 pt jiggle on B: not a drag, so no pan and no slide.
        h.press(at: CGPoint(x: 250, y: 50)); h.drag(to: CGPoint(x: 254, y: 50)); h.release(after: 0)
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.camera.origin, .zero)
        expectEqual(h.scheduler.pendingCount, 0)
        h.press(at: CGPoint(x: 250, y: 50)); h.drag(to: CGPoint(x: 280, y: 70)); h.release(after: 200)
        expectEqual(h.editor.camera.origin, CGPoint(x: -30, y: -20))
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.document.shapes.map(\.id), [a, b])
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
])
