import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// A shape's parts (`ShapeParts`), walked with the keys a keyboard sends: ⌥Tab into them and round, Return
// and Space to press one, the arrows to adjust one, Escape back to the shape. A fixture plugin hands in
// three parts with no key code of its own (principle 2): two chips above a box, and a handle on its bottom
// edge, listed out of reading order.

/// What the fixture's parts were asked to do.
@MainActor final class PartLog {
    var pressed: [String] = []
    var adjusted: [PartStep] = []
}

/// Three parts on every box, listed handle first: the Left chip above its top-left (a press pops a menu),
/// the Right chip above its top-right, shown only on a box at least 150 wide, and a Handle on the middle of
/// its bottom edge, which the left and right arrows adjust (up and down it leaves to the nudge).
@MainActor func threeParts(_ log: PartLog) -> Contributor {
    Contributor(id: "parts") { registrar in
        registrar.forShapes(adopting: .box) { box in
            box.shapeParts { editor, shape in
                guard let f = shape.box else { return [] }
                var parts = [
                    ShapePart(id: "handle", title: "Handle", role: .handle, rect: CGRect(x: f.midX - 6, y: f.maxY - 6, width: 12, height: 12),
                              press: { _ in log.pressed.append("Handle") },
                              adjust: { _, step in
                                  guard step.direction.y == 0 else { return false }
                                  log.adjusted.append(step)
                                  return true
                              }),
                    ShapePart(id: "left", title: "Left", role: .menuButton, rect: CGRect(x: f.minX, y: f.minY - 24, width: 40, height: 18)) { editor in
                        log.pressed.append("Left")
                        editor.popUpMenu(NSMenu(title: "Left"), below: CGRect(x: f.minX, y: f.minY - 24, width: 40, height: 18))
                    },
                ]
                if f.width >= 150 {
                    parts.insert(ShapePart(id: "right", title: "Right", rect: CGRect(x: f.maxX - 40, y: f.minY - 24, width: 40, height: 18)) { _ in
                        log.pressed.append("Right")
                    }, at: 1)
                }
                return parts
            }
        }
    }
}

/// A canvas in an unshown window with two boxes, A (wide enough for all three parts) and B to its right,
/// and the parts fixture; the editor keeps the harness's clock.
@MainActor final class PartsWindow {
    let h: EditorHarness
    let log = PartLog()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: true)
    let canvas: CanvasView
    let a: ShapeID
    let b: ShapeID

    init() throws {
        h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), threeParts(log)])
        canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        a = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 160)))
        b = h.add(Box(CGRect(x: 400, y: 100, width: 100, height: 100)))
    }

    var editor: CanvasEditor { h.editor }

    /// A walk of the canvas: the selection named A and B, a part by its title, and where the keyboard is the
    /// focused part's rect, else the selection's. VoiceOver can't see the canvas's shapes yet.
    func walk() -> KeyWalk {
        let names = [a: "A", b: "B"]
        let walk = KeyWalk(window, editor: editor, readers: [.canvas(canvas, selection: { [editor] in editor.selectedShapeIDs.map { names[$0] ?? "?" } },
                                                                      part: { [editor] in editor.focusedPart?.title },
                                                                      frame: { [editor, canvas] in
                                                                          guard let rect = editor.focusedPart?.rect ?? editor.selectionBounds else { return nil }
                                                                          return editor.shownFrame(ofWorld: rect, in: canvas)
                                                                      })],
                           settle: .manual(h.scheduler))
        return walk
    }
}

