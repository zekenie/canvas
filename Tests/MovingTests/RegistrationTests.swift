@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Moving
import SlashCommands
import TestKit

// What Moving registers: two commands for every shape a drag moves, and nothing else.

@MainActor let movingRegistrationTests = Suite("Moving's commands", [
    test("the report: two commands for every shape, and nothing else") {
        let lines = try Registry(plugins: movingPlugins()).report.split(separator: "\n").map(String.init)
        let line = try require(lines.first { $0.hasPrefix("moving ") })
        expectEqual(line.dropFirst("moving".count).drop { $0 == " " }, "/move-to /move-near → every shape")
    },

    test("every kind with a box offers both, in that order; a link and a tag, which have none, offer neither") {
        let h = try movingHarness()
        let state = try require(h.editor.slashCommands)
        let a = h.add(Box(at(0, 0))), b = h.add(Box(at(300, 0)))
        let shapes = [a, b, h.add(Disc(at(600, 0))), h.add(Corral(at(0, 300, 400, 300))), h.add(Pocket(at(600, 300, 240, 160))),
                      h.add(Card(at(1000, 0, 100, 60)))]
        for shape in shapes { expectEqual(state.commands(for: shape).map(\.name), ["move-to", "move-near"], "\(String(describing: h.editor.document[shape]?.kind))") }
        expectEqual(state.commands(for: h.add(Link(from: a, to: b))).map(\.name), [])
        expectEqual(state.commands(for: h.add(Tag(target: a))).map(\.name), [])
    },

    test("each takes one shape: /move-to a frame or subboard, of the kinds that hold shapes or own boards; /move-near any shape; each makes one step called Move") {
        let h = try movingHarness()
        let state = try require(h.editor.slashCommands)
        let a = h.add(Box(at(0, 0)))
        let to = try require(state.command(named: "move-to", for: a)), near = try require(state.command(named: "move-near", for: a))
        expectEqual(to.argument, "@frame or subboard")
        expectEqual(near.argument, "@shape")
        expect(to.takesShape && near.takesShape)
        expectEqual(to.admittedKinds, [Corral.kind, Pocket.kind])
        expectEqual(near.admittedKinds, nil, "any kind")
        expectEqual(to.stepName, "Move", "a drag's name, not \"Move To\"")
        expectEqual(near.stepName, "Move")
        expect(!to.accepts(SlashArguments([])) && !near.accepts("Groceries"), "a shape, and nothing else")
    },

    test("a frozen shape offers neither: its text can't be typed in") {
        let h = try movingHarness()
        let state = try require(h.editor.slashCommands)
        let a = h.add(Box(at(0, 0)))
        h.editor.freeze([a])
        expectEqual(state.commands(for: a).map(\.name), [])
    },

    test("Moving needs slash commands: without them the list is refused") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeSlashCommands", owner: .slashCommands, contributor: "moving")) {
            _ = try Registry(plugins: [FixturesPlugin(), MovingPlugin()])
        }
    },
])
