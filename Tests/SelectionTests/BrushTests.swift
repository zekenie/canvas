@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

@MainActor let brushTests = Suite("Brush", [
    test("past 4 pt on empty canvas editor.brush spans the press to the pointer, and the selection updates live, back to front") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.press(at: CGPoint(x: 150, y: 150))
        h.drag(to: CGPoint(x: 154, y: 150))
        expectEqual(h.editor.brush, nil, "4 pt isn't past the threshold")
        h.drag(to: CGPoint(x: 154, y: 152))
        expectEqual(h.editor.brush, CGRect(x: 150, y: 150, width: 4, height: 2))
        h.drag(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.brush, CGRect(x: 50, y: 50, width: 100, height: 100))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.drag(to: CGPoint(x: 450, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [c, b])
        h.drag(to: CGPoint(x: 160, y: 160))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.release()
        expectEqual(h.editor.brush, nil)
        expectEqual(h.editor.camera, Camera())
    },
    test("the marquee redraws as it moves, even when the selection doesn't change") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let host = DisplayCounter()
        h.editor.delegate = host
        h.press(at: CGPoint(x: 500, y: 500)); h.drag(to: CGPoint(x: 520, y: 520))
        let redraws = host.redraws
        h.drag(to: CGPoint(x: 540, y: 540))
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.brush, CGRect(x: 500, y: 500, width: 40, height: 40))
        expect(host.redraws > redraws)
        h.release()
    },
    test("the brush selects a box it crosses and one it strictly contains; not a disc whose frame corner it only overlaps") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let small = h.add(Box(CGRect(x: 150, y: 20, width: 20, height: 20)))
        h.add(Disc(CGRect(x: 500, y: 500, width: 100, height: 100)))
        h.press(at: CGPoint(x: 150, y: 150)); h.drag(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.release()
        h.press(at: CGPoint(x: 140, y: 10)); h.drag(to: CGPoint(x: 180, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [small])
        h.release()
        h.press(at: CGPoint(x: 490, y: 490)); h.drag(to: CGPoint(x: 510, y: 510))
        expectEqual(h.editor.selectedShapeIDs, [], "(510, 510) is outside the disc")
        h.drag(to: CGPoint(x: 520, y: 520))
        expectEqual(h.editor.selectedShapeIDs.count, 1, "(520, 520) is inside it")
        h.release()
    },
    test("the default brush hit test: an outline edge crossing or touching the brush, or a brush inside a closed outline; open outlines only by their edges") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let context = h.editor.shapeContext
        // Corners at the frame's edge midpoints.
        let diamond = DiamondDefinition().geometry(of: ShapeRecord(Diamond(CGRect(x: 0, y: 0, width: 100, height: 100))), in: context)
        expect(diamond.isHit(byBrush: CGRect(x: 40, y: 40, width: 20, height: 20)), "inside")
        expect(diamond.isHit(byBrush: CGRect(x: 90, y: 40, width: 20, height: 20)), "across the outline")
        expect(diamond.isHit(byBrush: CGRect(x: 100, y: 40, width: 20, height: 20)), "touching its corner (100, 50)")
        expect(!diamond.isHit(byBrush: CGRect(x: 0, y: 0, width: 10, height: 10)), "in the frame's corner")
        // (0, 0) → (100, 0) → (100, 100)
        let corner = CornerDefinition().geometry(of: ShapeRecord(Corner(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 100))), in: context)
        expect(corner.isHit(byBrush: CGRect(x: 45, y: -10, width: 10, height: 20)))
        expect(!corner.isHit(byBrush: CGRect(x: 40, y: 30, width: 20, height: 20)), "open: its hollow is outside it, and nothing closes it")
    },
    test("a shape touching the brush edge is selected; with ⌘, one whose bounds share the brush's edge is not (strict containment)") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 99, y: 150))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.drag(to: CGPoint(x: 100, y: 150))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.release()
        h.hold(.command)
        h.press(at: CGPoint(x: 50, y: 50)); h.drag(to: CGPoint(x: 200, y: 200))
        expectEqual(h.editor.selectedShapeIDs, [], "the bounds share the brush's right and bottom edges")
        h.drag(to: CGPoint(x: 200.5, y: 200.5))
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.release()
    },
    test("⌘ selects only enclosed shapes; pressing and releasing ⌘ mid-brush re-selects without a move") {
        let (h, a, b) = try crossedAndEnclosed()
        h.press(at: CGPoint(x: 180, y: 70)); h.drag(to: CGPoint(x: 50, y: 10))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.hold(.command)
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.hold([])
        expectEqual(h.editor.selectedShapeIDs, [b], "a released key counts for 150 ms")
        h.wait(149)
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.wait(1)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expectEqual(h.editor.brush, CGRect(x: 50, y: 10, width: 130, height: 60))
        h.release()
    },
    test("⇧ unions with the pre-brush selection, which stays first; releasing ⇧ mid-brush drops the union after 150 ms, with no move") {
        let (h, a, b) = try crossedAndEnclosed()
        let c = h.add(Box(CGRect(x: -300, y: -300, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [c, b]                              // the press is outside their box
        h.hold(.shift)
        h.press(at: CGPoint(x: 180, y: 70)); h.drag(to: CGPoint(x: 120, y: 30))
        expectEqual(h.editor.selectedShapeIDs, [c, b], "B, touched, isn't repeated")
        h.drag(to: CGPoint(x: 50, y: 10))
        expectEqual(h.editor.selectedShapeIDs, [c, b, a])
        h.hold([])
        h.wait(149)
        expectEqual(h.editor.selectedShapeIDs, [c, b, a])
        h.wait(1)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.release()
    },
    test("Escape mid-brush restores the pre-brush selection and clears the brush; later drags do nothing") {
        let (h, a, b) = try crossedAndEnclosed()
        h.editor.selection = b
        h.hold(.shift)
        h.press(at: CGPoint(x: 180, y: 70)); h.drag(to: CGPoint(x: 50, y: 10))
        expectEqual(h.editor.selectedShapeIDs, [b, a])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [b])
        expectEqual(h.editor.brush, nil)
        expect(h.editor.session == nil)
        h.drag(to: CGPoint(x: 60, y: 20)); h.release()
        expectEqual(h.editor.selectedShapeIDs, [b])

        h.hold([])
        h.wait(200)
        h.press(at: CGPoint(x: 180, y: 70)); h.drag(to: CGPoint(x: 50, y: 10))
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [], "a plain press had already deselected")
        h.release()
    },
    test("the release does a final hit test at the release point and clears the brush") {
        let (h, a, b) = try crossedAndEnclosed()
        h.press(at: CGPoint(x: 180, y: 70)); h.drag(to: CGPoint(x: 175, y: 60))
        expectEqual(h.editor.selectedShapeIDs, [])
        h.move(to: CGPoint(x: 50, y: 10))              // no drag event: the release is the first to see it
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expectEqual(h.editor.brush, nil)
    },
    test("a shape with no outline is never brushed, even by a brush over the world origin") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.add(Tag(target: nil))                                       // bounds .zero
        let box = h.add(Box(CGRect(x: 20, y: 20, width: 10, height: 10)))
        for modifiers in [Modifiers(), .command] {
            h.hold(modifiers)
            h.press(at: CGPoint(x: -50, y: -50)); h.drag(to: CGPoint(x: 50, y: 50))
            expectEqual(h.editor.selectedShapeIDs, [box])
            h.release()
        }
    },
    test("a kind adopting BrushHitTesting is asked instead of its geometry, only for overlapping bounds") {
        let log = BrushLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), Contributor(id: "picky") { $0.shape(PickyDefinition(log: log)) }])
        let picky = h.add(Picky(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.press(at: CGPoint(x: 300, y: 300)); h.drag(to: CGPoint(x: 250, y: 250))
        expectEqual(log.asked, [], "the bounds aren't touched")
        h.drag(to: CGPoint(x: 150, y: 150))
        expectEqual(log.asked, [CGRect(x: 150, y: 150, width: 150, height: 150)])
        expectEqual(h.editor.selectedShapeIDs, [], "its answer, though its frame is crossed")
        log.answer = true
        h.drag(to: CGPoint(x: 140, y: 150))
        expectEqual(h.editor.selectedShapeIDs, [picky])
        let asked = log.asked.count
        h.drag(to: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [picky])
        expectEqual(log.asked.count, asked, "strict containment is decided before the kind is asked")
        h.release()
        h.hold(.command)
        h.press(at: CGPoint(x: 300, y: 300)); h.drag(to: CGPoint(x: 150, y: 150))
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(log.asked.count, asked, "with ⌘, never asked")
        h.release()
    },
    test("the marquee held at the canvas's edge scrolls it, and grows to select what it brings into view") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        let near = h.add(Box(CGRect(x: 400, y: 600, width: 50, height: 50)))
        let below = h.add(Box(CGRect(x: 400, y: 1000, width: 50, height: 50)))
        h.press(at: CGPoint(x: 300, y: 500))
        h.drag(to: CGPoint(x: 500, y: 810))                      // past the bottom edge
        expectEqual(h.editor.selectedShapeIDs, [near])
        h.wait(1000)
        expect(h.editor.camera.origin.y > 250, "scrolled down: \(h.editor.camera)")
        expectClose(try require(h.editor.brush?.maxY), h.editor.camera.toWorld(CGPoint(x: 500, y: 810)).y, within: 1e-9)   // under the pointer
        expectEqual(h.editor.selectedShapeIDs, [near, below], "reached as the canvas scrolled, before the pointer moved")
        h.release()
    },
])

