@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import SlashCommands
import TestKit

// `/lock`, the slash command Locking offers: on the kinds that can be locked, while the shape isn't,
// one undo step like the menu's Lock. Typing it is the shipped app's (CompositionTests).

@MainActor let lockSlashTests = Suite("Locking and slash commands", [
    test("/lock is offered on every shape that can be locked, while it isn't") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(chipBox))
        let card = h.add(Card(chipBox))
        expectEqual(state.commands(for: box).map(\.name), ["lock"])
        expectEqual(state.commands(for: card).map(\.name), ["lock"])
        expectEqual(state.commands(for: box).first?.argument, nil, "it takes nothing")
        h.editor.lock([box])
        expectEqual(state.commands(for: box).map(\.name), [], "not once it's locked")
        expectEqual(state.commands(for: card).map(\.name), ["lock"])
        h.editor.unlock([box])
        expectEqual(state.commands(for: box).map(\.name), ["lock"], "and again once it's not")
    },

    test("running it locks the shape in one step named Lock, as the menu's item does; undoing it unlocks") {
        let h = try lockingHarness()
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(chipBox))
        expect(state.run("lock", on: box, with: SlashArguments([])))
        expect(h.editor.isLocked(box))
        expectEqual(h.editor.undoHistory.undoName, "Lock")
        h.editor.undo()
        expect(!h.editor.isLocked(box))
        expect(!state.run("lock", on: box, with: "now"), "it takes no arguments")
        expect(!h.editor.isLocked(box))
        h.editor.redo()
        expect(h.editor.isLocked(box))
        expect(!state.run("lock", on: box, with: SlashArguments([])), "a locked shape doesn't offer it")
    },
])
