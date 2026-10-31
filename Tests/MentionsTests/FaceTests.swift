import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Mentions
import Selection
import TestKit

// Pills on the canvas as Selection's faces, driven headlessly as a user would: a click on a pill
// selects its jot and edits it from the pill; a drag from one moves the jot; a double-click on a
// read-only jot's live pill goes to what it names, and Back returns; the pointer over a live pill
// hovers what it names. Read-only is CanvasTesting's `Frozen`, never Locking. What the text view
// then selects is its own (TextViewTests); here, only where editing began.

/// A jot at (100, 100) whose text starts with a pill naming plate A, far off, and a plate, all on
/// an 800 × 600 view at zoom 1 (view points are world units).
@MainActor private final class FaceBoard {
    let h: EditorHarness
    let refusals = RefusalLog()
    let jot: ShapeID
    let plateFrame = CGRect(x: 2000, y: 1500, width: 120, height: 80)
    var editor: CanvasEditor { h.editor }

    init(text: MentionText = mentioning([.mention(idA, label: "Groceries"), .text(" and the rest of the list")])) throws {
        h = try mentionHarness([FreezingPlugin(log: refusals)])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.editor.add(Plate(plateFrame), titled: "Groceries", id: idA)
        jot = h.editor.add(Jot(CGRect(x: 100, y: 100, width: 200, height: 200), text: text))
    }

    /// Where the jot's pills are, in world units.
    var pills: [MentionPillFrame] { editor.mentionPills(of: jot) }

    func center(_ pill: MentionPillFrame) -> CGPoint { CGPoint(x: pill.frame.midX, y: pill.frame.midY) }

    /// The first pill's center, as the pointer would reach it, in view points.
    func onPill(_ index: Int = 0) throws -> CGPoint { h.view(center(try require(pills.dropFirst(index).first))) }

    /// On the jot, away from its text.
    var onJot: CGPoint { h.view(CGPoint(x: 200, y: 280)) }

    func doubleClick(at point: CGPoint) {
        h.click(at: point)
        h.click(at: point, clickCount: 2)
    }
}

