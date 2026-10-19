@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Observation
import TestKit

// The tool lock (`editor.isToolLocked`, tldraw's `toggle-tool-lock`, Q in the shipped app): while it's
// on, putting a shape down keeps the tool that put it down, where it would go back to the default tool
// (the Hand here, as no plugin claims another). Escape still leaves the tool, and the lock stays on.

@MainActor let toolLockTests = Suite("Tool lock", [
    test("off, a placed shape sends the tool back to the default tool; on, the tool stays and the next press puts another down") {
        let h = try EditorHarness(plugins: [CardsPlugin(), discTools()])
        let disc = ToolID(placing: Disc.kind)
        expect(!h.editor.isToolLocked, "off to begin with")
        h.editor.setTool(disc)
        h.click(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, .hand)
        h.editor.isToolLocked = true
        h.editor.setTool(disc)
        h.click(at: CGPoint(x: 300, y: 100))
        expectEqual(h.editor.currentToolID, disc, "kept")
        h.click(at: CGPoint(x: 500, y: 100))
        expectEqual(h.editor.currentToolID, disc)
        expectEqual(h.editor.document.shapes.count, 3, "one down at each press")
        expectEqual(h.editor.undoHistory.undoName, "Add Disc", "each its own step")
        h.editor.isToolLocked = false
        h.click(at: CGPoint(x: 700, y: 100))
        expectEqual(h.editor.currentToolID, .hand, "unlocked: the next one sends it back")
        expectEqual(h.editor.document.shapes.count, 4)
    },
    test("a tool that edits what it places keeps the tool too: the shape is edited, and the next press, once that ends, puts another down") {
        let h = try EditorHarness(plugins: [CardsPlugin(), discTools()])
        let card = ToolID(placing: Card.kind)
        h.editor.isToolLocked = true
        h.editor.setTool(card)
        h.click(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, card)
        let first = try require(h.editor.document.shapes.first?.id)
        expectEqual(h.editor.editingShapeID, first)
        h.editor.endEditing()
        h.click(at: CGPoint(x: 400, y: 400))
        expectEqual(h.editor.currentToolID, card)
        expectEqual(h.editor.document.shapes.count, 2)
        expectEqual(h.editor.editingShapeID, h.editor.document.shapes.last?.id)
    },
    test("Escape leaves the tool for the default tool and the lock stays on for the next tool; Escape during the placing press takes the shape away and still leaves the lock on") {
        let h = try EditorHarness(plugins: [CardsPlugin(), discTools()])
        let disc = ToolID(placing: Disc.kind)
        h.editor.isToolLocked = true
        h.editor.setTool(disc)
        h.click(at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, disc)
        h.escape()
        expectEqual(h.editor.currentToolID, .hand, "Escape leaves the tool")
        expect(h.editor.isToolLocked, "and the lock stays")
        h.editor.setTool(ToolID(placing: Card.kind))
        h.click(at: CGPoint(x: 400, y: 400))
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind), "locked for the next tool as well")
        h.editor.endEditing()
        h.editor.setTool(disc)
        h.press(at: CGPoint(x: 600, y: 100))
        h.drag(to: CGPoint(x: 640, y: 120))
        h.escape()
        expectEqual(h.editor.currentToolID, disc, "Escape takes the shape that follows the pointer, not the tool")
        expect(h.editor.isToolLocked)
        h.release()
        h.escape()
        expectEqual(h.editor.currentToolID, .hand)
        expect(h.editor.isToolLocked)
    },
    test("it's every way a shape is put down: a placement at a point, or in a rect (the Frame tool's), and a container around shapes") {
        let h = try EditorHarness(plugins: [CorralsPlugin(), discTools()])
        let disc = ToolID(placing: Disc.kind)
        let placement = try require(h.editor.registry.placement(for: Disc.kind))
        h.editor.isToolLocked = true
        h.editor.setTool(disc)
        h.editor.place(placement, at: CGPoint(x: 100, y: 100))
        expectEqual(h.editor.currentToolID, disc)
        h.editor.place(placement, in: CGRect(x: 300, y: 300, width: 80, height: 60))
        expectEqual(h.editor.currentToolID, disc)
        let around = h.editor.document.shapes.map(\.id)
        expect(h.editor.place(ShapeRecord(Corral()), around: around, padding: 20) != nil)
        expectEqual(h.editor.currentToolID, disc, "Create Frame's too")
        h.editor.isToolLocked = false
        h.editor.place(placement, at: CGPoint(x: 700, y: 100))
        expectEqual(h.editor.currentToolID, .hand)
        h.editor.setTool(disc)
        expect(h.editor.place(ShapeRecord(Corral()), around: [try require(h.editor.document.shapes.last?.id)]) != nil)
        expectEqual(h.editor.currentToolID, .hand)
    },
    test("it's observed, so the toolbar shows it as it's turned on and off; and nothing but the lock's own setting changes it: not a tool, a board, or a placement") {
        let h = try EditorHarness(plugins: [discTools(), PocketsPlugin()])
        let changed = Flag()
        withObservationTracking { _ = h.editor.isToolLocked } onChange: { changed.set() }
        h.editor.isToolLocked = true
        expect(changed.isSet)
        let pocket = h.add(Pocket(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.setTool(ToolID(placing: Disc.kind))
        expect(h.enter(pocket))
        expect(h.editor.isToolLocked, "another board")
        expect(h.editor.showBoard(.root))
        h.editor.setTool(.hand)
        h.click(at: CGPoint(x: 400, y: 400))
        expect(h.editor.isToolLocked, "a click with the Hand")
    },
])
