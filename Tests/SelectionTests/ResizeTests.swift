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

/// What the fixture resize adjuster heard: the drags it was made for, and each event's box, scaling and keys.
@MainActor
final class ResizerLog {
    var begun: [ResizeStart] = []
    var asked: [(resized: CGRect, scaling: ResizeScaling, modifiers: Modifiers)] = []
    var draws = 0
}

/// A resize adjuster that gives the box its rule says, and draws a black square at the world's origin.
@MainActor
final class RuleResizer: ResizeAdjuster {
    let log: ResizerLog
    let rule: @MainActor (CGRect, ResizeScaling, Modifiers) -> CGRect
    init(log: ResizerLog, rule: @escaping @MainActor (CGRect, ResizeScaling, Modifiers) -> CGRect) {
        self.log = log
        self.rule = rule
    }

    func adjust(_ resized: CGRect, scaling: ResizeScaling, for pointer: Pointer, in editor: CanvasEditor) -> CGRect {
        log.asked.append((resized, scaling, pointer.modifiers))
        return rule(resized, scaling, pointer.modifiers)
    }

    func draw(in context: OverlayContext) {
        log.draws += 1
        context.cg.setFillColor(CGColor(gray: 0, alpha: 1))
        context.cg.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
}

/// The resize adjuster, claimed with `rule`: the box as the pointer gives it, unless it says otherwise.
@MainActor func resizerPlugin(_ log: ResizerLog,
                              rule: @escaping @MainActor (CGRect, ResizeScaling, Modifiers) -> CGRect = { resized, _, _ in resized }) -> Contributor {
    Contributor(id: "resizer") { r in
        r.resizeAdjuster { _, start in
            log.begun.append(start)
            return RuleResizer(log: log, rule: rule)
        }
    }
}

/// `box` with its right side on a grid of 50, unless ⌘ is held.
@MainActor func rightOnGrid(_ box: CGRect, _ scaling: ResizeScaling, _ modifiers: Modifiers) -> CGRect {
    guard !modifiers.contains(.command) else { return box }
    return CGRect(x: box.minX, y: box.minY, width: (box.maxX / 50).rounded() * 50 - box.minX, height: box.height)
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
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 150, y: 100)), AnyHashable(ResizeHandle.top), "between two handles, the edge is its side's")
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
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 150, y: 100)), nil, "nor its sides")
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
    test("a side is pressed anywhere along it, from 6 points inside its edge to 6 past the outline drawn off it, the corners' handles first") {
        let (h, box) = try resizeHarness()
        h.editor.outlineStandoff = Style.outlineStandoff                          // 4, as the app draws it
        let sides: [(ResizeHandle, CGPoint, CGPoint)] = [               // a point on the side, and the way out of the box
            (.top, CGPoint(x: 130, y: 100), CGPoint(x: 0, y: -1)),
            (.right, CGPoint(x: 300, y: 120), CGPoint(x: 1, y: 0)),
            (.bottom, CGPoint(x: 270, y: 200), CGPoint(x: 0, y: 1)),
            (.left, CGPoint(x: 100, y: 180), CGPoint(x: -1, y: 0)),
        ]
        for (side, at, out) in sides {
            for off: CGFloat in [-6, 0, 4, 10] {
                expectEqual(h.editor.handle(atViewPoint: at + out * off), AnyHashable(side), "\(side), \(off) out")
            }
            expectEqual(h.editor.handle(atViewPoint: at + out * -7), nil, "\(side): further in is the shape's")
            expectEqual(h.editor.handle(atViewPoint: at + out * 11), nil, "\(side): further out is the canvas's")
        }
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 295, y: 106)), AnyHashable(ResizeHandle.topRight), "a corner's handle first")
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 316, y: 90)), nil, "past a side's end")
        h.editor.outlineStandoff = 0
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 130, y: 94)), AnyHashable(ResizeHandle.top), "6 past an outline on the edge")
        expectEqual(h.editor.handle(atViewPoint: CGPoint(x: 130, y: 93)), nil)
        h.editor.outlineStandoff = Style.outlineStandoff
        h.move(to: CGPoint(x: 296, y: 120))
        expectEqual(h.editor.hoveredHandle, AnyHashable(ResizeHandle.right), "hovered as its side's handle")
        expectEqual(h.editor.cursor, .resize(.right))
        expectEqual(h.editor.hovered, nil, "the shape under it isn't")
        h.press(at: CGPoint(x: 296, y: 120))
        h.drag(to: CGPoint(x: 311, y: 130))
        h.drag(to: CGPoint(x: 326, y: 140))
        h.release()
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 230, height: 100), "the side alone moved, with the pointer")
        expectEqual(h.editor.undoHistory.undoName, "Resize")
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
        expectEqual(h.editor.handle(atViewPoint: h.view(CGPoint(x: 150, y: 100))), AnyHashable(ResizeHandle.top), "its top's, along it")
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)        // 100 by 50: all eight
        expect(ResizeHandle.allCases.allSatisfy { h.editor.handle(atViewPoint: h.view(point(of: $0, on: resizeFrame))) == AnyHashable($0) })
    },
    test("a resize asks the resize adjuster, once as it begins and at each event, and the box takes what it says; the translation adjuster is a move's") {
        let count = AdjusterCount()
        let adjuster = Contributor(id: "adjuster") { r in
            r.translationAdjuster { _, _ in
                count.begun += 1
                return StillAdjuster()
            }
        }
        let log = ResizerLog()
        let (h, box) = try resizeHarness([adjuster, resizerPlugin(log, rule: rightOnGrid)])
        h.resize(box, .right, by: CGPoint(x: 33, y: 0))
        expectEqual(count.begun, 0, "a resize doesn't ask the translation adjuster")
        expectEqual(log.begun.count, 1)
        expectEqual(log.asked.map { $0.resized.maxX }, [316.5, 333, 333], "two drag events and the release, as the pointer gives it")
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 250, height: 100), "its right side on the grid")
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        h.press(at: CGPoint(x: 200, y: 150))
        h.drag(to: CGPoint(x: 210, y: 160))
        h.release()
        expectEqual(count.begun, 1, "a move asks it")
        expectEqual(log.begun.count, 1, "and not the resize adjuster")
    },
    test("the resize adjuster is told the shape, its box, its minimum and its room; what it gives past the room is cut to it") {
        let log = ResizerLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin(), resizableBoxes(),
                                            resizerPlugin(log) { resized, _, _ in resized.insetBy(dx: -1000, dy: 0) }])
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let box = h.add(Box(resizeFrame))
        h.editor.put([box], in: corral)
        h.editor.selection = box
        h.resize(box, .right, by: CGPoint(x: 30, y: 0))
        let start = try require(log.begun.first)
        expectEqual(start.id, box)
        expectEqual(start.box, resizeFrame)
        expectEqual(start.minimum, CGSize(width: 20, height: 10))
        expectEqual(start.room, CGRect(x: 16, y: 16, width: 568, height: 368), "16 inside the corral's edge")
        expectEqual(h.frame(of: box), CGRect(x: 16, y: 100, width: 568, height: 100), "the room's, whatever it said")
        expectEqual(h.editor.holder(of: box), corral)
    },
    test("each event tells the resize adjuster how the box changes: about what stays put, along which ways, and whether in proportion") {
        let cases: [(ResizeHandle, Modifiers, ResizeScaling)] = [
            (.right, [], ResizeScaling(anchor: CGPoint(x: 100, y: 150), changesWidth: true, changesHeight: false, keepsProportions: false)),
            (.bottom, [], ResizeScaling(anchor: CGPoint(x: 200, y: 100), changesWidth: false, changesHeight: true, keepsProportions: false)),
            (.topLeft, [], ResizeScaling(anchor: CGPoint(x: 300, y: 200), changesWidth: true, changesHeight: true, keepsProportions: false)),
            (.bottomRight, .shift, ResizeScaling(anchor: CGPoint(x: 100, y: 100), changesWidth: true, changesHeight: true, keepsProportions: true)),
            (.top, .shift, ResizeScaling(anchor: CGPoint(x: 200, y: 200), changesWidth: true, changesHeight: true, keepsProportions: true)),
            (.topLeft, .option, ResizeScaling(anchor: CGPoint(x: 200, y: 150), changesWidth: true, changesHeight: true, keepsProportions: false)),
            (.left, [.option, .shift], ResizeScaling(anchor: CGPoint(x: 200, y: 150), changesWidth: true, changesHeight: true, keepsProportions: true)),
        ]
        for (handle, held, scaling) in cases {
            let log = ResizerLog()
            let (h, box) = try resizeHarness([resizerPlugin(log)])
            h.hold(held)
            h.resize(box, handle, by: CGPoint(x: 30, y: 20))
            expect(!log.asked.isEmpty, "\(handle) with \(held)")
            expect(log.asked.allSatisfy { $0.scaling == scaling }, "\(handle) with \(held): \(log.asked.map { $0.scaling })")
            h.hold([])
        }
    },
    test("held keys ask the resize adjuster again where the pointer is, and what it draws shows while the resize lasts") {
        let log = ResizerLog()
        let (h, box) = try resizeHarness([resizerPlugin(log, rule: rightOnGrid)])
        let side = point(of: .right, on: resizeFrame), size = CGSize(width: 400, height: 300)
        h.move(to: side)
        h.press(at: side)
        h.drag(to: side + CGPoint(x: 10, y: 0))
        h.drag(to: side + CGPoint(x: 33, y: 0))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 250, height: 100))
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 10, y: 10)), [0, 0, 0, 255])
        h.hold(.command)
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 233, height: 100), "asked again with ⌘, the pointer still")
        expect(log.asked.last?.modifiers.contains(.command) == true)
        h.hold([])
        h.wait(150)                                              // a key let go counts as held until then
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 250, height: 100))
        h.release()
        expect(log.draws > 0)
        expect(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 10, y: 10)) != [0, 0, 0, 255], "gone with the resize")
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 250, height: 100))
    },
    test("Escape puts the box back whatever the resize adjuster said; ⌥ and an arrow don't ask it") {
        let log = ResizerLog()
        let (h, box) = try resizeHarness([resizerPlugin(log, rule: rightOnGrid)])
        let side = point(of: .right, on: resizeFrame)
        h.move(to: side)
        h.press(at: side)
        h.drag(to: side + CGPoint(x: 33, y: 0))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 250, height: 100))
        h.escape()
        expectEqual(h.frame(of: box), resizeFrame)
        h.release()
        expect(!h.editor.canUndo, "the step came to nothing")
        let asked = log.asked.count
        h.hold(.option)
        expect(h.key("\u{F703}"))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 201, height: 100), "a unit, as a nudge moves one, unsnapped")
        expectEqual(log.asked.count, asked)
        h.hold([])
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
    test("⌥→ and ⌥↓ grow the only selected shape from its top left, ⌥← and ⌥↑ shrink it, a unit, ten with ⇧; held, one step, Resize") {
        let (h, box) = try resizeHarness()
        let right = "\u{F703}", left = "\u{F702}", up = "\u{F700}", down = "\u{F701}"
        h.hold(.option)
        expect(h.key(right))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 201, height: 100))
        expect(h.key(down))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 201, height: 101))
        expect(h.key(left))
        expect(h.key(up))
        expectEqual(h.frame(of: box), resizeFrame, "the top left stays put")
        h.hold([.option, .shift])
        expect(h.key(right))
        for _ in 0..<2 { expect(h.key(right, isRepeat: true)) }
        h.editor.keyUp(KeyStroke(right, modifiers: [.option, .shift]))
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 230, height: 100))
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        h.editor.undo()
        expectEqual(h.frame(of: box), resizeFrame, "the held key's three, one step")
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("by the keys too, never smaller than the kind's minimum: at it, the key changes nothing and leaves no step") {
        let (h, box) = try resizeHarness()
        h.hold([.option, .shift])
        for _ in 0..<30 { expect(h.key("\u{F702}")) }
        for _ in 0..<30 { expect(h.key("\u{F700}")) }
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 20, height: 10))
        expect(h.key("\u{F700}"), "the key is still taken")
        h.editor.undo()
        expectEqual(h.frame(of: box), CGRect(x: 100, y: 100, width: 20, height: 20), "undo takes back the last press that changed it")
    },
    test("⌥ and an arrow on a read-only shape shake it and change nothing; with no resizable shape selected alone, they pass") {
        let log = RefusalLog()
        let (h, box) = try resizeHarness([FreezingPlugin(log: log), CardsPlugin()])
        h.editor.freeze([box])
        h.hold(.option)
        expect(h.key("\u{F703}"))
        expectEqual(h.frame(of: box), resizeFrame)
        expectEqual(log.refusals, [[box]], "refused, so a lock shakes")
        h.editor.freeze([box], false)
        let other = h.add(Box(CGRect(x: 400, y: 100, width: 50, height: 50)))
        h.editor.selectedShapeIDs = [box, other]
        expect(!h.key("\u{F703}"), "two selected")
        h.editor.selection = h.add(Card(CGRect(x: 0, y: 300, width: 100, height: 60)))
        expect(!h.key("\u{F703}"), "a kind that doesn't resize")
        h.editor.selection = nil
        expect(!h.key("\u{F703}"), "nothing selected")
        expectEqual(h.frame(of: box), resizeFrame)
    },
    test("the resize handles are parts of their shape: ⌥Tab reaches each in reading order, and an arrow moves the one focused as its drag does") {
        let (h, box) = try resizeHarness([FreezingPlugin()])
        h.hold(.option)
        var titles: [String] = []
        for _ in 0..<8 {
            expect(h.key("\t"))
            titles.append(h.editor.focusedPart?.title ?? "none")
        }
        expectEqual(titles, ["Top Left Corner", "Top Edge", "Top Right Corner", "Left Edge", "Right Edge",
                             "Bottom Left Corner", "Bottom Edge", "Bottom Right Corner"])
        expectEqual(h.editor.focusedPart?.role, .handle)
        expect(h.key("\t"))
        expectEqual(h.editor.focusedPart?.title, "Top Left Corner", "round to the first")
        h.hold([])
        expect(h.key("\u{F703}"))
        expectEqual(h.frame(of: box), CGRect(x: 101, y: 100, width: 199, height: 100), "the left side follows →")
        h.hold(.shift)
        expect(h.key("\u{F701}"))
        expectEqual(h.frame(of: box), CGRect(x: 101, y: 110, width: 199, height: 90), "and the top ⇧↓, ten")
        expectEqual(h.editor.focusedPart?.title, "Top Left Corner", "the focus stays on it")
        h.hold([])
        h.editor.selection = nil
        h.editor.selection = box
        h.hold(.option)
        for _ in 0..<2 { expect(h.key("\t")) }
        expectEqual(h.editor.focusedPart?.title, "Top Edge")
        h.hold([])
        expect(h.key("\u{F703}"))
        expectEqual(h.frame(of: box), CGRect(x: 102, y: 110, width: 199, height: 90), "across the way the top edge moves, → nudges the shape")
        h.editor.freeze([box])
        expectEqual(h.editor.shapeParts(of: box).filter { $0.role == .handle }.count, 0, "a read-only shape has none, as it shows none")
    },
    test("a focused handle the zoom leaves out, drawn in full still, has no focus: no part takes the keys, Delete deletes, and the first Escape goes on out") {
        let (h, _) = try resizeHarness()
        let box = h.add(Box(CGRect(x: 400, y: 100, width: 60, height: 40)))
        h.editor.selection = box
        h.hold(.option)
        expect(h.key("\t"))
        h.hold([])
        expectEqual(h.editor.focusedPart?.title, "Top Left Corner")
        h.editor.camera.zoom = 0.5
        expect(!h.editor.drawsSkeletons, "in full")
        expect(h.editor.shapeParts(of: box).isEmpty, "30 by 20 on screen: no handles")
        expect(!h.editor.hasFocusedPart)
        expect(h.editor.canPerform(.delete), "Delete is no part's")
        expect(h.key("\u{1b}"))
        expectEqual(h.editor.selectedShapeIDs, [], "one Escape, out of the shape: nothing focused was left to back out of")
        h.editor.camera.zoom = 1
        h.editor.selection = box
        h.hold(.option)
        expect(h.key("\t"))
        h.hold([])
        h.editor.camera.zoom = 0.5
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document[box], nil)
    },
    test("a held arrow on a focused handle that shrinks the box past showing it stops there: its repeats never move the shape") {
        let (h, _) = try resizeHarness()
        let box = h.add(Box(CGRect(x: 400, y: 100, width: 100, height: 30)))
        h.editor.selection = box
        h.hold([.option, .shift])
        expect(h.key("\t"))
        h.hold([])
        expectEqual(h.editor.focusedPart?.title, "Bottom Right Corner")
        let up = "\u{F700}"
        expect(h.key(up))
        for _ in 0..<10 { expect(h.key(up, isRepeat: true)) }
        expectEqual(h.frame(of: box), CGRect(x: 400, y: 100, width: 100, height: 23), "under 24 points the corner is gone, and the rest of the hold does nothing")
        expect(!h.editor.hasFocusedPart)
        h.editor.keysReleased()
        expectEqual(h.editor.undoHistory.undoName, "Resize")
        expect(h.key(up))
        expectEqual(h.frame(of: box), CGRect(x: 400, y: 99, width: 100, height: 23), "pressed again, the arrow nudges")
    },
])
