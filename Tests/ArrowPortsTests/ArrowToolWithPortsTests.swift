import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Ports
import Selection
import TableOfContents
import TestKit

// Nothing changes for the arrow tool with ports installed: each gesture here, a case from
// ArrowsTests' ArrowToolTests, commits as often and draws the same arrow as it does on a board with
// arrows alone.

/// The same shapes (A, B and the disc, with the same ids) on a board with arrows alone and on one with ports too.
@MainActor
struct TwinBoards {
    let plain: EditorHarness
    let ported: PortBoard

    init() throws {
        ported = try PortBoard()
        plain = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), ArrowsPlugin(), TableOfContentsPlugin()])
        plain.add(Box(boxA), id: ported.a)
        plain.add(Box(boxB), id: ported.b)
        plain.add(Disc(discC), id: ported.c)
    }

    /// Runs `gesture` on both, and returns how many commits it made on each.
    func run(_ gesture: (EditorHarness) -> Void) -> (plain: Int, ported: Int) {
        let plainRevision = plain.editor.revision, portedRevision = ported.h.editor.revision
        gesture(plain)
        gesture(ported.h)
        return (plain.editor.revision - plainRevision, ported.h.editor.revision - portedRevision)
    }

    func arrows(_ h: EditorHarness) -> [Arrow] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props } }

    /// The arrows on both boards are the same, and none has a channel.
    func expectSameArrows(file: StaticString = #fileID, line: UInt = #line) {
        expectEqual(arrows(ported.h), arrows(plain), file: file, line: line)
        expect(ported.arrows.allSatisfy { $0[ChannelProperty.self] == nil }, "no channel", file: file, line: line)
    }
}

@MainActor func drawArrow(_ h: EditorHarness, from: CGPoint, to: CGPoint, speed: CGFloat = fast, release: Bool = true) {
    h.key("a")
    h.move(to: from)
    h.press()
    h.drag(to: to, speed: speed)
    if release { h.release() }
}

@MainActor let arrowToolWithPortsTests = Suite("Arrow tool with ports", [
    test("arriving fast binds the end to the shape's center; finishing selects the arrow and switches to select") {
        let twins = try TwinBoards()
        let commits = twins.run { drawArrow($0, from: boxA.center, to: CGPoint(x: 500, y: 120)) }
        expectEqual(commits.ported, commits.plain)
        let arrow = try require(twins.ported.arrows.first)
        expectEqual(arrow.props.start.binding?.shapeID, twins.ported.a)
        expectEqual(arrow.props.end, binding(twins.ported.b))
        expectEqual(twins.ported.h.editor.currentToolID, .select)
        expectEqual(twins.ported.h.editor.selection, arrow.id)
        expectEqual(twins.ported.h.editor.hintedShapeID, nil)
        twins.expectSameArrows()
    },
    test("arriving slowly binds precisely where the pointer is") {
        let twins = try TwinBoards()
        let commits = twins.run { h in
            drawArrow(h, from: boxA.center, to: CGPoint(x: 400, y: 120), release: false)
            h.drag(to: CGPoint(x: 500, y: 120), speed: slow)
            h.release()
        }
        expectEqual(commits.ported, commits.plain)
        expectEqual(twins.ported.arrows.first?.props.end, binding(twins.ported.b, CGPoint(x: 0.2, y: 0.2), precise: true))
        twins.expectSameArrows()
    },
    test("an arrow from where a port's dot would be, ending on a shape no channel lets a connection end on, is an ordinary arrow") {
        let twins = try TwinBoards()
        let commits = twins.run { drawArrow($0, from: aRightDot, to: discC.center) }
        expectEqual(commits.ported, commits.plain)
        let arrow = try require(twins.ported.arrows.first)
        expectEqual(arrow.props.start, .free(aRightDot))
        expectEqual(arrow.props.end, binding(twins.ported.c))
        expectEqual(twins.ported.h.editor.selection, arrow.id)
        twins.expectSameArrows()
    },
    test("Escape while drawing deletes the new arrow and stays in the arrow tool") {
        let twins = try TwinBoards()
        let commits = twins.run { h in
            drawArrow(h, from: boxA.center, to: CGPoint(x: 300, y: 180), release: false)
            h.escape()
            h.release()
        }
        expectEqual(commits.ported, commits.plain)
        expect(twins.ported.arrows.isEmpty)
        expectEqual(twins.ported.h.editor.currentToolID, .arrow)
        expectEqual(twins.ported.h.editor.selection, nil)
    },
])