/// A crosses (0, 0, 100, 100); B is (150, 20, 20, 20), inside the brush from (180, 70) to (50, 10).
@MainActor func crossedAndEnclosed() throws -> (EditorHarness, ShapeID, ShapeID) {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
    let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
    let b = h.add(Box(CGRect(x: 150, y: 20, width: 20, height: 20)))
    return (h, a, b)
}

/// An open shape: across from `from`, then down to `to`.
struct Corner: ShapeProps {
    static let kind: ShapeKind = "corner"
    static let properties = Properties<Corner> {
        Property("from", \.from).required()
        Property("to", \.to).required()
    }
    var from: CGPoint
    var to: CGPoint
}
extension Corner {
    init() { self.init(from: .zero, to: .zero) }
}

struct CornerDefinition {}

extension CornerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Corner>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Corner>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [shape.props.from, CGPoint(x: shape.props.to.x, y: shape.props.from.y), shape.props.to], isClosed: false)
    }
}

/// Records the brushes it's asked about, and answers `answer`.
@MainActor final class BrushLog {
    var asked: [CGRect] = []
    var answer = false
}

struct Picky: BoxShapeProps {
    static let kind: ShapeKind = "picky"
    static let properties = Properties<Picky> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}
extension Picky {
    init() { self.init(.zero) }
}

struct PickyDefinition {
    let log: BrushLog
}

extension PickyDefinition: ShapeDefinition, BrushHitTesting {
    func render(_ shape: ShapeRecord<Picky>, in context: RenderContext) {}
    func brushHitTest(_ brush: CGRect, on shape: ShapeRecord<Picky>, in context: ShapeContext) -> Bool {
        log.asked.append(brush)
        return log.answer
    }
}
