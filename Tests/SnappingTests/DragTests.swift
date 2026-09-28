@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Snapping
import TestKit

// Drags with the move tool (a lone box following the pointer from the press, as the select tool's
// does) over boxes in a 1000 × 800 view at 100%, where view points are world units.
@MainActor let dragTests = Suite("Snapping a drag", [
    test("a dragged box snaps its edge onto another's within 8 view points, and follows the pointer exactly along the other axis") {
        let h = try snapHarness()
        let target = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        // Its right edge 10 short of the other's left edge: it follows the pointer.
        h.drag(to: CGPoint(x: 240, y: 263.25))
        expectEqual(h.origin(of: box), CGPoint(x: 190, y: 213.25))
        expectEqual(h.editor.snapGuides, [])
        // 3 short: it snaps onto it.
        h.drag(to: CGPoint(x: 247, y: 263.25))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213.25))
        expectEqual(h.editor.snapGuides, [.alignment(.x, at: 300, points: [CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 100),
                                                                            CGPoint(x: 300, y: 213.25), CGPoint(x: 300, y: 313.25)])])
        h.release()
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213.25))
        expectEqual(h.editor.snapGuides, [], "the guides go with the drag")
        expectEqual(h.origin(of: target), CGPoint(x: 300, y: 0))
    },
    test("8 view points are 4 world units at 200%") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.editor.camera.setZoom(2, around: .zero)
        h.press(at: h.view(CGPoint(x: 50, y: 250)))
        h.drag(to: h.view(CGPoint(x: 245, y: 263)))                       // 5 short: 10 view points
        expectEqual(h.origin(of: box), CGPoint(x: 195, y: 213))
        h.drag(to: h.view(CGPoint(x: 247, y: 263)))                       // 3 short: 6 view points
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213))
        h.release()
    },
    test("a click moves a box no more than the pointer does: nothing snaps until the pointer is past the drag threshold") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        // Its right edge 3 short of the other's left edge, pressed and wobbled 2 points toward it.
        let box = h.add(Box(CGRect(x: 197, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 247, y: 250))
        h.drag(to: CGPoint(x: 249, y: 250))
        expectEqual(h.origin(of: box), CGPoint(x: 199, y: 200))
        expectEqual(h.editor.snapGuides, [])
        h.release()
        expectEqual(h.origin(of: box), CGPoint(x: 199, y: 200))
        // Past the threshold, it snaps; back within it, it still does.
        h.press(at: CGPoint(x: 249, y: 250))
        h.drag(to: CGPoint(x: 255, y: 250))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 251, y: 250))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 200))
        h.release()
    },
    test("⌘ or ⌃ held lets it follow the pointer exactly, at once; let go, it snaps again once the key's release counts") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 247, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213))
        for key in [Modifiers.command, .control] {
            h.hold(key)
            expectEqual(h.origin(of: box), CGPoint(x: 197, y: 213), "\(key)")
            expectEqual(h.editor.snapGuides, [])
            h.drag(to: CGPoint(x: 248, y: 263))
            expectEqual(h.origin(of: box), CGPoint(x: 198, y: 213), "\(key)")
            h.hold([])
            expectEqual(h.origin(of: box), CGPoint(x: 198, y: 213), "a key let go counts as held for 150 ms")
            h.wait(150)
            expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213), "\(key)")
            expect(!h.editor.snapGuides.isEmpty)
            h.drag(to: CGPoint(x: 247, y: 263))
        }
        h.hold(.command)
        h.release()
        expectEqual(h.origin(of: box), CGPoint(x: 197, y: 213), "released with ⌘ held, it stays where the pointer put it")
        h.hold([])
    },
    test("only shapes in view are snapped to, and with no view, none") {
        let h = try snapHarness()
        // Just past the view's right edge, at 1000.
        h.add(Box(CGRect(x: 1003, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 950, y: 263))                                // its right edge 3 short of the box outside
        expectEqual(h.origin(of: box), CGPoint(x: 900, y: 213))
        h.release()

        let unseen = try snapHarness()
        unseen.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let other = unseen.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        unseen.editor.viewportDidResize(to: .zero)
        unseen.press(at: CGPoint(x: 50, y: 250))
        unseen.drag(to: CGPoint(x: 247, y: 263))
        expectEqual(unseen.origin(of: other), CGPoint(x: 197, y: 213))
        unseen.release()
    },
    test("several shapes snap as one, by their frames together, and never to each other") {
        let moves = Moves()
        let h = try snapHarness(moves: moves)
        h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        let a = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 150, y: 200, width: 50, height: 50)))
        moves.ids = [a, b]
        h.press(at: CGPoint(x: 50, y: 250))
        // Their right edge, b's, 3 short of 400; a's right edge would be 3 short of 300, where nothing is.
        h.drag(to: CGPoint(x: 247, y: 263))
        expectEqual(h.origin(of: a), CGPoint(x: 200, y: 213))
        expectEqual(h.origin(of: b), CGPoint(x: 350, y: 213))
        expectEqual(h.editor.snapGuides, [.alignment(.x, at: 400, points: [CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 100),
                                                                            CGPoint(x: 400, y: 213), CGPoint(x: 400, y: 313)])])
        h.release()
    },
    test("a read-only shape stays put and doesn't count in what snaps, but is snapped to") {
        let moves = Moves()
        let h = try snapHarness(moves: moves, [FreezingPlugin()])
        let frozen = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let stuck = h.add(Box(CGRect(x: 0, y: 400, width: 330, height: 50)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.editor.freeze([frozen, stuck])
        moves.ids = [box, stuck]
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 247, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213))
        expectEqual(h.origin(of: stuck), CGPoint(x: 0, y: 400))
        h.release()
    },
    test("Escape puts it back where it was, and the guides go") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 247, y: 263))
        expect(!h.editor.snapGuides.isEmpty)
        h.escape()
        expectEqual(h.origin(of: box), CGPoint(x: 0, y: 200))
        expectEqual(h.editor.snapGuides, [])
        h.release()
    },
    test("the move, snapped, is one step of undo") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 150, y: 263))
        h.drag(to: CGPoint(x: 247, y: 263))
        h.release()
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.origin(of: box), CGPoint(x: 0, y: 200))
        h.editor.redo()
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213))
    },
    test("a shape just placed follows the pointer, and snaps once it's dragged") {
        let h = try snapHarness(shapes: [Contributor(id: "boxes") { $0.shape(BoxDefinitionForTests()) }, discTools()])
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        h.editor.setTool(ToolID(placing: Disc.kind))
        h.press(at: CGPoint(x: 100, y: 250))
        let disc = try require(h.editor.document.shapes.last?.id)
        expectEqual(h.origin(of: disc), CGPoint(x: 80, y: 230))
        // Its right edge 3 short of 300.
        h.drag(to: CGPoint(x: 277, y: 250))
        expectEqual(h.origin(of: disc), CGPoint(x: 260, y: 230))
        h.release()
    },
    test("what's in view is read again once the camera moves mid-drag") {
        let h = try snapHarness()
        // Out of view, until the camera moves 500 points right.
        h.add(Box(CGRect(x: 1100, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 1047, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 997, y: 213))
        h.editor.camera = Camera(origin: CGPoint(x: 500, y: 0))
        h.drag(to: CGPoint(x: 547, y: 263))                               // world (1047, 263) again
        expectEqual(h.origin(of: box), CGPoint(x: 1000, y: 213))
        h.release()
    },
    test("what's in view is read again once a shape the drag doesn't move changes (a plugin's write mid-drag)") {
        let h = try snapHarness()
        let target = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 247, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213))
        h.editor.transact { $0.moveBox(target, to: CGPoint(x: 310, y: 0)) }
        h.drag(to: CGPoint(x: 247, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 197, y: 213), "13 short of where it went")
        h.drag(to: CGPoint(x: 257, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 210, y: 213))
        h.release()
    },
    test("a frame it moves resized mid-drag (a plugin's write) snaps as big as it is now") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 100, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 50, y: 213))
        h.editor.transact { $0.update(box) { $0.box?.size.width = 150 } }
        // Its right edge, 150 wide now, 3 short of the other's left edge (at its old width, 53).
        h.drag(to: CGPoint(x: 197, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 150, y: 213))
        expectEqual(h.editor.snapGuides, [.alignment(.x, at: 300, points: [CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 100),
                                                                            CGPoint(x: 300, y: 213), CGPoint(x: 300, y: 313)])])
        h.release()
    },
    test("the guides go the moment a key frees the drag, though nothing moves, and come back as it's let go, each time redrawn") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        let redraws = Redraws()
        h.editor.delegate = redraws
        h.press(at: CGPoint(x: 50, y: 250))
        // Its right edge exactly on the other's left edge: snapped or not, it's where it is.
        h.drag(to: CGPoint(x: 250, y: 263))
        expectEqual(h.origin(of: box), CGPoint(x: 200, y: 213))
        expect(!h.editor.snapGuides.isEmpty)
        let revision = h.editor.revision, snapped = redraws.count
        h.hold(.command)
        expectEqual(h.editor.revision, revision, "nothing moved")
        expectEqual(h.editor.snapGuides, [])
        expect(redraws.count > snapped, "redrawn without them")
        let freed = redraws.count
        h.hold([])
        h.wait(150)
        expectEqual(h.editor.revision, revision)
        expect(!h.editor.snapGuides.isEmpty)
        expect(redraws.count > freed, "redrawn with them")
        h.release()
    },
    test("equal spacing: dragged after two neighbors, it repeats their space, lined up with them") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.add(Box(CGRect(x: 150, y: 0, width: 100, height: 100)))
        let box = h.add(Box(CGRect(x: 0, y: 300, width: 100, height: 100)))
        h.press(at: CGPoint(x: 50, y: 350))
        h.drag(to: CGPoint(x: 347, y: 53))
        expectEqual(h.origin(of: box), CGPoint(x: 300, y: 0))
        expectEqual(h.editor.snapGuides, [
            .spacing(.x, gaps: [gap(100, 0...100, 150, 0...100), gap(250, 0...100, 300, 0...100)]),
            .alignment(.y, at: 0, points: [0, 100, 150, 250, 300, 400].map { CGPoint(x: $0, y: 0) }),
            .alignment(.y, at: 50, points: [50, 200, 350].map { CGPoint(x: $0, y: 50) }),
            .alignment(.y, at: 100, points: [0, 100, 150, 250, 300, 400].map { CGPoint(x: $0, y: 100) }),
        ])
        h.release()
    },
    test("the guides draw in the snap color while the drag lasts") {
        let h = try snapHarness()
        h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        h.add(Box(CGRect(x: 0, y: 200, width: 100, height: 100)))
        let size = CGSize(width: 500, height: 400)
        // On the line at x = 300, between the two boxes: a point wide, it covers half of each pixel
        // beside 300 (or all of one).
        @MainActor func showsGuide() -> Bool {
            let bitmap = renderBitmap(h.editor, size: size)
            for x in [299, 300] {
                let color = pixel(bitmap, at: CGPoint(x: x, y: 150))
                if color[0] - color[1] > 40 && color[0] - color[2] > 40 { return true }
            }
            return false
        }
        h.press(at: CGPoint(x: 50, y: 250))
        h.drag(to: CGPoint(x: 247, y: 263))
        expect(showsGuide())
        h.release()
        expect(!showsGuide())
    },
])
