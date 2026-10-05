@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import JumpTo
import Keyboard
import Selection
import TestKit

// What a pick does: Boards' rule (`editor.follow`) for a shape anywhere in the file, one step back;
// and ⌘K, which opens the palette and changes no document.

/// Where bringing `frame` into view takes the camera, as Selection's `reveal` does.
private func revealed(_ frame: CGRect, in view: CGSize) -> Camera { Camera(fitting: frame, in: CGRect(origin: .zero, size: view), inset: 100, maxZoom: 1.2) }

@MainActor let pickTests = Suite("Jump To's picks", [
    test("a shape whose kind opens its board is gone into: that board shown, nothing selected; one step back to where Jump To was opened") {
        let h = try storyHarness()
        h.openJumpTo()
        h.jump.setQuery("epsilon")
        h.jump.pickHighlighted()
        expect(!h.jump.isOpen)
        expectEqual(h.editor.board, BoardID(owner: id(23)), "into Epsilon's board, two boards down")
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
    },
    test("any other shape is gone to: its board shown, it selected; one step back, to the board and the selection it left") {
        let h = try storyHarness()
        h.editor.selection = id(3)
        h.openJumpTo()
        h.jump.setQuery("alpha gamma checkout")
        h.jump.pickHighlighted()
        expectEqual(h.editor.board, BoardID(owner: id(11)), "Beta's board, where the Checkout in Gamma is")
        expectEqual(h.editor.selectedShapeIDs, [id(22)])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [id(3)])
    },
    test("a frame is fitted into view, not zoomed to a readable 70%: a corral too big for the view is brought in as a whole") {
        let h = try storyHarness()
        // Beta's board, visited and left at 100% somewhere the corral isn't whole.
        expect(h.enter(id(1)))
        expect(h.enter(id(11)))
        h.wait(500)
        h.editor.camera = Camera(origin: CGPoint(x: 300, y: 300), zoom: 1)
        expect(h.editor.showBoard(.root))
        h.openJumpTo()
        h.jump.setQuery("gamma")
        h.jump.pickHighlighted()
        h.wait(500)
        expectEqual(h.editor.board, BoardID(owner: id(11)))
        expectEqual(h.editor.selectedShapeIDs, [id(21)])
        let corral = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        expectEqual(h.editor.camera, revealed(corral, in: viewSize))
        expectClose(h.editor.camera.zoom, 0.2, within: 0.001)
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
    },
    test("a shape on the board shown, in view already, is selected and the camera stays; a pick follows it from the row, not the query") {
        let h = try storyHarness()
        h.openJumpTo()
        h.jump.setQuery("delta")
        let camera = h.editor.camera
        h.jump.pick(row: 0)
        expectEqual(h.editor.board, BoardID(owner: id(2)), "a pocket: gone into")
        h.editor.goBack()
        h.openJumpTo()
        h.jump.setQuery("planned")
        h.jump.pick(row: 0)
        expectEqual(h.editor.selectedShapeIDs, [id(4)])
        h.wait(500)
        expectEqual(h.editor.camera, camera, "in view at a readable zoom already")
    },
    test("a header, an empty state and a row that isn't there pick nothing; the palette stays open") {
        let h = try storyHarness()
        h.openJumpTo()
        h.jump.setQuery("")
        h.jump.pick(row: 0)
        h.jump.pick(row: 99)
        h.jump.setQuery("zzzzzzz")
        h.jump.pickHighlighted()
        expect(h.jump.isOpen)
        expectEqual(h.editor.board, .root)
        expectEqual(h.jump.recent, [])
    },
    test("⌘K opens the palette, empty, from the canvas's shortcut and Go › Jump To…; open, it asks for the keyboard again, and keeps what's typed") {
        let h = try storyHarness()
        expect(!h.jump.isOpen)
        h.hold(.command)
        expect(h.key("k"))
        h.hold([])
        expect(h.jump.isOpen)
        expectEqual(h.jump.query, "")
        let first = h.jump.focusRequest
        h.jump.setQuery("alp")
        expect(h.openJumpTo())
        expect(h.jump.isOpen)
        expectEqual(h.jump.query, "alp")
        expectEqual(h.jump.focusRequest, first + 1)
    },
    test("⌘K ends editing first, its edit committed, and leaves no step of undo") {
        let h = try storyHarness()
        let card = h.add(Card(frame(0, 0), text: "Receipt"))
        let steps = h.editor.undoHistory.undoName
        h.editor.selection = card
        expect(h.editor.beginEditing(card))
        expectEqual(h.editor.editingShapeID, card)
        expect(h.openJumpTo())
        expectEqual(h.editor.editingShapeID, nil, "editing ended")
        expect(h.jump.isOpen)
        expectEqual(h.editor.undoHistory.undoName, steps, "no step for opening the palette")
        expect(h.openJumpTo())
        expectEqual(h.editor.undoHistory.undoName, steps, "nor for asking for the keyboard again")
    },
    test("it's refused mid-gesture: a drag under way, ⌘K does nothing and Go › Jump To… is dimmed") {
        let h = try storyHarness()
        h.editor.viewportDidResize(to: viewSize)
        h.press(at: h.view(CGPoint(x: 700, y: 100 + 20)))
        h.drag(to: h.view(CGPoint(x: 760, y: 160)))
        expect(h.editor.session != nil, "a drag is under way")
        expect(!h.editor.canPerform(.jumpTo))
        h.hold(.command)
        h.key("k")
        h.hold([])
        expect(!h.jump.isOpen)
        h.release()
        expect(h.editor.canPerform(.jumpTo))
    },
])
