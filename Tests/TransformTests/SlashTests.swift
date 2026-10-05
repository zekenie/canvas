import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit
import Transform

// `/turn-into-pocket`, the command a target brings to the kinds that offer its channel: offered where a
// shape can turn into the kind, one undo step named like the menu item that does the same. Typing one
// is the shipped app's (CompositionTests), where a shape with text offers it.

private let area = CGRect(x: 0, y: 0, width: 100, height: 60)

@MainActor let transformSlashTests = Suite("Turning with a slash command", [
    test("the command is named for the target's id, and offered on the kinds that offer its channel, but the target's own") {
        let h = try transformHarness([boxesTurnIntoDiscs()])
        let state = try require(h.editor.slashCommands)
        let corral = h.add(Corral(area)), pocket = h.add(Pocket(area)), box = h.add(Box(area)), disc = h.add(Disc(area))
        expectEqual(state.commands(for: corral).map(\.name), ["turn-into-pocket"])
        expectEqual(state.commands(for: box).map(\.name), ["turn-into-disc"])
        expectEqual(state.commands(for: pocket).map(\.name), [], "it's what a corral turns into, and offers nothing to turn into")
        expectEqual(state.commands(for: disc).map(\.name), [])
        expectEqual(state.commands(for: corral).first?.argument, nil, "it takes nothing")
        expectEqual(state.commands(for: corral).first?.title, "Turn into Pocket", "the step it makes is named as the menu's item is")
    },

    test("the target's own kind offers none, even if it offers the channel too") {
        let h = try transformHarness([plugin("both") { $0.turnable(into: Corral.self, through: ContainerChannel.self) { _, _ in } }])
        let state = try require(h.editor.slashCommands)
        let corral = h.add(Corral(area))
        expectEqual(state.commands(for: corral).map(\.name), ["turn-into-pocket"], "a corral can't turn into a corral")
    },

    test("running it turns the shape in one step named Turn into Pocket, as the menu's item does; undoing it brings the corral back") {
        let a = ShapeID(), k = ShapeID(), b = ShapeID()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 100, y: 100, width: 300, height: 200)),
                                                                  box(a, x: 120, y: 120, in: k), box(b, x: 600))))
        let state = try require(h.editor.slashCommands)
        let before = h.file
        expect(state.run("turn-into-pocket", on: k, with: SlashArguments([])))
        expectEqual(h.editor.document[k]?.kind, Pocket.kind)
        expectEqual(ids(h.editor.document), [k, b])
        expectEqual(ids(h.contents(of: k)), [a])
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "the corral, and what it held")
        h.editor.redo()
        try expectFile(h, after, "and the pocket")
        expect(!state.run("turn-into-pocket", on: k, with: SlashArguments([])), "a pocket doesn't offer it")
    },

    test("it takes no arguments: with some, it isn't run") {
        let h = try transformHarness()
        let state = try require(h.editor.slashCommands)
        let corral = h.add(Corral(area))
        let before = h.file
        expect(!state.run("turn-into-pocket", on: corral, with: "now"))
        expectEqual(h.file, before)
    },

    test("run on a shape of a kind that offers nothing, or one that's gone, it does nothing") {
        let h = try transformHarness([boxesTurnIntoDiscs()])
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(area))
        expect(!state.run("turn-into-pocket", on: box, with: SlashArguments([])), "a box offers /turn-into-disc, not this")
        expectEqual(h.editor.document[box]?.kind, Box.kind)
        h.editor.transact { $0.delete([box]) }
        expect(!state.run("turn-into-disc", on: box, with: SlashArguments([])), "gone")
    },

    test("a frozen shape offers it, and running it changes nothing and shakes the shape") {
        let log = RefusalLog()
        let h = try transformHarness(log: log)
        let state = try require(h.editor.slashCommands)
        let corral = h.add(Corral(area))
        h.editor.freeze([corral])
        let before = h.file, revision = h.editor.revision
        expectEqual(state.commands(for: corral).map(\.name), ["turn-into-pocket"])
        expect(state.run("turn-into-pocket", on: corral, with: SlashArguments([])), "it ran, and gave up")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [[corral]])
    },
])
