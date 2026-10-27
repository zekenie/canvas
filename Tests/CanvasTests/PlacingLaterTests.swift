import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Shapes placed later (`editor.placeLater`): records that wait on the core's own tool, drawn faint where
// they'd land, until a press (or Return, `placeAtKeyboard`) puts them all down in one step. The camera is at
// the origin at 100%, so view points are world units. Slabs (ShadowTests') fill orange, so they show.

/// What services heard put down (`EditorService.didPlace`), a call at a time.
@MainActor private final class PlacedCalls {
    var calls: [[ShapeID]] = []
}

extension PlacedCalls: EditorService {
    func didPlace(_ ids: [ShapeID], in editor: CanvasEditor) { calls.append(ids) }
}

/// Three 40 × 30 slabs, each its own record: a column from where they're put down, 10 apart, the first's
/// middle there, or a row with ⌥ held.
@MainActor private func threeSlabs() -> PendingPlacement {
    let records = (0..<3).map { _ in AnyShapeRecord(ShapeRecord(Slab(frame: CGRect(x: 0, y: 0, width: 40, height: 30)))) }
    return PendingPlacement(records, stepName: "Add Slabs") { modifiers in
        (0..<3).map { index in
            let step = CGFloat(index), inRow = modifiers.contains(.option)
            return CGPoint(x: -20 + (inRow ? step * 50 : 0), y: -15 + (inRow ? 0 : step * 40))
        }
    }
}

@MainActor private func placingHarness(_ more: [any CanvasPlugin] = []) throws -> (EditorHarness, PlacedCalls) {
    let calls = PlacedCalls()
    let h = try EditorHarness(plugins: [SlabPlugin(), Contributor(id: "placed") { $0.service { _ in calls } }] + more)
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return (h, calls)
}

/// The boxes of the shapes waiting, in order.
@MainActor private func pendingBoxes(_ h: EditorHarness) -> [CGRect] { h.editor.pendingShapes.compactMap(\.box) }

