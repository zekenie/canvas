@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// Canvas buttons (`CanvasButtons`): a plugin's bell, a 20-point square it says is at (40, 40), over
// a box's middle, which the select tool clicks before the box.

@MainActor final class Bell {
    var rings: [String] = []
    var isShown = true
    /// What its help says, if anything.
    var words = "Ring"
}

/// A plugin with a button named `name`, in `rect` (view points) while the bell is shown.
@MainActor func bellPlugin(_ bell: Bell, _ name: String = "bell", at rect: CGRect = CGRect(x: 40, y: 40, width: 20, height: 20),
                           help: (@MainActor (String, CanvasEditor) -> String?)? = nil) -> Contributor {
    Contributor(id: PluginID(name)) { r in
        r.canvasButtons(at: { _, point in bell.isShown && rect.contains(point) ? name : nil }, click: { button, _ in bell.rings.append(button) }, help: help)
    }
}

@MainActor let buttonTests = Suite("Canvas buttons", [
    test("a button's help is the help the host shows while the pointer rests on it, and goes when the pointer leaves, a press starts or there's none") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                            bellPlugin(bell, help: { name, _ in bell.words.isEmpty ? nil : "\(bell.words) the \(name)" }),
                                            bellPlugin(Bell(), "mute", at: CGRect(x: 80, y: 40, width: 20, height: 20))])
        h.add(Box(CGRect(x: 0, y: 0, width: 200, height: 100)))
        expectEqual(h.editor.pointerHelp, nil)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButtonHelp, "Ring the bell")
        expectEqual(h.editor.pointerHelp, "Ring the bell")
        h.move(to: CGPoint(x: 90, y: 50))
        expectEqual(h.editor.hoveredButton, AnyHashable("mute"))
        expectEqual(h.editor.pointerHelp, nil, "a button of a plugin that gave none")
        h.move(to: CGPoint(x: 50, y: 50))
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, nil, "while it's pressed")
        h.release()
        expectEqual(h.editor.pointerHelp, "Ring the bell")
        h.move(to: CGPoint(x: 150, y: 80))
        expectEqual(h.editor.pointerHelp, nil, "the pointer left it")
        bell.words = ""
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, nil, "a button that says nothing")
    },
    test("a button that goes while the pointer rests on it takes its help with it, and one whose help changes with a commit shows the new") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell, help: { _, _ in bell.words })])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 200, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, "Ring")
        bell.words = "Ring twice"
        h.editor.transact("Move") { $0.update(box, as: Box.self) { $0.props.frame.origin.x += 1 } }
        expectEqual(h.editor.pointerHelp, "Ring twice", "asked again once the commit has settled")
        bell.isShown = false
        h.editor.canvasButtonsDidChange()
        expectEqual(h.editor.pointerHelp, nil)
    },
    test("another tool has no help, and the hand held gives none") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell, help: { _, _ in "Ring" })])
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, "Ring")
        h.editor.setTool(.hand)
        expectEqual(h.editor.pointerHelp, nil)
        h.editor.setTool(.select)
        h.move(to: CGPoint(x: 51, y: 50))
        expectEqual(h.editor.pointerHelp, "Ring")
        h.editor.isHandHeld = true
        expectEqual(h.editor.pointerHelp, nil, "the hand held")
        h.editor.isHandHeld = false
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, "Ring")
    },
    test("a button whose click commits what its help reads shows the new help once the click is done") {
        let bell = Bell()
        var target: ShapeID?
        let counted = Contributor(id: PluginID("counted")) { r in
            r.canvasButtons(at: { _, point in CGRect(x: 40, y: 40, width: 20, height: 20).contains(point) ? "count" : nil },
                            click: { _, editor in
                                bell.rings.append("count")
                                editor.transact("Count") { if let target { $0.update(target, as: Box.self) { $0.props.frame.origin.x += 1 } } }
                            },
                            help: { _, _ in "x \(bell.rings.count)" })
        }
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), counted])
        target = h.add(Box(CGRect(x: 0, y: 0, width: 200, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, "x 0")
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pointerHelp, "x 1", "the click's own commit")
    },
    test("a press and a release on a button click it, before the shape under it, which isn't selected") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(bell.rings, ["bell"])
        expectEqual(h.editor.selectedShapeIDs, [])
        h.click(at: CGPoint(x: 80, y: 80))
        expectEqual(h.editor.selection, box, "beside the button, the shape")
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(bell.rings, ["bell", "bell"])
        expectEqual(h.editor.selection, box, "the selection stays")
    },
    test("the pointing hand shows over a button, which is hovered; pressed, it's pressed while the pointer's on it") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell)])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, AnyHashable("bell"))
        expectEqual(h.editor.hovered, nil, "not the shape under it")
        expectEqual(h.editor.cursor, .pointingHand)
        h.press(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.pressedButton, AnyHashable("bell"))
        expectEqual(h.editor.cursor, .pointingHand)
        h.drag(to: CGPoint(x: 150, y: 150))
        expectEqual(h.editor.pressedButton, nil)
        h.drag(to: CGPoint(x: 45, y: 45))
        expectEqual(h.editor.pressedButton, AnyHashable("bell"), "back on it, pressed again")
        h.release()
        expectEqual(h.editor.pressedButton, nil)
        expectEqual(bell.rings, ["bell"])
        h.move(to: CGPoint(x: 80, y: 80))
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
    test("a press dragged off a button and released there doesn't click it, nor does one Escape lets go of") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell)])
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 150, y: 150))
        h.release()
        h.press(at: CGPoint(x: 50, y: 50))
        h.escape()
        expectEqual(h.editor.pressedButton, nil)
        h.release()
        expectEqual(bell.rings, [])
    },
    test("a button wins over the only selected shape's handle, and a later plugin's over an earlier's") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), KnobsPlugin(), bellPlugin(bell, "first"),
                                            bellPlugin(bell, "second", at: CGRect(x: 45, y: 45, width: 20, height: 20))])
        let knob = h.add(Knob(CGRect(x: 0, y: 0, width: 100, height: 100)))   // its handle is at (50, 50)
        h.editor.selection = knob
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(bell.rings, ["second"])
        h.click(at: CGPoint(x: 42, y: 42))
        expectEqual(bell.rings, ["second", "first"])
    },
    test("in other tools a button is only drawn: a press there is the tool's") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell)])
        h.editor.setTool(.hand)
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, nil)
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(bell.rings, [])
    },
    test("a button that comes or goes under a still pointer: the select tool looks again when told, and after a commit") {
        let bell = Bell()
        bell.isShown = false
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell)])
        h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.hoveredButton, nil)
        bell.isShown = true
        h.editor.canvasButtonsDidChange()
        expectEqual(h.editor.hoveredButton, AnyHashable("bell"))
        expectEqual(h.editor.cursor, .pointingHand)
        bell.isShown = false
        h.add(Box(CGRect(x: 300, y: 300, width: 10, height: 10)))
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
    test("without a button there, the select tool is as it was, and the report names who has buttons") {
        let bell = Bell()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), bellPlugin(bell)])
        let box = h.add(Box(CGRect(x: 200, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 250, y: 250))
        h.drag(to: CGPoint(x: 280, y: 250))
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 230, y: 200))
        expect(h.editor.registry.report.contains("bell          CanvasButtons"), h.editor.registry.report)
    },
])
