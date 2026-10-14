@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// What a drag in progress says it is touching (`Session.touching`), for a service that leaves such a
// shape out until the drag is over.

/// A session that changes nothing and answers the default: it touches no shape.
private final class IdleSession {}

extension IdleSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

/// A session that says what it touches, and notes what `editor.session` said of it as it ended or was
/// cancelled.
private final class TouchingSession {
    let shape: ShapeID
    var heardAtEnd: Set<ShapeID>?
    var heardAtCancel: Set<ShapeID>?
    init(_ shape: ShapeID) { self.shape = shape }
}

extension TouchingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
    var touching: Set<ShapeID> { [shape] }
    func end(_ pointer: Pointer, in editor: CanvasEditor) { heardAtEnd = editor.session?.touching }
    func cancel(in editor: CanvasEditor) -> Bool {
        heardAtCancel = editor.session?.touching
        return true
    }
}

@MainActor let sessionTouchingTests = Suite("What a drag touches", [
    test("a session that answers nothing touches no shape; one that answers says which, for as long as it is the editor's session") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        expectEqual(h.editor.session?.touching, nil, "no session, no answer")
        let idle = IdleSession()
        h.editor.session = idle
        expectEqual(idle.touching, [])
        expectEqual(h.editor.session?.touching, [])
        let touching = TouchingSession(box)
        h.editor.session = touching
        expectEqual(h.editor.session?.touching, [box])
        h.editor.session = nil
        expectEqual(h.editor.session?.touching, nil)
    },
    test("the editor's session still says what it touches when its press ends and when it is cancelled, and is none after") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        let ending = TouchingSession(box)
        h.editor.session = ending
        h.release()
        expectEqual(ending.heardAtEnd, [box], "as it ended")
        expect(h.editor.session == nil, "and cleared once it has")
        let cancelled = TouchingSession(box)
        h.editor.session = cancelled
        h.editor.cancel()
        expectEqual(cancelled.heardAtCancel, [box], "as it was cancelled")
        expect(h.editor.session == nil)
    },
])
