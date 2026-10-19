@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit

// How commands are registered: every sugar form, the report, a kind's own command over an
// every-shape one, `where`, and what the registry refuses.

@MainActor private func registry(_ more: [any CanvasPlugin]) throws -> Registry {
    try Registry(plugins: slashPlugins([LampsPlugin()] + more))
}

/// A plugin that offers one command to boxes through the form for another plugin's kind.
private func offering(_ name: String, id: PluginID) -> Contributor {
    Contributor(id: id) { registrar in
        registrar.slashCommands(Box.self) { SlashCommand(name) { _, _ in } }
    }
}

@MainActor let slashRegistrationTests = Suite("Slash command registration", [
    test("every form of the sugar: a kind's own, over an added property, another plugin's for a kind and for a property, and for every shape") {
        let r = try registry([Contributor(id: "bridge") { registrar in
            registrar.slashCommands(Box.self) {
                SlashCommand("flip") { _, _ in }
                SlashCommand("grow") { _, _ in }
            }
            registrar.slashCommands(of: Flagged.self) { SlashCommand("clear-flag") { _, _ in } }
            registrar.slashCommandsForEveryShape { SlashCommand("rename", argument: "name") { _, _ in } }
        }])
        let lines = r.report.split(separator: "\n").map(String.init)
        let lamps = try require(lines.first { $0.hasPrefix("lamps") })
        expect(lamps.hasSuffix("/turn-on /turn-off /level → lamp · /unflag → lamp"), lamps)
        let bridge = try require(lines.first { $0.hasPrefix("bridge") })
        expect(bridge.hasSuffix("/flip /grow → box · /clear-flag → every shape · /rename → every shape"), bridge)
        expectEqual(r.contributions(to: ShapeSlashCommands.self).count, 5)
    },

    test("a command that takes one shape is a command like any other: its line in the report, its name typed as one, its name claimed by its target; the hint is @shape unless it says more") {
        let parking = Contributor(id: "parking") { registrar in
            registrar.slashCommands(Box.self) { SlashCommand("park", argument: "@spot", shapes: { _, _, _ in true }) { _, _, _ in } }
        }
        let r = try registry([CardCommandsPlugin(log: CommandLog()), parking])
        let lines = r.report.split(separator: "\n").map(String.init)
        let cards = try require(lines.first { $0.hasPrefix("card-commands") })
        expect(cards.hasSuffix("/grow /width /log /ping /stack /wide /any → card"), cards)
        let parked = try require(lines.first { $0.hasPrefix("parking") })
        expect(parked.hasSuffix("/park → box"), parked)

        let h = try EditorHarness(plugins: slashPlugins([CardCommandsPlugin(log: CommandLog()), parking]))
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        expectEqual(state.command(named: "stack", for: card)?.argument, "@shape")
        expectEqual(state.command(named: "park", for: box)?.argument, "@spot")

        expectThrows(RegistryError.conflict(point: "ShapeSlashCommands", key: "card /stack", plugins: ["card-commands", "again"])) {
            _ = try registry([CardCommandsPlugin(log: CommandLog()), Contributor(id: "again") { registrar in
                registrar.slashCommands(Card.self) { SlashCommand("stack", shapes: { _, _, _ in true }) { _, _, _ in } }
            }])
        }
        expectThrows(RegistryError.invalid(point: "ShapeSlashCommands", reason: "bad offers /Move To, which can't be typed as a command's name: "
                                           + "lowercase letters and digits, words joined by hyphens")) {
            _ = try registry([Contributor(id: "bad") { registrar in
                registrar.slashCommands(Box.self) { SlashCommand("Move To", shapes: { _, _, _ in true }) { _, _, _ in } }
            }])
        }
    },

    test("an every-shape command goes where `where` lets it: on the kinds that hold an added property") {
        let h = try EditorHarness(plugins: slashPlugins([LampsPlugin(), Contributor(id: "flags") { registrar in
            registrar.slashCommandsForEveryShape(where: { $0.holds(Flagged.self) }) { SlashCommand("flag-all") { _, _, _ in } }
            registrar.slashCommandsForEveryShape(where: { $0.definition is LampDefinition }) { SlashCommand("only-lamps") { _, _, _ in } }
        }]))
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let chore = h.add(Chore(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        expectEqual(state.commands(for: lamp).map(\.name), ["turn-on", "level", "flag-all", "only-lamps"])
        expectEqual(state.commands(for: chore).map(\.name), ["flag-all"])
        expectEqual(state.commands(for: box).map(\.name), [])
    },

    test("a kind's own command takes the place of an every-shape one of the same name; offered or not") {
        let h = try EditorHarness(plugins: slashPlugins([LampsPlugin(), Contributor(id: "every") { registrar in
            registrar.slashCommandsForEveryShape { SlashCommand("level", argument: "n") { _, _, _ in } }
            registrar.slashCommandsForEveryShape { SlashCommand("hello") { _, _, _ in } }
        }]))
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        expectEqual(state.commands(for: lamp).map(\.name), ["turn-on", "level", "hello"])
        expectEqual(state.commands(for: lamp).first { $0.name == "level" }?.argument, "1-3", "the lamp's own")
        expectEqual(state.commands(for: box).map(\.name), ["level", "hello"], "a box takes the every-shape one")
        expectEqual(state.commands(for: box).first { $0.name == "level" }?.argument, "n")
    },

    test("two plugins can't offer one name to a kind, nor to every shape; a builder can't repeat a name; another target's is another command") {
        expectThrows(RegistryError.conflict(point: "ShapeSlashCommands", key: "box /flip", plugins: ["a", "b"])) {
            _ = try registry([offering("flip", id: "a"), offering("flip", id: "b")])
        }
        expectThrows(RegistryError.conflict(point: "ShapeSlashCommands", key: "* /rename", plugins: ["a", "b"])) {
            _ = try registry([Contributor(id: "a") { $0.slashCommandsForEveryShape { SlashCommand("rename") { _, _ in } } },
                              Contributor(id: "b") { $0.slashCommands(of: Flagged.self) { SlashCommand("rename") { _, _ in } } }])
        }
        expectThrows(RegistryError.conflict(point: "ShapeSlashCommands", key: "box /twice", plugins: ["dup", "dup"])) {
            _ = try registry([Contributor(id: "dup") { r in
                r.slashCommands(Box.self) { SlashCommand("twice") { _, _ in }; SlashCommand("twice") { _, _ in } }
            }])
        }
        _ = try registry([offering("flip", id: "a"),
                          Contributor(id: "disc") { $0.slashCommands(Disc.self) { SlashCommand("flip") { _, _ in } } },
                          Contributor(id: "every") { $0.slashCommandsForEveryShape { SlashCommand("flip") { _, _ in } } }])
    },

    test("a name that can't be typed as one refuses the plugin list: lowercase letters, digits and single hyphens between words") {
        for name in ["Flip", "set_title", "set title", "-flip", "flip-", "a--b", "", "flip!", "café", "1/2"] {
            expectThrows(RegistryError.invalid(point: "ShapeSlashCommands", reason: "bad offers /\(name), which can't be typed as a command's name: "
                                               + "lowercase letters and digits, words joined by hyphens")) {
                _ = try registry([offering(name, id: "bad")])
            }
        }
        for name in ["flip", "set-title", "h2", "2d", "a-b-c-1"] {
            _ = try registry([offering(name, id: "good")])
        }
    },

    test("contributing needs SlashCommandsPlugin installed, and a kind that is") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeSlashCommands", owner: .slashCommands, contributor: "lamps")) {
            _ = try Registry(plugins: [FixturesPlugin(), ChoresPlugin(), LampsPlugin()])
        }
        expectThrows(RegistryError.unknownKind(Lamp.kind, point: "ShapeSlashCommands", contributor: "bridge")) {
            _ = try Registry(plugins: [SlashCommandsPlugin(), Contributor(id: "bridge") { $0.slashCommands(Lamp.self) { SlashCommand("x") { _, _ in } } }])
        }
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        expect(h.editor.slashCommands == nil, "no service without the plugin")
    },

    test("the plugin offers nothing of its own, and its service is found by the editor") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), SlashCommandsPlugin()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        expect(h.editor.slashCommands != nil)
        expectEqual(h.editor.slashCommands?.commands(for: box).count, 0)
        expectEqual(try Registry(plugins: [SlashCommandsPlugin()]).report.split(separator: "\n").last.map(String.init),
                    "slash-commands  service SlashCommandState · key hint / at a Line\'s Start Run a Command")
    },
])
