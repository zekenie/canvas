@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection
import TestKit
import Titles

// Create Frame: in the context menu of any shapes a frame can hold, a frame put down around them,
// holding them, 32 past them and never under 96 × 64, in the frame they're all in (the core's
// `place(_:around:)`, which CanvasTests hold with corrals). The camera is at the origin at 100%, so
// view points are world units.

@MainActor let createFrameTests = Suite("Create Frame", [
    test("a selection's menu has Create Frame, in its own band before Delete; chosen, an untitled frame 32 past the boxes holds them where they are, selected, as one step named as the item") {
        let h = try frameHarness()
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let b = h.addBox(CGRect(x: 300, y: 150, width: 100, height: 80))
        h.editor.selectedShapeIDs = [a, b]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 140)))
        expectEqual(menu.outline, ["Create Frame", "—", "Delete"])
        expectEqual(h.editor.selectedShapeIDs, [a, b], "the menu is for the selection")
        try menu.choose("Create Frame")
        let frame = try require(h.frames.first)
        expectEqual(h.frames.count, 1)
        expectEqual(frame.box, CGRect(x: 68, y: 68, width: 364, height: 194))
        expectEqual(frame[TitleProperty.self], nil)
        expectEqual(h.editor.holder(of: a), frame.id)
        expectEqual(h.editor.holder(of: b), frame.id)
        expectEqual(h.editor.box(a), CGRect(x: 100, y: 100, width: 100, height: 80), "where it was")
        expectEqual(h.editor.selection, frame.id)
        expectEqual(h.editor.undoHistory.undoName, "Create Frame")
        h.editor.undo()
        expect(h.frames.isEmpty)
        expectEqual(h.editor.holder(of: a), nil)
    },

    test("chosen in another tool, the default tool comes back, as after placing a frame") {
        let h = try frameHarness()
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        h.editor.selection = a
        h.frameTool()
        try require(h.secondaryClick(at: CGPoint(x: 150, y: 140))).choose("Create Frame")
        expectEqual(h.frames.count, 1)
        expectEqual(h.editor.currentToolID, .select)
    },

    test("never under 96 × 64: a small box gets a frame that size, centered on it") {
        let h = try frameHarness()
        let a = h.addBox(CGRect(x: 200, y: 200, width: 20, height: 10))
        try require(h.secondaryClick(at: CGPoint(x: 210, y: 205))).choose("Create Frame")
        expectEqual(h.frames.first?.box, CGRect(x: 162, y: 168, width: 96, height: 74))
        expectEqual(h.editor.holder(of: a), h.frames.first?.id)
    },

    test("a frame's own menu has it: the new frame holds that frame, and what it holds with it, in the frame they were in") {
        let h = try frameHarness()
        let outer = h.addFrame(CGRect(x: 0, y: 0, width: 900, height: 700))
        let inner = h.addFrame(CGRect(x: 100, y: 100, width: 400, height: 300))
        h.editor.put([inner], in: outer)
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: inner)
        try require(h.secondaryClick(at: CGPoint(x: 300, y: 101))).choose("Create Frame")
        let made = try require(h.editor.selection)
        expect(made != inner && made != outer)
        expectEqual(h.editor.box(made), CGRect(x: 68, y: 68, width: 464, height: 364))
        expectEqual(h.editor.holder(of: made), outer)
        expectEqual(h.editor.holder(of: inner), made)
        expectEqual(h.editor.holder(of: box), inner)
    },

    test("a locked box among them leaves it all as it was, with no step, and it shakes") {
        let refusals = RefusalLog()
        let h = try frameHarness(refusals)
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let b = h.addBox(CGRect(x: 300, y: 150, width: 100, height: 80))
        h.editor.freeze([b])
        h.editor.selectedShapeIDs = [a, b]
        let steps = h.editor.undoHistory.undoName
        let menu = try require(h.secondaryClick(at: CGPoint(x: 150, y: 140)))
        expect(menu.outline.contains("Create Frame"), "the item is there: what stops it is the lock")
        try menu.choose("Create Frame")
        expect(h.frames.isEmpty)
        expectEqual(refusals.refusals, [[b]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },
])
