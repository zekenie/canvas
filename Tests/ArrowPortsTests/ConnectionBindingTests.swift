import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Ports
import Selection
import TestKit

// How a connection's ends bind as it's drawn from a port: the start at its shape's center, always;
// the end by tldraw's rules, as a re-aimed end's (ArrowsTests' BindingTests), only onto shapes that
// take it.
@MainActor let connectionBindingTests = Suite("Connection binding", [
    test("the start binds the port's shape at its center, imprecisely; arriving fast binds the end to the target's center") {
        let board = try PortBoard()
        board.connect(to: CGPoint(x: 500, y: 120))
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.props.start, binding(board.a))
        expectEqual(arrow.props.end, binding(board.b))
        expectEqual(arrow[ChannelProperty.self], Wire.id)
        expectEqual(board.h.editor.currentToolID, .select)
    },
    test("hovering the shape 700 ms and holding the press 400 ms still starts at its center, imprecisely: a port has no timers") {
        let board = try PortBoard()
        board.h.move(to: CGPoint(x: 180, y: 180))
        board.h.wait(700)
        board.h.move(to: aRightDot)
        board.h.wait(700)
        board.h.press()
        board.h.wait(400)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.release()
        expectEqual(board.arrows.first?.props.start, binding(board.a))
        expectEqual(board.arrows.first?.props.end, binding(board.b))
    },
    test("arriving slowly binds the end precisely where the pointer is") {
        let board = try PortBoard()
        board.connect(to: CGPoint(x: 400, y: 120), release: false)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: slow)
        board.h.release()
        expectEqual(board.arrows.first?.props.end, binding(board.b, CGPoint(x: 0.2, y: 0.2), precise: true))
        expectEqual(board.arrows.first?.props.start, binding(board.a))
    },
    test("entering the target under 0.5 pt/ms binds precisely; over it, to the center") {
        for (speed, precise) in [(CGFloat(0.4), true), (0.6, false)] {
            let board = try PortBoard()
            board.connect(to: CGPoint(x: 400, y: 120), release: false)
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: speed)
            board.h.release()
            expectEqual(board.arrows.first?.props.end.binding?.isPrecise, precise, "speed \(speed)")
        }
    },
    test("pausing 320 ms on the target makes the end precise where the pointer is; 319 ms doesn't") {
        for (pause, precise) in [(319, false), (320, true)] {
            let board = try PortBoard()
            board.connect(to: CGPoint(x: 500, y: 120), release: false)
            board.h.wait(pause - 16)
            board.h.release()                                             // 16 ms later
            let end = try require(board.arrows.first?.props.end.binding, "pause \(pause)")
            expectEqual(end.isPrecise, precise, "pause \(pause)")
            expectClose(end.normalizedAnchor, precise ? CGPoint(x: 0.2, y: 0.2) : center)
        }
    },
    test("a precise end within 16 points of the target's center snaps to it") {
        for (x, anchor) in [(CGFloat(570), center), (580, CGPoint(x: 0.6, y: 0.5))] {        // 10 and 20 from its center
            let board = try PortBoard()
            board.connect(to: CGPoint(x: 400, y: 170), release: false)
            board.h.drag(to: CGPoint(x: x, y: 180), speed: slow)
            board.h.release()
            expectEqual(board.arrows.first?.props.end, binding(board.b, anchor, precise: true), "x \(x)")
        }
    },
    test("the center snap is measured on screen: 10 units off B's center snaps at zoom 1, not at zoom 2") {
        for (zoom, anchor) in [(CGFloat(1), center), (2, CGPoint(x: 0.55, y: 0.5))] {
            let board = try PortBoard()
            board.h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let v = board.h.view
            let dot = v(CGPoint(x: 280, y: 180)) + CGPoint(x: 12, y: 0)             // A's right dot, 12 view points out
            board.connect(from: dot, to: v(CGPoint(x: 400, y: 170)), release: false)
            board.h.drag(to: v(CGPoint(x: 570, y: 180)), speed: slow)
            board.h.release()
            let arrow = try require(board.arrows.first, "zoom \(zoom)")
            expectEqual(arrow.props.start, binding(board.a), "zoom \(zoom)")
            let end = try require(arrow.props.end.binding)
            expect(end.isPrecise, "zoom \(zoom)")
            expectClose(end.normalizedAnchor, anchor, within: 1e-9)
        }
    },
    test("⌥ binds the end exactly: its visible end is where the pointer is; the start stays at the center") {
        let board = try PortBoard()
        board.pressDot()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.release()
        let arrow = try require(board.arrows.first)
        expectEqual(arrow.props.end, binding(board.b, CGPoint(x: 0.2, y: 0.2), precise: true, exact: true))
        expectEqual(arrow.props.start, binding(board.a))
        expectClose(try require(board.h.editor.arrowGeometry(of: arrow.id)).end, CGPoint(x: 500, y: 120))
    },
    test("⌘ and ⌃ bind nothing and hint nothing; released so, nothing is drawn") {
        for modifier in [Modifiers.command, .control] {
            let board = try PortBoard()
            let before = board.h.editor.document
            board.pressDot()
            board.h.hold(modifier)
            board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
            expectEqual(board.h.editor.hintedShapeID, nil, "\(modifier)")
            expectEqual(board.arrows.first?.props.end, .free(CGPoint(x: 500, y: 120)), "\(modifier)")
            board.h.release()
            expect(board.arrows.isEmpty, "\(modifier)")
            expectEqual(board.h.editor.document, before, "\(modifier)")
        }
    },
    test("letting go of ⌥ with the mouse keeps the end exact") {
        let board = try PortBoard()
        board.pressDot()
        board.h.hold(.option)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.hold([])
        board.h.release()                                                 // 16 ms later
        expectEqual(board.arrows.first?.props.end.binding?.isExact, true)
    },
    test("letting go of ⌘ over the target binds the end 150 ms later, as a re-aimed end's does") {
        let board = try PortBoard()
        board.pressDot()
        board.h.hold(.command)
        board.h.drag(to: CGPoint(x: 500, y: 120), speed: fast)
        board.h.hold([])
        board.h.wait(149)
        expectEqual(board.arrows.first?.props.end.binding, nil)
        board.h.wait(1)
        expectEqual(board.arrows.first?.props.end.binding?.shapeID, board.b)
        expectEqual(board.h.editor.hintedShapeID, board.b)
        board.h.release()
        expectEqual(board.arrows.first?.props.end.binding?.shapeID, board.b)
        expectEqual(board.arrows.first?[ChannelProperty.self], Wire.id)
    },
    test("⇧ snaps the free end's angle to 15° steps around the start's anchor, the shape's center") {
        let board = try PortBoard()
        board.pressDot()
        board.h.hold(.shift)
        board.h.drag(to: CGPoint(x: 380, y: 210), speed: fast)
        guard case .free(let end)? = board.arrows.first?.props.end else { throw RequireFailed() }
        expect(end != CGPoint(x: 380, y: 210), "snapped: \(end)")
        expect(isOnStep(atan2(end.y - boxA.center.y, end.x - boxA.center.x)), "\(end)")
        board.h.release()
        expect(board.arrows.isEmpty, "released free, nothing is drawn")
    },
    test("⇧ still held when the pause timer fires keeps the precise end on a 15° step") {
        let board = try PortBoard()
        board.pressDot()
        board.h.hold(.shift)
        board.h.drag(to: CGPoint(x: 520, y: 150), speed: fast)           // 5° off the start's level: snaps to 0°
        board.h.wait(400)
        board.h.release()
        let arrow = try require(board.arrows.first)
        let end = try require(arrow.props.end.binding)
        expectEqual(end.shapeID, board.b)
        expect(end.isPrecise)
        let geometry = try require(board.h.editor.arrowGeometry(of: arrow.id))
        expect(isOnStep(atan2(geometry.endHandle.y - geometry.startHandle.y, geometry.endHandle.x - geometry.startHandle.x)), "\(geometry.endHandle)")
        expect(geometry.endHandle.x < 555, "precise, not the center: \(geometry.endHandle)")
    },
])
