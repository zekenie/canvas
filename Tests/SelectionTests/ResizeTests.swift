@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Resizing (`ShapeResizing`): CanvasTesting's boxes opted in from another plugin, never smaller than 20 by
// 10, and its cards from their own registrar. The camera starts at the origin at 100%, so view
// points and world units agree until a test zooms.

/// Boxes (CanvasTesting's) that resize, from another plugin.
@MainActor func resizableBoxes(minimumSize: CGSize = CGSize(width: 20, height: 10)) -> Contributor {
    Contributor(id: "resizable-boxes") { $0.resizable(Box.self, minimumSize: minimumSize) }
}

let resizeFrame = CGRect(x: 100, y: 100, width: 200, height: 100)

/// A box in `resizeFrame`, selected alone, with nothing to undo, in an editor with keys, the
/// selection, the fixtures, resizable boxes and `more`.
@MainActor func resizeHarness(_ more: [any CanvasPlugin] = [], resizable: Contributor = resizableBoxes()) throws -> (EditorHarness, ShapeID) {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), resizable] + more)
    let box = h.add(Box(resizeFrame))
    h.editor.replaceDocument(with: h.editor.document)          // nothing to undo
    h.editor.selection = box
    return (h, box)
}

/// Where a handle is on a box.
func point(of handle: ResizeHandle, on box: CGRect) -> CGPoint {
    switch handle {
    case .topLeft: CGPoint(x: box.minX, y: box.minY)
    case .top: CGPoint(x: box.midX, y: box.minY)
    case .topRight: CGPoint(x: box.maxX, y: box.minY)
    case .right: CGPoint(x: box.maxX, y: box.midY)
    case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
    case .bottom: CGPoint(x: box.midX, y: box.maxY)
    case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
    case .left: CGPoint(x: box.minX, y: box.midY)
    }
}

extension EditorHarness {
    /// Presses `handle` of `box` (as it is now, at the current camera) `off` its middle, drags it
    /// `by` view points in two steps, the first past the drag threshold, and lets go.
    func resize(_ box: ShapeID, _ handle: ResizeHandle, by delta: CGPoint, off: CGPoint = .zero) {
        guard let frame = editor.document[box]?.box else { return }
        let start = view(point(of: handle, on: frame)) + off
        move(to: start)
        press(at: start)
        drag(to: start + delta / 2)
        drag(to: start + delta)
        release()
    }

    func frame(of id: ShapeID) -> CGRect? { editor.document[id]?.box }
}

/// What a translation adjuster heard: a drag that moves shapes asks one; a resize never does.
@MainActor
final class AdjusterCount {
    var begun = 0
}

/// Leaves what a drag moves under the pointer.
@MainActor
final class StillAdjuster: TranslationAdjuster {
    func adjust(_ delta: CGPoint, along axis: TranslationAxis?, for pointer: Pointer, in editor: CanvasEditor) -> CGPoint { delta }
    func draw(in context: OverlayContext) {}
}