@MainActor let placingLaterTests = Suite("Placing later", [
    test("shapes placed later wait on the pointer on a tool no toolbar lists, and a click puts them all down there in one step, every one heard placed") {
        let (h, calls) = try placingHarness()
        h.move(to: CGPoint(x: 300, y: 200))
        expect(h.editor.placeLater(threeSlabs()))
        expectEqual(h.editor.currentToolID, .pendingPlacement)
        expect(h.editor.isPlacingLater)
        expect(!h.editor.registry.tools.contains { $0.id == .pendingPlacement }, "the toolbar lists no such tool")
        expectEqual(pendingBoxes(h), [CGRect(x: 280, y: 185, width: 40, height: 30), CGRect(x: 280, y: 225, width: 40, height: 30),
                                      CGRect(x: 280, y: 265, width: 40, height: 30)], "the first's middle on the pointer, the rest below")
        expect(h.editor.document.shapes.isEmpty, "nothing put down while they wait")
        h.move(to: CGPoint(x: 400, y: 100))
        expectEqual(pendingBoxes(h).first, CGRect(x: 380, y: 85, width: 40, height: 30), "they follow the pointer")
        h.click()
        expectEqual(h.editor.document.shapes.compactMap(\.box), [CGRect(x: 380, y: 85, width: 40, height: 30), CGRect(x: 380, y: 125, width: 40, height: 30),
                                                                CGRect(x: 380, y: 165, width: 40, height: 30)], "where they were drawn")
        expectEqual(h.editor.undoHistory.undoName, "Add Slabs")
        expectEqual(calls.calls, [h.editor.document.shapes.map(\.id)], "heard placed once, all together")
        expectEqual(h.editor.currentToolID, .hand, "the default tool back")
        expect(!h.editor.isPlacingLater)
        expect(h.editor.pendingShapes.isEmpty)
        h.editor.undo()
        expect(h.editor.document.shapes.isEmpty, "one step takes them all back")
    },
    test("⌥ held lays them out as the placement says (a row here), and the click puts them down as they're drawn then") {
        let (h, _) = try placingHarness()
        h.move(to: CGPoint(x: 300, y: 200))
        h.editor.placeLater(threeSlabs())
        h.hold(.option)
        expectEqual(pendingBoxes(h), [CGRect(x: 280, y: 185, width: 40, height: 30), CGRect(x: 330, y: 185, width: 40, height: 30),
                                      CGRect(x: 380, y: 185, width: 40, height: 30)])
        h.hold([])
        expectEqual(pendingBoxes(h)[1], CGRect(x: 280, y: 225, width: 40, height: 30), "let go: the column again")
        h.hold(.option)
        h.click()
        expectEqual(h.editor.document.shapes.compactMap(\.box).map(\.minY), [185, 185, 185], "put down in the row")
    },
    test("Return puts them where they're drawn: at the pointer, or with the pointer off the canvas, their bounds in the middle of the view") {
        let (h, _) = try placingHarness()
        expect(!h.editor.isPointerOverCanvas)
        h.editor.placeLater(threeSlabs())
        // The column is 40 wide and 110 tall: its middle at the view's, (400, 300).
        expectEqual(pendingBoxes(h).first, CGRect(x: 380, y: 245, width: 40, height: 30))
        expect(h.editor.placeAtKeyboard())
        expectEqual(h.editor.document.shapes.compactMap(\.box).first, CGRect(x: 380, y: 245, width: 40, height: 30))
        expectEqual(h.editor.undoHistory.undoName, "Add Slabs")
        expectEqual(h.editor.currentToolID, .hand)
        h.move(to: CGPoint(x: 100, y: 100))
        h.editor.placeLater(threeSlabs())
        expect(h.editor.placeAtKeyboard())
        expectEqual(h.editor.document.shapes.compactMap(\.box)[3], CGRect(x: 80, y: 85, width: 40, height: 30), "at the pointer, as a click")
        expect(!h.editor.placeAtKeyboard(), "nothing waits, and the Hand places nothing")
    },
    test("a press and a drag: they follow the pointer while it lasts, as one placed shape does, and settle at the release; Escape mid-press takes them all away") {
        let (h, _) = try placingHarness()
        h.move(to: CGPoint(x: 300, y: 200))
        h.editor.placeLater(threeSlabs())
        h.press()
        expectEqual(h.editor.document.shapes.count, 3, "down at the press")
        h.drag(to: CGPoint(x: 340, y: 260))
        h.release()
        expectEqual(h.editor.document.shapes.compactMap(\.box).first, CGRect(x: 320, y: 245, width: 40, height: 30), "where the release left them")
        expectEqual(h.editor.undoHistory.undoName, "Add Slabs")
        h.editor.placeLater(threeSlabs())
        h.press(at: CGPoint(x: 500, y: 200))
        h.drag(to: CGPoint(x: 540, y: 220))
        h.escape()
        h.release()
        expectEqual(h.editor.document.shapes.count, 3, "Escape took the three of the press away")
    },
    test("Escape, another tool, another board and editing let them go, nothing placed") {
        let (h, _) = try placingHarness([CardsPlugin(), PocketsPlugin()])
        let pocket = h.add(Pocket(CGRect(x: 600, y: 400, width: 80, height: 60)))
        let card = h.add(Card(CGRect(x: 600, y: 100, width: 100, height: 60)))
        h.move(to: CGPoint(x: 300, y: 200))
        h.editor.placeLater(threeSlabs())
        h.escape()
        expect(!h.editor.isPlacingLater && h.editor.currentToolID == .hand && h.editor.pendingShapes.isEmpty, "Escape")
        h.editor.placeLater(threeSlabs())
        h.editor.setTool(ToolID(placing: Card.kind))
        expect(!h.editor.isPlacingLater, "another tool")
        h.editor.placeLater(threeSlabs())
        expect(h.editor.beginEditing(card))
        expect(!h.editor.isPlacingLater, "editing")
        h.editor.endEditing()
        h.editor.placeLater(threeSlabs())
        expect(h.enter(pocket))
        expect(!h.editor.isPlacingLater, "another board")
        expectEqual(h.editor.file[.root].shapes.count, 2, "nothing placed")
    },
    test("into a corral: put down over one they settle in it; a read-only one refuses at Return, and they still wait") {
        let refusals = RefusalLog()
        let (h, _) = try placingHarness([CorralsPlugin(), FreezingPlugin(log: refusals)])
        let corral = h.add(Corral(CGRect(x: 200, y: 100, width: 300, height: 300)))
        var locked = ShapeRecord(Corral(CGRect(x: 600, y: 100, width: 150, height: 300)))
        locked[Frozen.self] = true
        h.editor.transact { $0.insert(AnyShapeRecord(locked)) }
        h.move(to: CGPoint(x: 300, y: 200))
        h.editor.placeLater(threeSlabs())
        expect(h.editor.placeAtKeyboard())
        expectEqual(h.editor.document.shapes.filter { $0.container == corral }.count, 3, "in the corral")
        h.editor.placeLater(threeSlabs())
        h.move(to: CGPoint(x: 675, y: 200))
        expect(!h.editor.placeAtKeyboard(), "refused")
        expectEqual(h.editor.document.shapes.count, 5, "nothing more placed")
        expect(h.editor.isPlacingLater, "they still wait, to be put down elsewhere")
        expectEqual(refusals.refusals.last, [locked.id])
    },
    test("nothing waits for no records, during a press, or on a board that can't change") {
        let (h, _) = try placingHarness([FreezingPlugin(), PocketsPlugin()])
        expect(!h.editor.placeLater(PendingPlacement([], stepName: "Add Nothing") { _ in [] }))
        h.editor.session = OutlineHidingSession()
        expect(!h.editor.placeLater(threeSlabs()), "a press under way")
        h.editor.session = nil
        var pocket = ShapeRecord(Pocket(CGRect(x: 600, y: 400, width: 80, height: 60)))
        pocket[Frozen.self] = true
        h.editor.transact { $0.insert(AnyShapeRecord(pocket)) }
        expect(h.enter(pocket.id))
        expect(!h.editor.isToolEnabled(.pendingPlacement))
        expect(!h.editor.placeLater(threeSlabs()), "a board that can't change")
    },
    test("drawn faint over the board where they'd land, and gone once put down, when they're drawn as themselves") {
        let (h, _) = try placingHarness()
        let size = CGSize(width: 800, height: 600)
        let ground = pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 300, y: 200))
        h.move(to: CGPoint(x: 300, y: 200))
        h.editor.placeLater(threeSlabs())
        let faint = pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 300, y: 200))
        h.click()
        let solid = pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 300, y: 200))
        expect(faint != ground, "drawn while it waits: \(faint) over \(ground)")
        expect(faint != solid, "but not as it is once put down: \(faint) against \(solid)")
        // Orange at 45% over the light canvas: its blue nearer the ground's than the slab's.
        expect(abs(faint[2] - ground[2]) < abs(solid[2] - ground[2]), "faint: \(faint), \(solid), \(ground)")
    },
])