@MainActor let faceTests = Suite("Faces", [
    test("a click on a pill of a jot that isn't selected selects the jot and edits it from the pill's center") {
        let board = try FaceBoard()
        let pill = try require(board.pills.first)
        expectEqual(pill.target, idA)
        expect(pill.isLive)
        board.h.move(to: try board.onPill())
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.editingShapeID, board.jot)
        expectEqual(board.editor.editingStartPoint, board.center(pill))
        expect(board.refusals.refusals.isEmpty)
    },
    test("a click on a pill of the selected jot edits it from the pill too; a click beside the pill doesn't edit it") {
        let board = try FaceBoard()
        board.h.click(at: board.onJot)
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.editingShapeID, nil, "beside the pill, the jot is only selected")
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.editingShapeID, board.jot)
        expectEqual(board.editor.editingStartPoint, board.center(try require(board.pills.first)))
    },
    test("pills are found where they're drawn, whatever the camera") {
        let board = try FaceBoard()
        board.editor.camera.setZoom(2, around: .zero)
        board.editor.camera.pan(by: CGSize(width: -120, height: -90))
        let pill = try require(board.pills.first)
        board.h.click(at: board.h.view(CGPoint(x: pill.frame.maxX - 1, y: pill.frame.maxY - 1)))
        expectEqual(board.editor.editingShapeID, board.jot, "just inside its bottom-right corner")
        board.h.escape()
        board.h.escape()
        board.h.click(at: board.h.view(CGPoint(x: pill.frame.maxX + 1, y: pill.frame.midY)))
        expectEqual(board.editor.editingShapeID, nil, "just past its right end")
    },
    test("a drag from a pill moves the jot, and edits nothing") {
        let board = try FaceBoard()
        let start = try board.onPill()
        board.h.press(at: start)
        board.h.drag(to: CGPoint(x: start.x + 20, y: start.y + 10))
        board.h.drag(to: CGPoint(x: start.x + 40, y: start.y + 30))
        board.h.release()
        expectEqual(board.editor.document[board.jot]?.box?.origin, CGPoint(x: 140, y: 130))
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.editingShapeID, nil)
    },
    test("a read-only jot: a click on a pill only selects it, with no try to change it; a double-click goes to what it names, and Back returns") {
        let board = try FaceBoard()
        board.editor.freeze([board.jot])
        let camera = board.editor.camera
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.editingShapeID, nil)
        expect(board.refusals.refusals.isEmpty, "a click isn't a try: \(board.refusals.refusals)")
        board.h.click(at: try board.onPill(), clickCount: 2)
        expectEqual(board.editor.selection, idA, "gone to the plate")
        expectEqual(board.editor.editingShapeID, nil)
        expect(board.refusals.refusals.isEmpty, "nor is a double-click")
        let shown = board.editor.cameraTarget.toWorld(CGRect(origin: .zero, size: board.editor.viewportSize))
        expect(shown.contains(board.plateFrame), "brought into view: \(shown)")
        board.editor.goBack()
        expectEqual(board.editor.selection, board.jot, "Back returns to the jot")
        expectEqual(board.editor.cameraTarget, camera)
    },
    test("a double-click's press on a live pill goes to what it names in place of editing the jot, read-only or not") {
        let board = try FaceBoard()
        board.h.click(at: try board.onPill(), clickCount: 2)
        expectEqual(board.editor.selection, idA)
        expectEqual(board.editor.editingShapeID, nil)
        board.editor.goBack()
        expectEqual(board.editor.selection, board.jot, "back to the jot it was followed from")
        expect(!board.editor.canGoBack, "the press selected the jot in view: no step of its own")
    },
    test("a pill naming a shape that isn't there: a click edits the jot from it; on a read-only jot, a double-click does nothing") {
        let board = try FaceBoard()
        board.editor.delete(idA)
        let pill = try require(board.pills.first)
        expect(!pill.isLive)
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.editingShapeID, board.jot, "missing pills are faces too, so one can be deleted")
        expectEqual(board.editor.editingStartPoint, board.center(pill))
        board.h.escape()
        board.h.escape()
        board.editor.freeze([board.jot])
        let camera = board.editor.cameraTarget
        board.doubleClick(at: try board.onPill())
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.editingShapeID, nil)
        expectEqual(board.editor.cameraTarget, camera, "nowhere to go")
        expect(!board.editor.canGoBack || board.editor.selection == board.jot)
        expect(board.refusals.refusals.isEmpty)
    },
    test("the pointer over a live pill hovers what it names; over a missing or unavailable one, or beside a pill, the jot") {
        let keptID = ShapeID()
        let board = try FaceBoard(text: mentioning([.mention(idA, label: "Groceries"), .text(" "), .mention(idB, label: "Gone"), .text(" "),
                                                    .mention(keptID, label: "Kept")]))
        append([try keptAside(Plate.kind, id: keptID, in: board.editor.registry)], to: board.editor)
        expectEqual(board.pills.map(\.isLive), [true, false, false])
        board.h.move(to: try board.onPill(0))
        expectEqual(board.editor.hovered, idA)
        board.h.move(to: try board.onPill(1))
        expectEqual(board.editor.hovered, board.jot, "missing: its jot")
        board.h.move(to: try board.onPill(2))
        expectEqual(board.editor.hovered, board.jot, "kept aside: its jot")
        board.h.move(to: board.onJot)
        expectEqual(board.editor.hovered, board.jot)
        board.h.move(to: try board.onPill(0))
        expectEqual(board.editor.hovered, idA, "back on it")
        board.editor.rename(idA, nil)
        board.h.move(to: try board.onPill(0))
        expectEqual(board.editor.hovered, idA, "renamed, it's still what the pill names")
    },
    test("the jot being edited has no faces: the pointer over its pills hovers the jot, not what they name") {
        let board = try FaceBoard()
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.editingShapeID, board.jot)
        board.h.move(to: try board.onPill())
        expectEqual(board.editor.hovered, board.jot)
    },
    test("a shape over a pill takes the press and the hover") {
        let board = try FaceBoard()
        let pill = try require(board.pills.first)
        let cover = board.editor.add(Box(pill.frame.insetBy(dx: -4, dy: -4)))
        board.h.move(to: try board.onPill())
        expectEqual(board.editor.hovered, cover)
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.selection, cover)
        expectEqual(board.editor.editingShapeID, nil)
    },
    test("a press with ⇧, ⌘ or ⌥ on a pill is the jot's, and edits nothing") {
        for modifiers in [Modifiers.shift, .command, .option] {
            let board = try FaceBoard()
            let other = board.editor.add(Box(CGRect(x: 400, y: 100, width: 50, height: 50)))
            board.h.click(at: board.h.view(CGPoint(x: 425, y: 125)))
            board.h.hold(modifiers)
            board.h.click(at: try board.onPill())
            board.h.hold([])
            expectEqual(board.editor.editingShapeID, nil, "\(modifiers)")
            if modifiers == .option {
                expectEqual(board.editor.selectedShapeIDs, [board.jot], "⌥: pressed as the jot")
            } else {
                expectEqual(Set(board.editor.selectedShapeIDs), [other, board.jot], "\(modifiers): added to the selection")
            }
        }
    },
    test("pills on a shape with several, and none on text without mentions") {
        let board = try FaceBoard(text: mentioning([.text("Ask "), .mention(idA, label: "Groceries"), .text(" and "), .mention(idB, label: "Gone")]))
        expectEqual(board.pills.map(\.target), [idA, idB])
        board.h.click(at: try board.onPill(1))
        expectEqual(board.editor.editingStartPoint, board.center(board.pills[1]))
        let plain = board.editor.add(Jot(CGRect(x: 400, y: 100, width: 200, height: 200), text: "Nothing here"))
        expectEqual(board.editor.mentionPills(of: plain), [])
        expectEqual(board.editor.mentionPills(of: idA), [], "a plate draws no mention text")
    },
    test("zoomed out past 35%, a jot is drawn as a skeleton, with no pills to click or hover: a click there selects it, a double-click edits it; at 35%, pills again") {
        let board = try FaceBoard()
        let pill = try require(board.pills.first)
        board.editor.camera = Camera(zoom: 0.3)
        board.h.move(to: try board.onPill())
        expectEqual(board.editor.hovered, board.jot, "not what the pill names")
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.editingShapeID, nil, "no edit from the pill")
        board.h.click(at: try board.onPill(), clickCount: 2)
        expectEqual(board.editor.selection, board.jot, "not gone to what the pill names")
        expectEqual(board.editor.editingShapeID, board.jot, "a double-click on the jot edits it")
        let start = try require(board.editor.editingStartPoint, "from where it's pressed, as any double-click")
        expect(start.distance(to: board.center(pill)) < 0.01, "there, no pill's face: \(start)")
        board.editor.endEditing()
        board.editor.camera = Camera(zoom: 0.35)
        board.h.move(to: try board.onPill())
        expectEqual(board.editor.hovered, idA)
        board.h.click(at: try board.onPill())
        expectEqual(board.editor.editingShapeID, board.jot)
        expectEqual(board.editor.editingStartPoint, board.center(pill), "from the pill")
    },
    test("zoomed out past 35%, a double-click where a read-only jot's live pill is tries to edit the jot, and goes nowhere") {
        let board = try FaceBoard()
        board.editor.freeze([board.jot])
        board.editor.camera = Camera(zoom: 0.3)
        let camera = board.editor.cameraTarget
        board.doubleClick(at: try board.onPill())
        expectEqual(board.editor.selection, board.jot)
        expectEqual(board.editor.cameraTarget, camera)
        expectEqual(board.refusals.refusals, [[board.jot]], "a try to edit it, which a read-only jot refuses")
    },
    test("a pill hovered at 40%, zoomed out to 30% under a still pointer, hovers what it names no longer, but its jot; zoomed back in, again") {
        let board = try FaceBoard()
        board.editor.camera = Camera(zoom: 0.4)
        let point = try board.onPill()
        board.h.move(to: point)
        expectEqual(board.editor.hovered, idA)
        board.editor.camera.setZoom(0.3, around: point)
        expectEqual(board.editor.hovered, board.jot)
        board.editor.camera.setZoom(0.4, around: point)
        expectEqual(board.editor.hovered, idA)
    },
])
