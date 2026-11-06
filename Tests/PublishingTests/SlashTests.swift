@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Publishing
import SlashCommands
import TestKit

// `/public` and `/private`, the slash commands Publishing offers on the kinds that can be private:
// `/private` while a shape is public, as every shape starts (refused while anything stands for it),
// `/public` while it's private. For the shapes selected each reaches exactly the shapes it would
// change. Typing them is the shipped app's (CompositionTests).

/// The names of what Publishing offers on a shape.
@MainActor private func ours(_ state: SlashCommandState, _ id: ShapeID) -> [String] {
    state.commands(for: id).map(\.name).filter { $0 == "public" || $0 == "private" }
}

/// What Publishing offers for the shapes selected.
@MainActor private func ours(_ state: SlashCommandState, selecting ids: [ShapeID]) -> [OfferedSlashCommand] {
    state.commands(for: .selection(ids)).filter { $0.name == "public" || $0.name == "private" }
}

@MainActor let slashTests = Suite("Publishing and slash commands", [
    test("/private is offered on a public shape, as every shape starts, and /public on a private one, on every kind that can be; never on a seal, a draft or a stand-in") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame)), box = h.add(Box(plaqueFrame))
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame)), holder = h.hold([seal])
        expectEqual(ours(state, plaque), ["private"])
        expectEqual(ours(state, box), ["private"])
        expectEqual(state.commands(for: plaque).first { $0.name == "private" }?.argument, nil, "they take nothing")
        h.conceal(plaque)
        expectEqual(ours(state, plaque), ["public"])
        for id in [seal, draft, holder] { expectEqual(ours(state, id), [], "\(id)") }
    },
    test("running /private makes the shape private in one step, undone as one; /public takes it away") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame))
        expect(state.run("private", on: plaque, with: SlashArguments([])))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        let name = h.editor.undoHistory.undoName
        expectEqual(name, "Make Private", "the step a person would call it, as the menu's item")
        expect(!state.run("private", on: plaque, with: SlashArguments([])), "not offered once it's private")
        expect(state.run("public", on: plaque, with: SlashArguments([])))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        h.editor.undo()
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        h.editor.undo()
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        expect(!state.run("private", on: plaque, with: "now"), "they take no arguments")
    },
    test("/private on a held shape is refused like the chip: nothing written, no step, the shape shakes") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame))
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
        h.conceal(plaque)
        h.editor.freeze([plaque])
        expectEqual(ours(state, plaque), [])
    },
    test("a public and a private plaque selected: /public and /private are each listed on the one they change, 1 of 2, in the first shape's order") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let open = h.add(Plaque(plaqueFrame)), closed = h.add(Plaque(plaqueFrame.offsetBy(dx: 300, dy: 0)))
        h.conceal(closed)
        let found = ours(state, selecting: [open, closed])
        expectEqual(found.map(\.name), ["private", "public"], "the public plaque's first")
        let makePrivate = try require(found.first { $0.name == "private" })
        let makePublic = try require(found.first { $0.name == "public" })
        expectEqual(makePrivate.shapes, [open])
        expectEqual(makePublic.shapes, [closed])
        for command in found {
            expectEqual(command.targetCount, 2, command.name)
            expect(command.isPartial, command.name)
            expectEqual(command.reach, .together, command.name)
            expectEqual(command.argument, nil, "\(command.name) takes nothing")
        }
        expectEqual(ours(state, selecting: [closed, open]).map(\.name), ["public", "private"])
        expectEqual(ours(state, selecting: [closed]).map(\.name), ["public"])
        expectEqual(ours(state, selecting: [open]).map(\.name), ["private"])
        expectEqual(ours(state, selecting: [closed]).first?.isPartial, false, "one shape, all of its target")
    },
    test("run for a public and a private plaque, each changes the one it reaches and leaves the other, in one step named as the command is") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let open = h.add(Plaque(plaqueFrame)), closed = h.add(Plaque(plaqueFrame.offsetBy(dx: 300, dy: 0)))
        h.conceal(closed)
        let target = SlashTarget.selection([open, closed])
        expect(state.run("public", for: target, with: SlashArguments([])))
        expectEqual(h.editor.document[open]?[PrivateProperty.self], nil)
        expectEqual(h.editor.document[closed]?[PrivateProperty.self], nil)
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.editor.undo()
        expectEqual(h.editor.document[closed]?[PrivateProperty.self], true, "one step undone whole")
        expectEqual(h.editor.document[open]?[PrivateProperty.self], nil, "the public one was not reached")
        expectEqual(ours(state, selecting: [open, closed]).map(\.name), ["private", "public"], "as it was")
        expect(state.run("private", for: target, with: SlashArguments([])))
        expectEqual(h.editor.document[open]?[PrivateProperty.self], true)
        expectEqual(h.editor.document[closed]?[PrivateProperty.self], true, "the private one was not reached")
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        h.editor.undo()
        expectEqual(h.editor.document[open]?[PrivateProperty.self], nil)
        expect(!state.run("public", for: target, with: "now"), "they take no arguments")
    },
    test("on shapes alike /private or /public reaches every one: three plaques made private in one step, then public in one") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let plaques = (0..<3).map { h.add(Plaque(plaqueFrame.offsetBy(dx: CGFloat($0) * 300, dy: 0))) }
        let target = SlashTarget.selection(plaques)
        expectEqual(ours(state, selecting: plaques).map(\.name), ["private"])
        expectEqual(ours(state, selecting: plaques).first?.shapes, plaques)
        expectEqual(ours(state, selecting: plaques).first?.isPartial, false)
        expect(state.run("private", for: target, with: SlashArguments([])))
        expect(plaques.allSatisfy { h.editor.document[$0]?[PrivateProperty.self] == true })
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        expectEqual(ours(state, selecting: plaques).map(\.name), ["public"])
        expect(state.run("public", for: target, with: SlashArguments([])))
        expect(plaques.allSatisfy { h.editor.document[$0]?[PrivateProperty.self] == nil })
        expectEqual(h.editor.undoHistory.undoName, "Make Public")
        h.editor.undo()
        expect(plaques.allSatisfy { h.editor.document[$0]?[PrivateProperty.self] == true }, "all three at once")
    },
    test("/private on a selection with a held public plaque and a free one: the held one shakes and nothing is written for it, the free one goes private, in one step") {
        let log = RefusalLog()
        let h = try publishingHarness([FreezingPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let held = h.add(Plaque(plaqueFrame)), free = h.add(Plaque(plaqueFrame.offsetBy(dx: 300, dy: 0)))
        h.hold([held])
        let makePrivate = try require(state.command(named: "private", for: .selection([held, free])))
        expectEqual(makePrivate.shapes, [held, free], "both are public: the held one is tried, as the chip's click is")
        expect(!makePrivate.isPartial)
        expect(state.run(makePrivate, with: SlashArguments([])), "the command ran")
        expectEqual(h.editor.document[held]?[PrivateProperty.self], nil, "nothing is written for the held one")
        expectEqual(h.editor.document[free]?[PrivateProperty.self], true, "the free one went private")
        expectEqual(log.refusals, [[held]], "the held one alone was refused")
        expectEqual(h.editor.undoHistory.undoName, "Make Private")
        h.wait(16)
        expect(h.editor.drawingOffset(of: held) != .zero, "the held one shakes")
        expectEqual(h.editor.drawingOffset(of: free), .zero, "and the free one doesn't")
        h.editor.undo()
        expectEqual(h.editor.document[free]?[PrivateProperty.self], nil, "one step: undone whole")
        expectEqual(h.editor.document[held]?[PrivateProperty.self], nil)
    },
    test("a locked plaque in the selection is reached by neither command, not even as a try; the rest are") {
        let h = try publishingHarness([FreezingPlugin()])
        let state = try require(h.editor.slashCommands)
        let frozenOpen = h.add(Plaque(plaqueFrame)), frozenClosed = h.add(Plaque(plaqueFrame.offsetBy(dx: 300, dy: 0)))
        let open = h.add(Plaque(plaqueFrame.offsetBy(dx: 600, dy: 0))), closed = h.add(Plaque(plaqueFrame.offsetBy(dx: 900, dy: 0)))
        h.conceal(frozenClosed, closed)
        h.editor.freeze([frozenOpen, frozenClosed])
        let found = ours(state, selecting: [frozenOpen, frozenClosed, open, closed])
        expectEqual(found.map(\.name), ["private", "public"])
        expectEqual(found.first { $0.name == "private" }?.shapes, [open], "/private is a try, and a locked public plaque's rule can't act: not offered")
        expectEqual(found.first { $0.name == "public" }?.shapes, [closed])
        expectEqual(ours(state, selecting: [frozenOpen, frozenClosed]).map(\.name), [], "a selection of only locked plaques offers neither")
    },
    test("a seal, a draft and a stand-in are reached by neither command: only the plaques in a mixed selection are") {
        let h = try publishingHarness()
        let state = try require(h.editor.slashCommands)
        let plaque = h.add(Plaque(plaqueFrame)), seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame))
        let holder = h.hold([seal])
        let found = ours(state, selecting: [seal, draft, holder, plaque])
        expectEqual(found.map(\.name), ["private"])
        expectEqual(found.first?.shapes, [plaque])
        expectEqual(found.first?.targetCount, 4)
        expectEqual(found.first?.isPartial, true)
        expect(state.run("private", for: .selection([seal, draft, holder, plaque]), with: SlashArguments([])))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        expectEqual(h.editor.document[draft]?[PrivateProperty.self], nil)
        expectEqual(h.editor.document[seal]?[PrivateProperty.self], nil)
    },
])
