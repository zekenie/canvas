import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit
import Transform

// `/turn-into-pocket`, the command a target brings to the kinds that offer its channel: offered where a
// shape can turn into the kind, one undo step named like the menu item that does the same. For the shapes
// selected it turns every shape it reaches, together, as the menu's item does: innermost first, all or
// nothing. Typing one is the shipped app's (CompositionTests), where a shape with text offers it.

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

    test("a frozen shape offers none, so none is typed or run: nothing changes, and nothing shakes") {
        let log = RefusalLog()
        let h = try transformHarness(log: log)
        let state = try require(h.editor.slashCommands)
        let corral = h.add(Corral(area))
        expectEqual(state.commands(for: corral).map(\.name), ["turn-into-pocket"])
        h.editor.freeze([corral])
        let before = h.file, revision = h.editor.revision
        expectEqual(state.commands(for: corral).map(\.name), [], "its text can't be edited, so no command could be typed")
        expect(!state.run("turn-into-pocket", on: corral, with: SlashArguments([])), "and by name it isn't found")
        expectEqual(h.file, before)
        expectEqual(h.editor.revision, revision)
        expectEqual(log.refusals, [])
    },

    test("two nested corrals selected, /turn-into-pocket turns both in one step, innermost first: the inner pocket is on the outer one's board, as the menu's item leaves it; undone and redone whole") {
        let z = ShapeID(), o = ShapeID(), a = ShapeID(), i = ShapeID(), b = ShapeID(), c = ShapeID()
        let file = CanvasFile(root: board(box(z, x: 900), corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)), box(a, x: 20, y: 20, in: o),
                                          corral(i, CGRect(x: 100, y: 100, width: 300, height: 200), in: o), box(b, x: 120, y: 120, in: i),
                                          box(c, x: 200, y: 120, in: i)))
        let h = try transformHarness(file: file)
        let state = try require(h.editor.slashCommands)
        let before = h.file
        let found = state.commands(for: .selection([o, i]))
        expectEqual(found.map(\.name), ["turn-into-pocket"])
        let turn = try require(found.first)
        expectEqual(turn.reach, .together, "handed both at once: run one by one it would turn the outer one first")
        expectEqual(turn.shapes, [o, i])
        expect(!turn.isPartial)
        expect(state.run(turn, with: SlashArguments([])))
        expectEqual(ids(h.editor.document), [z, o])
        expectEqual(ids(h.contents(of: o)), [a, i])
        expectEqual(ids(h.contents(of: i)), [b, c])
        expectEqual(h.file.record(o)?.kind, Pocket.kind)
        expectEqual(h.file.record(i)?.kind, Pocket.kind, "the inner one turned too")
        expectEqual(h.file.record(i)?.box, CGRect(x: 100, y: 100, width: pocketSize.width, height: pocketSize.height), "where it was")
        expectEqual(h.file.path(to: BoardID(owner: i)), [.root, BoardID(owner: o), BoardID(owner: i)], "its board went with it")
        expectEqual(h.contents(of: o).shapes.map(\.container), [nil, nil], "the pocket isn't in the pocket it moved onto")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        let after = h.file
        h.editor.undo()
        try expectFile(h, before, "both corrals, and everything in them: one step")
        h.editor.redo()
        try expectFile(h, after, "both pockets")

        // The order they are selected in changes nothing: the deepest turns first.
        for order in [[o, i], [i, o]] {
            let again = try transformHarness(file: file)
            let state = try require(again.editor.slashCommands)
            expect(state.run("turn-into-pocket", for: .selection(order), with: SlashArguments([])), "\(order)")
            expectEqual(ids(again.editor.document), [z, o], "\(order)")
            expectEqual(ids(again.contents(of: o)), [a, i], "\(order)")
            expectEqual(ids(again.contents(of: i)), [b, c], "\(order)")
            expectEqual(again.file.record(i)?.kind, Pocket.kind, "\(order)")
        }
    },

    test("a corral and a box selected list what each turns into, each on its own shape, 1 of 2; /turn-into-pocket turns the corral and leaves the box, /turn-into-disc the box") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID()
        let h = try transformHarness([boxesTurnIntoDiscs()], file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)),
                                                                                           box(a, x: 20, y: 20, in: k), box(b, x: 600))))
        let state = try require(h.editor.slashCommands)
        let before = h.file
        let found = state.commands(for: .selection([k, b]))
        expectEqual(found.map(\.name), ["turn-into-pocket", "turn-into-disc"], "the corral's, then the box's")
        let pocket = try require(found.first { $0.name == "turn-into-pocket" })
        let disc = try require(found.first { $0.name == "turn-into-disc" })
        expectEqual(pocket.shapes, [k])
        expectEqual(disc.shapes, [b])
        for command in found {
            expectEqual(command.targetCount, 2, command.name)
            expect(command.isPartial, command.name)
        }
        expect(state.run(pocket, with: SlashArguments([])))
        expectEqual(h.editor.document[k]?.kind, Pocket.kind)
        expectEqual(h.editor.document[b]?.kind, Box.kind, "the box isn't reached")
        expectEqual(ids(h.contents(of: k)), [a])
        expectEqual(h.editor.undoHistory.undoName, "Turn into Pocket")
        h.editor.undo()
        try expectFile(h, before, "one step")
        expect(state.run(disc, with: SlashArguments([])))
        expectEqual(h.editor.document[b]?.kind, Disc.kind)
        expectEqual(h.editor.document[k]?.kind, Corral.kind, "the corral isn't reached")
        expectEqual(h.editor.undoHistory.undoName, "Turn into Disc")
        expectEqual(state.commands(for: .selection([k, b])).map(\.name), ["turn-into-pocket"], "a disc has nothing to turn into")
        expectEqual(state.commands(for: .selection([k, b])).first?.isPartial, true)
    },

    test("a frozen box inside a selected corral: /turn-into-pocket changes nothing and makes no step, and the box is heard refused; thawed, it turns") {
        let k = ShapeID(), a = ShapeID(), b = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)), box(a, x: 20, y: 20, in: k),
                                                                  box(b, x: 120, y: 20, in: k))), log: log)
        let state = try require(h.editor.slashCommands)
        h.editor.freeze([b])
        let before = h.file, revision = h.editor.revision, step = h.editor.undoHistory.undoName
        let turn = try require(state.command(named: "turn-into-pocket", for: .selection([k])), "the corral itself isn't read-only: it is listed")
        expect(state.run(turn, with: SlashArguments([])), "the command ran, and committed nothing")
        expectEqual(h.file, before, "the corral is a corral, and still holds both")
        expectEqual(h.editor.revision, revision, "nothing committed")
        expectEqual(h.editor.undoHistory.undoName, step, "no step of its own")
        expectEqual(log.refusals, [[b]], "the box in the way, not the corral")
        h.editor.freeze([b], false)
        expect(state.run("turn-into-pocket", for: .selection([k]), with: SlashArguments([])))
        expectEqual(ids(h.contents(of: k)), [a, b])
    },

    test("a frozen box deep in the inner of two nested corrals selected keeps both from turning, though the inner went first: no change, no step, the box heard refused") {
        let o = ShapeID(), i = ShapeID(), b = ShapeID(), c = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(o, CGRect(x: 0, y: 0, width: 600, height: 400)),
                                                                  corral(i, CGRect(x: 100, y: 100, width: 300, height: 200), in: o), box(b, x: 120, y: 120, in: i),
                                                                  box(c, x: 200, y: 120, in: i))), log: log)
        let state = try require(h.editor.slashCommands)
        h.editor.freeze([b])
        let before = h.file, revision = h.editor.revision, step = h.editor.undoHistory.undoName
        expect(state.run("turn-into-pocket", for: .selection([o, i]), with: SlashArguments([])), "the command ran")
        expectEqual(h.file, before, "the inner corral, which turned first in the transaction, is a corral")
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, step)
        expectEqual(log.refusals, [[b]])
        expectEqual(h.editor.holder(of: c), i)
    },

    test("a frozen corral selected with a free one: the frozen one offers nothing to turn, so the free one is the whole reach, 1 of 2, and turns alone") {
        let k = ShapeID(), l = ShapeID(), log = RefusalLog()
        let h = try transformHarness(file: CanvasFile(root: board(corral(k, CGRect(x: 0, y: 0, width: 300, height: 200)),
                                                                  corral(l, CGRect(x: 400, y: 0, width: 300, height: 200)))), log: log)
        let state = try require(h.editor.slashCommands)
        h.editor.freeze([l])
        let turn = try require(state.command(named: "turn-into-pocket", for: .selection([k, l])))
        expectEqual(turn.shapes, [k], "a read-only shape is reached only by a command a plugin declared")
        expect(turn.isPartial)
        expect(state.run(turn, with: SlashArguments([])))
        expectEqual(h.editor.document[k]?.kind, Pocket.kind)
        expectEqual(h.editor.document[l]?.kind, Corral.kind)
        expectEqual(log.refusals, [], "the frozen corral wasn't tried")
    },
])