@MainActor let resizeTests = Suite("Resizing", [
    test("the only selected shape of a resizable kind has eight handles, on its corners and the middles of its sides, hovered as handles are") {
        let (h, box) = try resizeHarness()
        for handle in ResizeHandle.allCases {
            let at = point(of: handle, on: resizeFrame)
            expectEqual(h.editor.handle(atViewPoint: at), AnyHashable(handle), "\(handle) at \(at)")
            expectEqual(h.editor.handle(atViewPoint: at + CGPoint(x: 8, y: -8)), AnyHashable(handle), "within the hit radius of \(handle)")
            h.move(to: at)
            expectEqual(h.editor.hoveredHandle, AnyHashable(handle))
            expectEqual(h.editor.hovered, nil, "a handle takes the hover from its shape")
        }
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 200, y: 150)), nil, "its middle is the shape's")
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 150, y: 100)), nil, "between two handles, the edge is the shape's")
        h.move(to: CGPoint(x: 200, y: 150))
        expectEqual(h.editor.hoveredHandle, nil)
        expectEqual(h.editor.hovered, box)
    },
    test("no handles unselected, with another shape selected too, on a kind that didn't opt in, or on the shape being edited") {
        let cards = CardsPlugin { card, _ in card.resizable(minimumSize: CGSize(width: 10, height: 10)) }
        let (h, box) = try resizeHarness([cards])
        let disc = h.add(Disc(CGRect(x: 400, y: 100, width: 200, height: 100)))
        let card = h.add(Card(CGRect(x: 100, y: 300, width: 200, height: 100)))
        let topLeft = point(of: .topLeft, on: resizeFrame)
        h.editor.selection = nil
        expectEqual(h.editor.handle(atViewPoint: topLeft), nil, "unselected")
        h.editor.selectedShapeIDs = [box, disc]
        expectEqual(h.editor.handle(atViewPoint: topLeft), nil, "one of several selected")
        h.editor.selection = disc
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 400, y: 100)), nil, "a disc doesn't resize")
        h.editor.selection = card
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 100, y: 300)), AnyHashable(ResizeHandle.topLeft), "a card opted in on its own registrar")
        h.editor.beginEditing(card)
        expectEqual(h.editor.editingShapeID, card)
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 100, y: 300)), nil, "being edited")
        h.editor.endEditing()
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 100, y: 300)), AnyHashable(ResizeHandle.topLeft), "and back once it isn't")
    },
    test("a read-only shape has none: a press where one would be presses the shape") {
        let log = RefusalLog()
        let (h, box) = try resizeHarness([FreezingPlugin(log: log)])
        let corner = point(of: .bottomRight, on: resizeFrame)
        h.move(to: corner)
        expectEqual(h.editor.hoveredHandle, AnyHashable(ResizeHandle.bottomRight))
        h.editor.freeze([box])
        expectEqual(h.editor.hoveredHandle, nil, "the change that froze it took the handle away")
        for handle in ResizeHandle.allCases {
            expectEqual(h.editor.handle(atViewPoint: point(of: handle, on: resizeFrame)), nil, "\(handle)")
        }
        h.press(at: CGPoint(x: 295, y: 195))
        h.drag(to: CGPoint(x: 330, y: 230))
        expect(h.editor.session is TranslatingSession, "a press on the shape, which moves the selection")
        h.release()
        expectEqual(h.frame(of: box), resizeFrame, "neither resized nor moved")
        expectEqual(log.refusals, [[box]])
        h.editor.freeze([box], false)
        expectEqual(h.editor.handle(atViewPoint: corner), AnyHashable(ResizeHandle.bottomRight), "back once it can change")
    },
    test("a drag on each handle moves its corner or side with the pointer, the opposite one staying put, grabbed off its middle too") {
        let expected: [(ResizeHandle, CGRect)] = [
            (.topLeft, CGRect(x: 130, y: 120, width: 170, height: 80)),
            (.top, CGRect(x: 100, y: 120, width: 200, height: 80)),
            (.topRight, CGRect(x: 100, y: 120, width: 230, height: 80)),
            (.right, CGRect(x: 100, y: 100, width: 230, height: 100)),
            (.bottomRight, CGRect(x: 100, y: 100, width: 230, height: 120)),
            (.bottom, CGRect(x: 100, y: 100, width: 200, height: 120)),
            (.bottomLeft, CGRect(x: 130, y: 100, width: 170, height: 120)),
            (.left, CGRect(x: 130, y: 100, width: 170, height: 100)),
        ]
        for (handle, frame) in expected {
            for off in [CGPoint.zero, CGPoint(x: 5, y: -4)] {
                let (h, box) = try resizeHarness()
                h.resize(box, handle, by: CGPoint(x: 30, y: 20), off: off)
                expectEqual(h.frame(of: box), frame, "\(handle), grabbed \(off) off its middle")
                expectEqual(h.editor.selection, box, "still selected")
            }
        }
    },
    test("zoomed in, a handle follows the pointer in world units") {
        let (h, box) = try resizeHarness()
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        h.resize(box, .bottomRight, by: CGPoint(x: 30, y: 20))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 215, height: 110))
    },
    test("it resizes as the pointer moves, a transaction a drag event, and the press is one undo step, Resize") {
        let (h, box) = try resizeHarness()
        let corner = point(of: .bottomRight, on: resizeFrame)
        let revision = h.editor.revision
        h.press(at: corner)
        h.drag(to: corner + CGPoint(x: 2, y: 2))
        expectEqual(h.frame(of: box), resizeFrame, "within the drag threshold, nothing")
        h.drag(to: corner + CGPoint(x: 10, y: 5))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 210, height: 105), "past it, from where it was pressed")
        h.drag(to: corner + CGPoint(x: 40, y: 30))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 240, height: 130))
        expectEqual(h.editor.revision, revision + 2)
        h.release()
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        h.editor.undo()
        expectEqual(h.frame(of: box), resizeFrame)
        expect(!h.editor.canUndo, "one step")
        expectEqual(h.editor.selection, box)
        h.editor.redo()
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 240, height: 130))
    },
    test("a click on a handle changes nothing, and leaves no step") {
        let (h, box) = try resizeHarness()
        h.click(at: point(of: .top, on: resizeFrame))
        expectEqual(h.frame(of: box), resizeFrame)
        expect(!h.editor.canUndo)
        expectEqual(h.editor.selection, box)
    },
    test("⇧ keeps the proportions it began with: a corner by the side that grows the most, a side's across it about the middle") {
        let cases: [(ResizeHandle, CGPoint, CGRect)] = [
            (.bottomRight, CGPoint(x: 100, y: 10), CGRect(x: 100, y: 100, width: 300, height: 150)),
            (.bottomRight, CGPoint(x: 10, y: 100), CGRect(x: 100, y: 100, width: 400, height: 200)),
            (.topLeft, CGPoint(x: -100, y: 0), CGRect(x: 0, y: 50, width: 300, height: 150)),
            (.right, CGPoint(x: 100, y: 40), CGRect(x: 100, y: 75, width: 300, height: 150)),
            (.top, CGPoint(x: 30, y: -50), CGRect(x: 50, y: 50, width: 300, height: 150)),
        ]
        for (handle, delta, frame) in cases {
            let (h, box) = try resizeHarness()
            h.hold(.shift)
            h.resize(box, handle, by: delta)
            expectEqual(h.frame(of: box), frame, "\(handle) by \(delta)")
        }
    },
    test("⌥ resizes from the center; with ⇧ too, keeping proportions") {
        let cases: [(Modifiers, ResizeHandle, CGPoint, CGRect)] = [
            (.option, .right, CGPoint(x: 50, y: 30), CGRect(x: 50, y: 100, width: 300, height: 100)),
            (.option, .bottomRight, CGPoint(x: 20, y: 10), CGRect(x: 80, y: 90, width: 240, height: 120)),
            (.option, .top, CGPoint(x: 0, y: 20), CGRect(x: 100, y: 120, width: 200, height: 60)),
            ([.option, .shift], .bottomRight, CGPoint(x: 20, y: 30), CGRect(x: 40, y: 70, width: 320, height: 160)),
        ]
        for (held, handle, delta, frame) in cases {
            let (h, box) = try resizeHarness()
            h.hold(held)
            h.resize(box, handle, by: delta)
            expectEqual(h.frame(of: box), frame, "\(handle) by \(delta) with \(held)")
        }
    },
    test("⇧ and ⌥ take effect as they're pressed or let go mid-drag, without the pointer moving") {
        let (h, box) = try resizeHarness()
        let corner = point(of: .bottomRight, on: resizeFrame)
        h.press(at: corner)
        h.drag(to: corner + CGPoint(x: 50, y: 10))
        h.drag(to: corner + CGPoint(x: 100, y: 10))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 300, height: 110))
        h.hold(.shift)
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 300, height: 150), "⇧: in proportion")
        h.hold([.shift, .option])
        expectEqual(h.frame(of: box), CGRect(x: 0, y: 50, width: 400, height: 200), "and ⌥: from the center")
        h.hold([])
        h.wait(150)                                              // a key let go counts as held until then
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 300, height: 110), "neither")
        h.release()
        expectEqual(h.editor.undoHistory.undoName, "Resize")
    },
    test("never smaller than the kind's minimum, and never inside out: a side dragged past the one opposite stops there") {
        let cases: [(Modifiers, ResizeHandle, CGPoint, CGRect)] = [
            ([], .left, CGPoint(x: 400, y: 0), CGRect(x: 280, y: 100, width: 20, height: 100)),
            ([], .top, CGPoint(x: 0, y: 300), CGRect(x: 100, y: 180, width: 200, height: 20)),
            ([], .bottomRight, CGPoint(x: -500, y: -500), CGRect(x: 100, y: 100, width: 20, height: 20)),
            ([], .topLeft, CGPoint(x: 190, y: 0), CGRect(x: 280, y: 100, width: 20, height: 100)),
            (.shift, .bottomRight, CGPoint(x: -500, y: -500), CGRect(x: 100, y: 100, width: 40, height: 20)),
            (.option, .right, CGPoint(x: -300, y: 0), CGRect(x: 190, y: 100, width: 20, height: 100)),
        ]
        for (held, handle, delta, frame) in cases {
            let (h, box) = try resizeHarness(resizable: resizableBoxes(minimumSize: CGSize(width: 20, height: 20)))
            h.hold(held)
            h.resize(box, handle, by: delta)
            expectEqual(h.frame(of: box), frame, "\(handle) by \(delta) with \(held)")
        }
    },
    test("Escape puts the box back as it was, and leaves no step; the rest of the drag does nothing") {
        let (h, box) = try resizeHarness()
        let corner = point(of: .topLeft, on: resizeFrame)
        h.press(at: corner)
        h.drag(to: corner + CGPoint(x: 30, y: 20))
        expectEqual(h.frame(of: box), CGRect(x: 130, y: 120, width: 170, height: 80))
        h.escape()
        expectEqual(h.frame(of: box), resizeFrame)
        expect(h.editor.session == nil)
        h.drag(to: corner + CGPoint(x: 60, y: 40))
        h.release()
        expectEqual(h.frame(of: box), resizeFrame)
        expect(!h.editor.canUndo, "the step came to nothing")
        expectEqual(h.editor.selection, box)
    },
    test("the cursor over each handle, and while it's pressed and dragged, is its resize cursor; the open hand over another kind's handle") {
        let (h, box) = try resizeHarness([KnobsPlugin()])
        let cursors: [ResizeHandle: CanvasCursor] = [
            .topLeft: .resize(.topLeft), .top: .resize(.top), .topRight: .resize(.topRight), .right: .resize(.right),
            .bottomRight: .resize(.bottomRight), .bottom: .resize(.bottom), .bottomLeft: .resize(.bottomLeft), .left: .resize(.left),
        ]
        for handle in ResizeHandle.allCases {
            h.move(to: point(of: handle, on: resizeFrame))
            expectEqual(h.editor.cursor, cursors[handle], "over \(handle)")
        }
        h.move(to: CGPoint(x: 200, y: 150))
        expectEqual(h.editor.cursor, .standard, "on the shape")
        let corner = point(of: .bottomRight, on: resizeFrame)
        h.move(to: corner)
        h.press(at: corner)
        expectEqual(h.editor.cursor, .resize(.bottomRight), "pressed")
        h.drag(to: corner + CGPoint(x: 20, y: 20))
        expectEqual(h.editor.cursor, .resize(.bottomRight), "dragged")
        h.release()
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 220, height: 120))
        expectEqual(h.editor.hoveredHandle, AnyHashable(ResizeHandle.bottomRight), "the handle came with the pointer")
        expectEqual(h.editor.cursor, .resize(.bottomRight))
        let knob = h.add(Knob(CGRect(x: 400, y: 300, width: 100, height: 100)))   // its handle is at (450, 350)
        h.editor.selection = knob
        h.move(to: CGPoint(x: 450, y: 350))
        expectEqual(h.editor.cursor, .openHand, "a handle of the kind's own")
    },
    test("handles leave a shape room to be pressed itself: none on a box under 24 points on screen either way, a side's only on a side 48 long") {
        let (h, _) = try resizeHarness()
        h.editor.camera = Camera(origin: .zero, zoom: 0.2)        // the box is 40 by 20 on screen
        for handle in ResizeHandle.allCases {
            expectEqual(h.editor.handle(atViewPoint: h.view(point(of: handle, on: resizeFrame))), nil, "\(handle) at 20%")
        }
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)        // 60 by 30: its corners, and its top and bottom
        let shown = ResizeHandle.allCases.filter { h.editor.handle(atViewPoint: h.view(point(of: $0, on: resizeFrame))) == AnyHashable($0) }
        expectEqual(shown, [.topLeft, .top, .topRight, .bottomRight, .bottom, .bottomLeft])
        expectEqual(h.editor.handle(atViewPoint: h.view(point(of: .left, on: resizeFrame))), nil, "its left is the shape's")
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)        // 100 by 50: all eight
        expect(ResizeHandle.allCases.allSatisfy { h.editor.handle(atViewPoint: h.view(point(of: $0, on: resizeFrame))) == AnyHashable($0) })
    },
    test("nothing snaps while resizing: the translation adjuster isn't asked, as it is for a move") {
        let count = AdjusterCount()
        let adjuster = Contributor(id: "adjuster") { r in
            r.translationAdjuster { _, _ in
                count.begun += 1
                return StillAdjuster()
            }
        }
        let (h, box) = try resizeHarness([adjuster])
        h.resize(box, .right, by: CGPoint(x: 33, y: 0))
        expectEqual(count.begun, 0)
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 233, height: 100))
        h.press(at: CGPoint(x: 200, y: 150))
        h.drag(to: CGPoint(x: 210, y: 160))
        h.release()
        expectEqual(count.begun, 1, "a move asks it")
    },
    test("the handles are the canvas's: discs on its corners and sides; the one hovered, and the one dragged, haloed") {
        let size = CGSize(width: 400, height: 300)
        let (h, box) = try resizeHarness()
        let plain = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()], document: h.editor.document)
        plain.editor.selection = box
        let without = renderBitmap(plain.editor, size: size), with = renderBitmap(h.editor, size: size)
        for handle in ResizeHandle.allCases {
            let at = point(of: handle, on: resizeFrame)
            expect(changedPixels(without, with, in: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)) > 20, "a disc on \(handle)")
        }
        expectEqual(changedPixels(without, with, in: CGRect(x: 140, y: 90, width: 20, height: 20)), 0, "nothing between them")
        expectEqual(changedPixels(without, with, in: CGRect(x: 120, y: 120, width: 160, height: 60)), 0, "nor on the shape")
        let corner = point(of: .topRight, on: resizeFrame)
        h.move(to: corner)
        let hovered = renderBitmap(h.editor, size: size)
        expect(changedPixels(with, hovered, in: CGRect(x: corner.x - 12, y: corner.y - 12, width: 24, height: 24)) > 100, "the halo")
        expectEqual(changedPixels(with, hovered, in: CGRect(x: 80, y: 80, width: 180, height: 140)), 0, "on that one only")
        h.press(at: corner)
        h.drag(to: corner + CGPoint(x: 40, y: 0))
        let dragged = renderBitmap(h.editor, size: size)
        let moved = corner + CGPoint(x: 40, y: 0)
        expect(changedPixels(without, dragged, in: CGRect(x: moved.x - 12, y: moved.y - 12, width: 24, height: 24)) > 100,
               "the dragged one, haloed where it went")
        h.release()
    },
    test("a minimum that isn't a size is refused, and the report names the kinds that resize") {
        for minimum in [CGSize(width: 0, height: 10), CGSize(width: 10, height: -1), CGSize(width: CGFloat.infinity, height: 10), CGSize(width: 10, height: CGFloat.nan)] {
            expectThrows(RegistryError.invalid(point: "ShapeResizing",
                                               reason: "resizable-boxes says box is never smaller than \(minimum.width) by \(minimum.height), which isn't a size")) {
                _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), resizableBoxes(minimumSize: minimum)])
            }
        }
        let registry = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), resizableBoxes()])
        expect(registry.report.contains("ShapeResizing → box"), registry.report)
        expectThrows(RegistryError.conflict(point: "ShapeResizing", key: "box", plugins: ["resizable-boxes", "more"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), resizableBoxes(),
                                       Contributor(id: "more") { $0.resizable(Box.self, minimumSize: CGSize(width: 1, height: 1)) }])
        }
    },
])
