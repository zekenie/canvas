import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TestKit

// The arrow a drag is drawing or re-aiming says so (`Session.touching`) from the press to the
// release, however the drag ends, so a service that counts arrows leaves it out until then.

/// What `editor.session` said it touches at every commit and at the end of each press.
@MainActor private final class TouchLog {
    var atCommit: [Set<ShapeID>?] = []
}

@MainActor private final class TouchSpy: EditorService {
    let log: TouchLog
    init(log: TouchLog) { self.log = log }
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        log.atCommit.append(editor.session?.touching)
    }
}

@MainActor private func board(_ log: TouchLog) throws -> PortBoard {
    try PortBoard(more: [Contributor(id: "touch-spy") { $0.service { _ in TouchSpy(log: log) } }])
}

@MainActor let arrowTouchingTests = Suite("What an arrow's drag touches", [
    test("a connection being drawn says its arrow from its first hover to its release, and the release's own commit hears it so; none once the press has ended") {
        let log = TouchLog()
        let b = try board(log)
        b.pressDot()
        expectEqual(b.h.editor.session?.touching, [], "before the arrow, the port's press touches nothing")
        b.h.drag(to: CGPoint(x: 360, y: 180), speed: fast)
        let arrow = try require(b.arrows.first?.id)
        expectEqual(b.h.editor.session?.touching, [arrow], "dragged over nothing")
        b.h.drag(to: boxB.center, speed: fast)
        expectEqual(b.h.editor.session?.touching, [arrow], "dragged over a shape, its end bound by each hover")
        log.atCommit = []
        b.h.release()
        expectEqual(b.arrows.first?.props.end.binding?.shapeID, b.b)
        expect(!log.atCommit.isEmpty, "the release commits")
        expect(log.atCommit.allSatisfy { $0 == [arrow] }, "and its commits hear the session still naming the arrow: \(log.atCommit)")
        expect(b.h.editor.session == nil)
        expectEqual(b.h.editor.session?.touching, nil)
    },
    test("a connection released on nothing, which deletes the arrow, and one Escaped, hear the arrow named as they go") {
        let log = TouchLog()
        let b = try board(log)
        b.connect(to: CGPoint(x: 360, y: 700), release: false)
        let free = try require(b.arrows.first?.id)
        log.atCommit = []
        b.h.release()
        expectEqual(b.arrows.count, 0)
        expectEqual(log.atCommit, [[free]], "the free release's delete")
        let again = try board(log)
        again.connect(to: boxB.center, release: false)
        let escaped = try require(again.arrows.first?.id)
        expectEqual(again.h.editor.session?.touching, [escaped])
        log.atCommit = []
        again.h.escape()
        expectEqual(again.arrows.count, 0)
        expectEqual(log.atCommit, [[escaped]], "Escape's delete")
        expect(again.h.editor.session == nil)
    },
    test("an end re-aimed says its arrow from the press to the release, and so does a bend") {
        let log = TouchLog()
        let b = try board(log)
        let arrow = b.addArrow(channel: Wire.id)
        b.h.add(Box(boxD))
        log.atCommit = []
        b.reaim(arrow, from: boxB.center, to: boxD.center, release: false)
        expectEqual(b.h.editor.session?.touching, [arrow], "the end's drag")
        b.h.release()
        expect(!log.atCommit.isEmpty)
        expect(log.atCommit.allSatisfy { $0 == [arrow] }, "everything the drag committed heard it: \(log.atCommit)")
        expectEqual(b.h.editor.session?.touching, nil, "none after the release")
        b.h.editor.selection = arrow
        let middle = try require(b.h.editor.arrowGeometry(of: arrow)).middle
        b.h.move(to: b.h.editor.camera.toView(middle))
        b.h.press()
        b.h.drag(to: b.h.editor.camera.toView(middle) + CGPoint(x: 0, y: 40), speed: fast)
        expectEqual(b.h.editor.session?.touching, [arrow], "the bend handle's drag")
        b.h.release()
        expect(b.h.editor.session == nil)
    },
])
