import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import Keyboard
import Selection
import SlashCommands
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

    test("⇧⌘F is the same command: the frame around the selection, one step named as the item; the item shows the key") {
        let h = try frameHarness()
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let b = h.addBox(CGRect(x: 300, y: 150, width: 100, height: 80))
        h.editor.selectedShapeIDs = [a, b]
        let item = try require(try require(h.secondaryClick(at: CGPoint(x: 150, y: 140))).item(withTitle: "Create Frame"))
        expectEqual(item.keyEquivalent, "f")
        expectEqual(item.keyEquivalentModifierMask, [.shift, .command])
        expectEqual(h.editor.registry.shortcut(forCommand: .createFrame)?.chord, KeyChord("f", [.shift, .command]))
        h.hold([.shift, .command])
        expect(h.key("F"))
        let frame = try require(h.frames.first)
        expectEqual(h.frames.count, 1)
        expectEqual(frame.box, CGRect(x: 68, y: 68, width: 364, height: 194))
        expectEqual(h.editor.holder(of: a), frame.id)
        expectEqual(h.editor.selection, frame.id)
        expectEqual(h.editor.undoHistory.undoName, "Create Frame")
        h.editor.undo()
        expect(h.frames.isEmpty)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
    },

    test("⇧⌘F with nothing selected, or a locked box among the shapes: the key goes on, or leaves it all as it was and shakes") {
        let refusals = RefusalLog()
        let h = try frameHarness(refusals)
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let b = h.addBox(CGRect(x: 300, y: 150, width: 100, height: 80))
        h.hold([.shift, .command])
        h.editor.selection = nil
        expect(!h.key("F"), "nothing selected")
        expect(!h.editor.canPerform(.createFrame))
        h.editor.freeze([b])
        h.editor.selectedShapeIDs = [a, b]
        let steps = h.editor.undoHistory.undoName
        expect(h.key("F"))
        expect(h.frames.isEmpty)
        expectEqual(refusals.refusals, [[b]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        h.hold(.command)
        expect(!h.key("F"), "⌘F alone isn't it (it's Find's)")
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

/// `frameHarness` with `/create-frame` (`FrameSlashPlugin`), which goes with Frames' plugin.
@MainActor private func slashHarness(_ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: framePlugins(refusals) + [FrameSlashPlugin()])
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

// `/create-frame`: Create Frame typed for the shapes selected (the command bar's target, run headlessly
// through `editor.slashCommands`), or on a line of a shape's text.
@MainActor let createFrameSlashTests = Suite("/create-frame", [
    test("for the shapes selected it's Create Frame: an untitled frame 32 past them holds them where they are, selected, one step named as the item, undone") {
        let h = try slashHarness()
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let b = h.addBox(CGRect(x: 300, y: 150, width: 100, height: 80))
        h.editor.selectedShapeIDs = [a, b]
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-frame", for: .selection([a, b])))
        expectEqual(offered.shapes, [a, b], "together: every shape it reaches, once")
        expect(!offered.isPartial)
        expectEqual(offered.argument, nil, "it takes nothing")
        expect(state.run(offered, with: SlashArguments([])))
        let frame = try require(h.frames.first)
        expectEqual(h.frames.count, 1, "one frame around them all")
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
        expectEqual(h.editor.holder(of: b), nil)
    },

    test("on a line of a shape's text it frames that shape; a box offers it alone, and a frame after what its own plugins give it") {
        let h = try slashHarness()
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let sprint = h.addFrame(CGRect(x: 500, y: 100, width: 300, height: 200), title: "Sprint")
        let state = try require(h.editor.slashCommands)
        expectEqual(state.commands(for: a).map(\.name), ["create-frame"])
        expectEqual(state.commands(for: sprint).map(\.name), ["color", "title", "is-a", "create-frame"], "its plugin after the kinds'")
        expect(state.run("create-frame", on: a, with: SlashArguments([])))
        let frame = try require(h.frames.first { $0.id != sprint })
        expectEqual(frame.box, CGRect(x: 68, y: 68, width: 164, height: 144))
        expectEqual(h.editor.holder(of: a), frame.id)
        expect(!state.run("create-frame", on: a, with: SlashArguments([.text("now")])), "it takes no words")
    },

    test("a locked shape among those selected is left out, `1 of 2`, and the frame goes around the rest with nothing shaken; a locked one alone is offered none") {
        let refusals = RefusalLog()
        let h = try slashHarness(refusals)
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let locked = h.addBox(CGRect(x: 300, y: 150, width: 100, height: 80))
        h.editor.freeze([locked])
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-frame", for: .selection([a, locked])))
        expectEqual(offered.shapes, [a])
        expect(offered.isPartial)
        expect(state.run(offered, with: SlashArguments([])))
        let frame = try require(h.frames.first)
        expectEqual(h.editor.holder(of: a), frame.id)
        expectEqual(h.editor.holder(of: locked), nil)
        expectEqual(refusals.refusals, [], "nothing was refused")
        expect(state.command(named: "create-frame", for: .selection([locked])) == nil, "no row that could only be refused")
    },

    test("with nothing selected the bar is for every shape on the board: one frame around them all") {
        let h = try slashHarness()
        let a = h.addBox(CGRect(x: 100, y: 100, width: 100, height: 80))
        let b = h.addBox(CGRect(x: 600, y: 400, width: 100, height: 80))
        let state = try require(h.editor.slashCommands)
        let offered = try require(state.command(named: "create-frame", for: .everything([a, b])))
        expect(!offered.isPartial)
        expect(state.run(offered, with: SlashArguments([])))
        expectEqual(h.frames.count, 1)
        let frame = try require(h.frames.first)
        expectEqual(frame.box, CGRect(x: 68, y: 68, width: 664, height: 444))
        expectEqual(h.editor.holder(of: a), frame.id)
        expectEqual(h.editor.holder(of: b), frame.id)
    },

    test("the report's line: on every shape with a box") {
        let registry = try Registry(plugins: framePlugins() + [FrameSlashPlugin()])
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("frame-slash ") })
        expectEqual(line.split(separator: " ").joined(separator: " "), "frame-slash /create-frame → every shape with a box", "the id's column apart")
    },
])
