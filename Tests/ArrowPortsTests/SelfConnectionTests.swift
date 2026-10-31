import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import TestKit

// A port's drag back onto the shape it starts from, on a shape a plugin says takes one (Connections' `SelfConnections`): the
// arrow binds there while the pointer is on it, and is handed to the release (`finished`), which makes nothing of a box, so
// the arrow from the box to itself is taken back. Types' use of it, a type related to itself, is ReleaseBetweenTypesTests'.

/// Whether a box takes a port's drag from itself: an added true|false, set on the boxes a test says.
enum Looped {}

extension Looped: ShapeProperty {
    static let key: PropertyKey = "looped"
    static var defaultValue: Bool? { nil }
}

/// Boxes hold `Looped`, and one that holds it true takes a port's drag from itself.
@MainActor private func loopsPlugin() -> Contributor {
    Contributor(id: "loops") { registrar in
        registrar.declare(Looped.self)
        registrar.optIn(Box.self, to: Looped.self)
        registrar.forShapes(holding: Looped.self) { boxes in
            boxes.connectsToItself { shape, _ in shape[Looped.self] == true }
        }
    }
}

@MainActor let selfConnectionTests = Suite("A port's drag back onto where it starts", [
    test("on a box that takes one, the arrow binds back to it while the pointer is on it; released, nothing is made of it, so no arrow and no step are left") {
        let board = try PortBoard(more: [loopsPlugin()])
        let h = board.h
        h.editor.transact { $0.update(board.a) { $0[Looped.self] = true } }
        h.editor.undoHistory.seal()
        let before = h.editor.document
        let steps = h.editor.undoHistory.undoName
        board.connect(to: CGPoint(x: boxA.midX, y: boxA.midY), release: false)
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.props.end.binding?.shapeID, board.a, "bound back to A")
        expectEqual(h.editor.hintedShapeID, board.a)
        h.release()
        expectEqual(h.editor.document, before, "the arrow from A to itself is taken back")
        expectEqual(h.editor.undoHistory.undoName, steps, "and no step")
    },
    test("a box that doesn't take one, or a list without the say, is looked through as ever: released on itself, the drag draws nothing") {
        for withSay in [true, false] {
            let board = try PortBoard(more: withSay ? [loopsPlugin()] : [])
            let h = board.h
            if withSay { h.editor.transact { $0.update(board.a) { $0[Looped.self] = false } } }
            board.connect(to: CGPoint(x: boxA.midX, y: boxA.midY), release: false)
            expectEqual(board.arrows.first?.props.end.binding, nil, "free over A")
            h.release()
            expect(board.arrows.isEmpty)
        }
    },
])
