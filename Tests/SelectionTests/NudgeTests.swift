@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

private let left = "\u{F702}", right = "\u{F703}", up = "\u{F700}", down = "\u{F701}"

@MainActor let nudgeTests = Suite("Nudging", [
    test("the arrow keys nudge the selection a world unit, and ten with ⇧, whatever the zoom") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.editor.camera.zoom = 4
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        expect(h.key(right))
        expect(h.key(down))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 1, y: 1))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 201, y: 1))
        h.hold(.shift)
        expect(h.key(left))
        expect(h.key(up))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: -9, y: -9))
        expectEqual(h.editor.undoHistory.undoName, "Move")
        expectEqual(h.editor.selectedShapeIDs, [a, b], "still selected")
    },
    test("with nothing selected and a view with no size, a press under way or a shape being edited, the arrow keys pass") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(!h.key(right), "nothing selected, and nothing to pan")
        h.editor.selection = box
        h.press(at: CGPoint(x: 50, y: 50))
        expect(!h.key(right), "mid-press")
        h.release()
        let card = h.add(Card(CGRect(x: 300, y: 0, width: 100, height: 60)))
        h.editor.selection = card
        h.editor.beginEditing(card)
        expect(!h.key(right), "editing")
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        expectEqual(h.editor.document[card]?.box?.origin, CGPoint(x: 300, y: 0))
    },
    test("a held arrow key's nudges are one undo step; pressed again, another") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.selection = box
        h.key(right)
        for _ in 0..<9 { expect(h.key(right, isRepeat: true), "repeats nudge again") }
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 10, y: 0))
        h.key(right)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 11, y: 0))
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 10, y: 0))
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.origin, .zero, "the held key's ten, one step")
        expectEqual(h.editor.selectedShapeIDs, [box])
    },
    test("a nudge and Delete bring a selection out of view into view first, so what they do shows; in view, the camera stays") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let view = CGSize(width: 1000, height: 700)
        h.editor.viewportDidResize(to: view)
        let far = h.add(Box(CGRect(x: 3000, y: 2000, width: 100, height: 100)))
        let other = h.add(Box(CGRect(x: -3000, y: -2000, width: 100, height: 100)))
        h.editor.selection = far
        expect(h.key(right))
        h.wait(200)
        // The least pan: its right edge and bottom 40 points in from the view's (its title's row counted above it).
        let there = Camera(origin: CGPoint(x: 2140, y: 1440), zoom: 1)
        expectEqual(h.editor.camera, there, "where it was as the key came")
        expectEqual(h.editor.document[far]?.box?.origin, CGPoint(x: 3001, y: 2000))
        expect(h.key(right))
        h.wait(200)
        expectEqual(h.editor.camera, there, "in view: the camera stays")
        h.editor.selection = other
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document[other], nil)
        h.wait(200)
        expectEqual(h.editor.camera, Camera(origin: CGPoint(x: -3040, y: -2068), zoom: 1), "its top-left 40 points in, with its row above")
    },
    test("a read-only shape in the selection stays, refused, and the rest move") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), FreezingPlugin(log: log)])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let frozen = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.freeze([frozen])
        h.editor.selectedShapeIDs = [a, frozen]
        expect(h.key(right))
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 1, y: 0))
        expectEqual(h.editor.document[frozen]?.box?.origin, CGPoint(x: 200, y: 0))
        expectEqual(log.refusals, [[frozen]], "refused, so a lock shakes")
    },
    test("with nothing selected the arrow keys pan the view a step, the same on screen at any zoom, and ⇧ a page; eased, held, each repeat goes on from where the last was headed") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(h.key(right))
        expectEqual(h.editor.camera.origin, .zero, "eased, not jumped")
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: 50, y: 0), "what's to the right comes into view")
        expect(h.key(down))
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: 50, y: 50))
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        expect(h.key(left))
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: -25, y: 0), "50 points on screen, 25 units at 200%")
        h.editor.camera = Camera()
        expect(h.key(right))
        for _ in 0..<2 { expect(h.key(right, isRepeat: true)) }
        h.wait(16)
        let between = h.editor.camera.origin.x
        expect(between > 0 && between < 150, "on its way: \(between)")
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: 150, y: 0), "held: three steps, gliding on")
        h.editor.camera = Camera()
        h.hold(.shift)
        expect(h.key(up))
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: -560), "a page: 0.8 of the view")
        h.hold([])
        expectEqual(h.editor.undoHistory.undoName, nil, "panning changes no board")
        expectEqual(h.editor.document[box]?.box?.origin, .zero)
        h.editor.selection = box
        expect(h.key(right))
        h.wait(200)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 1, y: 0), "with a selection, they nudge")
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: -560), "and the view stays")
    },
    test("a shape nudged partway across a container's edge goes the rest of the way as the key is let go, the way it went, and settles there, in the nudge's step; never between repeats") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let box = h.add(Box(CGRect(x: 0, y: 150, width: 80, height: 40)))
        h.editor.replaceDocument(with: h.editor.document)          // nothing to undo
        let before = h.editor.document
        h.editor.selection = box
        h.hold(.shift)
        expect(h.key(right))
        for _ in 0..<5 { expect(h.key(right, isRepeat: true)) }
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 60, y: 150), "40 of 80 across the edge")
        expectEqual(h.editor.holder(of: box), nil, "nothing settles while the key is held")
        h.editor.keyUp(KeyStroke(right, modifiers: .shift))
        h.hold([])
        expectEqual(h.editor.holder(of: box), corral, "in, as the key is let go")
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 116, y: 150), "the rest of the way, to the gap inside the edge")
        expect(h.editor.isGliding(box), "gliding there")
        expectEqual(h.editor.undoHistory.undoName, "Move")
        h.editor.undo()
        expectEqual(h.editor.document, before, "the nudges and their settling, one step")
        h.editor.redo()
        // Out again a unit a press, each press its own step: the press that crosses the edge takes it out.
        h.editor.selection = box
        for _ in 0..<16 {
            expect(h.key(left))
            h.editor.keyUp(KeyStroke(left))
        }
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 100, y: 150))
        expectEqual(h.editor.holder(of: box), corral, "at the edge, still in")
        expect(h.key(left))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 99, y: 150), "a unit over")
        h.editor.keysReleased()
        expectEqual(h.editor.holder(of: box), nil, "out, as the key is let go")
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 4, y: 150), "the rest of the way, to the gap outside the edge")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 100, y: 150), "the press that crossed, and its settling, one step")
        expectEqual(h.editor.holder(of: box), corral)
    },
    test("a commit from elsewhere while the key is held settles the nudges first, in their step, and its own change is a step after") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let box = h.add(Box(CGRect(x: 0, y: 150, width: 80, height: 40)))
        h.editor.replaceDocument(with: h.editor.document)          // nothing to undo
        let before = h.editor.document
        h.editor.selection = box
        h.hold(.shift)
        expect(h.key(right))
        for _ in 0..<5 { expect(h.key(right, isRepeat: true)) }
        // `canvas draw`, say: it waits for a press, not for a held key.
        let other = ShapeID()
        h.editor.transact("Draw") { $0.insert(ShapeRecord(id: other, Box(CGRect(x: 0, y: 600, width: 80, height: 40)))) }
        expectEqual(h.editor.holder(of: box), corral, "settled, and not written over by the draw's commit")
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 116, y: 150))
        expect(h.editor.document[other] != nil)
        expectEqual(h.editor.undoHistory.undoName, "Draw")
        h.editor.undo()
        expectEqual(h.editor.document[other], nil)
        expectEqual(h.editor.holder(of: box), corral, "the draw undone alone")
        h.editor.undo()
        expectEqual(h.editor.document, before, "the nudges and their settling, one step")
    },
    test("a shape nudged within a container, or past one without touching it, settles nowhere new") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let inside = h.add(Box(CGRect(x: 150, y: 150, width: 80, height: 40)))
        let outside = h.add(Box(CGRect(x: 0, y: 400, width: 80, height: 40)))
        h.editor.put([inside], in: corral)
        h.editor.selection = inside
        expect(h.key(down))
        h.editor.keysReleased()
        expectEqual(h.editor.document[inside]?.box?.origin, CGPoint(x: 150, y: 151))
        expectEqual(h.editor.holder(of: inside), corral)
        expect(!h.editor.isGliding(inside))
        h.editor.selection = outside
        h.hold(.shift)
        for _ in 0..<20 { expect(h.key(right)) }
        h.editor.keysReleased()
        expectEqual(h.editor.document[outside]?.box?.origin, CGPoint(x: 200, y: 400), "below it, the whole way")
        expectEqual(h.editor.holder(of: outside), nil)
    },
    test("a nudge into a read-only container is refused as the key is let go: back where the nudges began, gliding, and the container shakes") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin(), FreezingPlugin(log: log)])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let box = h.add(Box(CGRect(x: 0, y: 150, width: 80, height: 40)))
        h.editor.freeze([corral])
        h.editor.selection = box
        h.hold(.shift)
        expect(h.key(right))
        for _ in 0..<6 { expect(h.key(right, isRepeat: true)) }
        h.editor.keyUp(KeyStroke(right, modifiers: .shift))
        h.hold([])
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 0, y: 150))
        expectEqual(h.editor.holder(of: box), nil)
        expect(h.editor.isGliding(box))
        expectEqual(log.refusals.last, [corral])
    },
    test("a shape laid out larger than it stores crosses an edge by the frame it is laid out in: one press that takes that frame over the edge takes it out") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin(), StretchesPlugin()])
        let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 300, height: 200)))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 900, y: 900, width: 60, height: 40), width: 80, height: 120))
        // Stored 40 high, laid out 120: its frame's bottom on the corral's, its stored box well inside.
        let stretch = h.add(Stretch(CGRect(x: 150, y: 180, width: 80, height: 40), gauge: gauge))
        h.editor.put([stretch], in: corral)
        h.editor.selection = stretch
        expect(h.key(down))
        h.editor.keysReleased()
        expectEqual(h.editor.holder(of: stretch), nil, "out, by the frame that crossed")
        expectEqual(h.editor.document[stretch]?.box?.origin, CGPoint(x: 150, y: 316), "to the gap below the edge, the frame's top past it")
    },
    test("what a nudged container holds glides with it as it goes the rest of the way into another, and back with it when that one refuses") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CorralsPlugin(), FreezingPlugin(log: log)])
        let big = h.add(Corral(CGRect(x: 300, y: 0, width: 600, height: 600)))
        let small = h.add(Corral(CGRect(x: 0, y: 100, width: 200, height: 150)))
        let inner = h.add(Box(CGRect(x: 20, y: 120, width: 50, height: 40)))
        h.editor.put([inner], in: small)
        h.editor.selection = small
        h.hold(.shift)
        expect(h.key(right))
        for _ in 0..<10 { expect(h.key(right, isRepeat: true)) }
        h.editor.keysReleased()
        h.hold([])
        expectEqual(h.editor.holder(of: small), big)
        expectEqual(h.editor.document[small]?.box?.origin, CGPoint(x: 316, y: 100))
        expectEqual(h.editor.document[inner]?.box?.origin, CGPoint(x: 336, y: 120), "carried")
        expect(h.editor.isGliding(small) && h.editor.isGliding(inner), "both gliding there")
        h.wait(400)
        h.editor.undo()
        h.editor.freeze([big])
        h.editor.selection = small
        h.hold(.shift)
        expect(h.key(right))
        for _ in 0..<10 { expect(h.key(right, isRepeat: true)) }
        h.editor.keysReleased()
        h.hold([])
        expectEqual(log.refusals.last, [big])
        expectEqual(h.editor.document[inner]?.box?.origin, CGPoint(x: 20, y: 120), "back where the nudges began")
        expect(h.editor.isGliding(small) && h.editor.isGliding(inner), "both gliding back")
    },
])
