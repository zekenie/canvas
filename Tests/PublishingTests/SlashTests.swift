@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Publishing
import SlashCommands
import TestKit

// `/public` and `/private`, the slash commands Publishing offers on the kinds that can be public:
// `/public` while a shape is private, `/private` while it's public (refused, like the chip, while
// anything stands for it). Typing them is the shipped app's (CompositionTests).

/// The names of what Publishing offers on a shape (Titles' `/title` is on the plaque too).
@MainActor private func ours(_ state: SlashCommandState, _ id: ShapeID) -> [String] {
    state.commands(for: id).map(\.name).filter { $0 == "public" || $0 == "private" }
}

@MainActor let slashTests = Suite("Publishing and slash commands", [
    test("/public is offered on a private shape and /private on a public one, on every kind that can be; never on a seal, a draft or a stand-in") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame)), box = h.add(Box(plaqueFrame))
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame)), holder = h.hold([plaque])
        expectEqual(ours(state, plaque), ["public"])
        expectEqual(ours(state, box), ["public"])
        expectEqual(state.commands(for: plaque).first { $0.name == "public" }?.argument, nil, "they take nothing")
        h.publish(plaque)
        expectEqual(ours(state, plaque), ["private"])
        for id in [seal, draft, holder] { expectEqual(ours(state, id), [], "\(id)") }
    },
    test("running /public makes the shape public in one step, undone as one; /private takes it away") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame))
        expect(state.run("public", on: plaque, with: SlashArguments([])))
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
        let name = h.editor.undoHistory.undoName
        expectEqual(name, "Make Public", "the step a person would call it, as the menu's item")
        expect(!state.run("public", on: plaque, with: SlashArguments([])), "not offered once it's public")
        expect(state.run("private", on: plaque, with: SlashArguments([])))
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil)
        h.editor.undo()
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], true)
        h.editor.undo()
        expectEqual(h.editor.document[plaque]?[PublicProperty.self], nil)
        expect(!state.run("public", on: plaque, with: "now"), "they take no arguments")
    },
    test("/private on a held shape is refused like the chip: nothing written, no step, the shape shakes") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame))
        h.publish(plaque)
        h.hold([plaque])
        let step = h.editor.undoHistory.undoName
        let before = h.editor.document
        expect(state.run("private", on: plaque, with: SlashArguments([])), "the command ran, and committed nothing")
        expectEqual(h.editor.document, before)
        expectEqual(h.editor.undoHistory.undoName, step)
        expectEqual(log.refusals, [[plaque]])
        h.wait(16)
        expect(h.editor.drawingOffset(of: plaque) != .zero, "shaking")
    },
    test("neither is offered on a locked shape: nobody can type in its text") {
        let h = try publishingHarness([FreezingPlugin()])
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame))
        h.editor.freeze([plaque])
        expectEqual(ours(state, plaque), [])
        h.editor.freeze([plaque], false)
        h.publish(plaque)
        h.editor.freeze([plaque])
        expectEqual(ours(state, plaque), [])
    },
])