@MainActor let partsTests = Suite("Parts of a shape", [
    test("⌥Tab focuses the first part in reading order, ⌥⇧Tab the last; ⌥Tab and ⌥⇧Tab step round the parts, each undoing the other, every part shown") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        expectEqual(walk.press(.optionBackTab).id, "canvas/A/Handle", "from the shape, ⌥⇧Tab: the last")
        expectEqual(walk.press(.escape).id, "canvas/A")
        expectEqual(walk.press(.optionTab).id, "canvas/A/Left", "the chips' row before the handle's, left to right, whatever order they were listed in")
        let cycle = walk.expectCycle(["canvas/A/Left", "canvas/A/Right", "canvas/A/Handle"], forward: .optionTab, back: .optionBackTab)
        walk.expectShows(cycle.stops, by: .optionTab)
        expectEqual(w.editor.selectedShapeIDs, [w.a], "the shape stays selected throughout")
        expectEqual(w.editor.shapeParts(of: w.a).map(\.title), ["Left", "Right", "Handle"])
    },
    test("Return and Space press the focused part, which keeps the focus, a menu it pops too; Space holds no Hand then") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        walk.press(.optionTab)
        expectEqual(walk.press(.return).id, "canvas/A/Left")
        expectEqual(w.log.pressed, ["Left"])
        expect(w.editor.menuToPopUp != nil, "its menu waits for the host")
        walk.driver.release(.return)
        expectEqual(walk.press(.space).id, "canvas/A/Left")
        expectEqual(w.log.pressed, ["Left", "Left"])
        expect(!w.editor.isHandHeld)
        walk.driver.release(.space)
        expectEqual(walk.press(.optionTab).id, "canvas/A/Right")
        walk.press(.enter)
        expectEqual(w.log.pressed, ["Left", "Left", "Right"], "Enter as Return")
        expectEqual(walk.press(.escape).id, "canvas/A")
        walk.press(.space)
        expect(w.editor.isHandHeld, "with no part focused, Space holds the Hand")
        walk.driver.release(.space)
        expect(!w.editor.isHandHeld)
        expectEqual(w.log.pressed.count, 3)
    },
    test("an arrow key adjusts a focused handle, and nudges the shape for a step the handle doesn't take or a part with no way to adjust") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        let frame = try require(w.editor.document[w.a]?.box)
        expectEqual(walk.press(.optionBackTab).id, "canvas/A/Handle")
        walk.press(.right)
        walk.press(Chord(Key.left, .shift))
        expectEqual(w.log.adjusted, [PartStep(direction: CGPoint(x: 1, y: 0)), PartStep(direction: CGPoint(x: -1, y: 0), isLarge: true)])
        expectEqual(w.editor.document[w.a]?.box, frame, "the handle took them")
        expectEqual(walk.press(.up).id, "canvas/A/Handle", "the handle doesn't take ↑: the shape moves, the focus stays")
        expectEqual(w.editor.document[w.a]?.box, frame.offsetBy(dx: 0, dy: -1))
        walk.press(.optionTab)
        expectEqual(walk.press(.right).id, "canvas/A/Left")
        expectEqual(w.editor.document[w.a]?.box, frame.offsetBy(dx: 1, dy: -1), "a chip has no way to adjust: the arrow nudges")
    },
    test("Escape goes back to the shape, still selected, then deselects: one level at a time") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        walk.press(.optionTab)
        walk.press(.optionTab)
        walk.expectEscapeLadder(["canvas/A", "canvas"])
    },
    test("keys a part has no use for change nothing there, Delete included, and Tab and Escape move on") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        walk.press(.optionTab)
        let cycle = walk.expectCycle(["canvas/A/Left", "canvas/A/Right", "canvas/A/Handle"], forward: .optionTab, back: .optionBackTab)
        walk.expectInert(at: cycle.stops, by: .optionTab)
        expect(w.editor.document[w.a] != nil)
        expectEqual(walk.press(.tab).id, "canvas/B", "Tab steps to the next shape, as from the shape")
        walk.press(.backTab)
        walk.press(.delete)
        expect(w.editor.document[w.a] == nil, "the shape itself still deletes")
    },
    test("the focused part has a ring, and one out of view comes into it") {
        let w = try PartsWindow()
        let size = CGSize(width: 800, height: 500)
        w.editor.selection = w.a
        let selected = renderBitmap(w.editor, size: size)
        let walk = w.walk()
        walk.press(.optionTab)
        let focused = renderBitmap(w.editor, size: size)
        let left = try require(w.editor.focusedPart?.rect)
        let around = w.editor.camera.toView(left.insetBy(dx: -6, dy: -6))
        expect(changedPixels(selected, focused, in: around) > 0, "the ring around Left")
        expectEqual(changedPixels(selected, focused, in: w.editor.camera.toView(left.insetBy(dx: 4, dy: 4))), 0, "a ring, not a fill")
        // The board scrolled so the box's bottom edge, its handle, is below the view.
        w.editor.camera = Camera(origin: CGPoint(x: 0, y: -300))
        let handle = try require(w.editor.shapeParts(of: w.a).last?.rect)
        expect(!w.editor.camera.toWorld(w.editor.unobscuredViewport).contains(handle))
        walk.press(.optionBackTab)
        expectEqual(walk.focus.id, "canvas/A/Handle")
        expect(w.editor.cameraTarget.toWorld(w.editor.unobscuredViewport).contains(handle), "brought into view")
    },
    test("the ring goes where its shape is drawn, as a shake or a glide carries the shape and its chips") {
        let w = try PartsWindow()
        let size = CGSize(width: 800, height: 500)
        w.editor.selection = w.a
        let walk = w.walk()
        walk.press(.optionTab)
        let left = try require(w.editor.focusedPart?.rect)
        w.editor.setDrawingOffset(CGPoint(x: 0, y: 200), for: w.a)
        let ringed = renderBitmap(w.editor, size: size)
        walk.press(.escape)
        let bare = renderBitmap(w.editor, size: size)
        expect(changedPixels(bare, ringed, in: w.editor.camera.toView(left.offsetBy(dx: 0, dy: 200).insetBy(dx: -6, dy: -6))) > 0,
               "the ring 200 lower, with the shape")
        expectEqual(changedPixels(bare, ringed, in: w.editor.camera.toView(left.insetBy(dx: -6, dy: -6))), 0, "none where the part is")
    },
    test("the focus goes with another selection, with a commit that takes its part away, and with editing; a commit that keeps it keeps it") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        walk.press(.optionTab)
        expectEqual(walk.press(.optionTab).id, "canvas/A/Right")
        w.editor.selection = w.b
        expect(!w.editor.hasFocusedPart)
        w.editor.selection = w.a
        expectEqual(walk.focus.id, "canvas/A", "selecting the shape again starts at the shape")
        walk.press(.optionTab)
        walk.press(.optionTab)
        w.editor.nudgeSelection(by: CGPoint(x: 5, y: 0))
        expectEqual(walk.focus.id, "canvas/A/Right", "moved, the part is still there")
        w.editor.transact { $0.update(w.a, as: Box.self) { $0.props.frame.size.width = 120 } }
        expectEqual(walk.focus.id, "canvas/A", "narrowed, the box shows no Right chip")
        expect(!w.editor.hasFocusedPart)
        w.editor.setTool(.hand)
        w.editor.setTool(.select)
        w.editor.selection = w.a
        walk.press(.optionTab)
        w.editor.setTool(.hand)
        expect(!w.editor.hasFocusedPart, "another tool")
    },
    test("a press of the pointer lets the focus go, on the shape itself too: Space then holds the Hand, and Delete deletes") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        expectEqual(walk.press(.optionTab).id, "canvas/A/Left")
        w.h.click(at: w.h.view(CGPoint(x: 200, y: 180)))
        expectEqual(w.editor.selectedShapeIDs, [w.a], "still selected")
        expect(!w.editor.hasFocusedPart, "the pointer took over from the keys")
        expectEqual(walk.focus.id, "canvas/A")
        walk.press(.space)
        expect(w.editor.isHandHeld, "Space holds the Hand, pressing no part")
        walk.driver.release(.space)
        expect(w.log.pressed.isEmpty)
        walk.press(.delete)
        expect(w.editor.document[w.a] == nil)
    },
    test("a focused part keeps Delete from the shape it is on when a key or the menu bar asks, never from a context menu's shapes") {
        let w = try PartsWindow()
        let walk = w.walk()
        w.editor.selection = w.a
        walk.press(.optionTab)
        expect(!w.editor.canPerform(.delete), "a key or the menu bar: the part is in front of the shape")
        expect(!w.editor.canPerform(.delete, on: [w.a]), "nor with no click")
        expect(w.editor.canPerform(.delete, on: [w.b], at: CGPoint(x: 450, y: 150)), "another shape's context menu")
        expect(w.editor.canPerform(.delete, on: [w.a], at: CGPoint(x: 200, y: 180)), "the shape's own context menu")
        expect(w.editor.canPerform(.delete, on: [w.b]), "another shape, from any surface")
    },
    test("with no shape or several selected, ⌥Tab and ⌥⇧Tab focus nothing") {
        let w = try PartsWindow()
        let walk = w.walk()
        expectEqual(walk.press(.optionTab).id, "canvas")
        expectEqual(walk.press(.optionBackTab).id, "canvas")
        w.editor.selectedShapeIDs = [w.a, w.b]
        expectEqual(walk.press(.optionTab).id, "canvas/A+B")
        expectEqual(walk.press(.optionBackTab).id, "canvas/A+B")
        expect(!w.editor.hasFocusedPart)
        expect(w.log.pressed.isEmpty)
    },
    test("the report names the parts' scope, and the Keyboard Shortcuts window lists their keys") {
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), threeParts(PartLog())])
        expect(registry.report.contains("parts → every shape with a box"), registry.report)
        let rows = registry.keyboardHelpRows
        expectEqual(rows.first { $0.title == "Next Part" }?.keys, ["⌥⇥"])
        expectEqual(rows.first { $0.title == "Previous Part" }?.keys, ["⌥⇧⇥"])
    },
])
