@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import SlashCommands
import TestKit

// What a shape offers and running a command, headless: the order of commands, `when`, the shapes
// that offer none, and a run's one transaction and one undo step.

private let area = CGRect(x: 0, y: 0, width: 100, height: 60)

@MainActor private func names(_ state: SlashCommandState?, _ id: ShapeID) -> [String] {
    state?.commands(for: id).map(\.name) ?? []
}

/// A shape of `kind` a board keeps aside, as one from a newer version of its kind: read from a
/// board, as nothing else makes one.
@MainActor private func keptAside(_ kind: ShapeKind, id: ShapeID, in registry: Registry) throws -> AnyShapeRecord {
    let json = """
    { "format" : 1, "schema" : { "\(kind.rawValue)" : 99 }, "shapes" : [
      { "id" : "\(id)", "kind" : "\(kind.rawValue)", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] }
    """
    let record = try require(BoardCodec(registry: registry).decode(Data(json.utf8)).document[id])
    expect(record.isOpaque)
    return record
}

/// A box command that changes its shape twice, in two transactions.
private let twice = Contributor(id: "twice") { registrar in
    registrar.slashCommands(Box.self) {
        SlashCommand("twice") { id, _, editor in
            editor.transact { $0.update(id, as: Box.self) { $0.props.frame.size.width += 1 } }
            editor.transact { $0.update(id, as: Box.self) { $0.props.frame.size.height += 1 } }
        }
        SlashCommand("echo", argument: "text") { id, arguments, editor in
            editor.transact { $0.update(id, as: Box.self) { $0.props.frame.size.width = CGFloat(arguments.text.count) } }
        }
    }
}

@MainActor let slashResolutionTests = Suite("Slash command resolution", [
    test("a shape offers its kind's commands in builder order, then those over a property it holds, then every shape's, each only while its `when` holds") {
        let h = try slashHarness([LampsPlugin(), Contributor(id: "every") { registrar in
            registrar.slashCommandsForEveryShape {
                SlashCommand("hello") { _, _, _ in }
                SlashCommand("bye", when: { $0[Flagged.self] == true }) { _, _, _ in }
            }
        }])
        let state = h.editor.slashCommands
        let lamp = h.add(Lamp(area))
        expectEqual(names(state, lamp), ["turn-on", "level", "hello"])
        h.editor.transact { $0.update(lamp, as: Lamp.self) { $0.props.isOn = true } }
        expectEqual(names(state, lamp), ["turn-off", "level", "hello"])
        h.editor.transact { $0.update(lamp) { $0[Flagged.self] = false } }
        expectEqual(names(state, lamp), ["turn-off", "level", "hello"], "a command over a property is offered while `when` holds for its value")
        h.editor.transact { $0.update(lamp) { $0[Flagged.self] = true } }
        expectEqual(names(state, lamp), ["turn-off", "level", "unflag", "hello", "bye"])
        let box = h.add(Box(area))
        expectEqual(names(state, box), ["hello"], "a box holds no flag and offers no lamp's command")
    },

    test("a shape that is gone, isn't on the board shown, or is kept aside offers nothing") {
        let h = try EditorHarness(plugins: slashPlugins([LampsPlugin(), PocketsPlugin()]))
        let state = h.editor.slashCommands
        let lamp = h.add(Lamp(area))
        let pocket = h.add(Pocket(area))
        expectEqual(names(state, lamp), ["turn-on", "level"])
        expect(h.enter(pocket))
        expectEqual(names(state, lamp), [], "on the root, while the pocket's board is shown")
        let inside = h.add(Lamp(area))
        expectEqual(names(state, inside), ["turn-on", "level"])
        expect(h.editor.showBoard(.root))
        expectEqual(names(state, inside), [], "on the pocket's board, while the root is shown")
        h.editor.transact { $0.delete([lamp]) }
        expectEqual(names(state, lamp), [], "deleted")
        let aside = try keptAside(Lamp.kind, id: ShapeID(), in: h.editor.registry)
        h.editor.replaceDocument(with: CanvasDocument(shapes: h.editor.document.shapes + [aside]))
        expectEqual(names(state, aside.id), [], "kept aside")
        expectEqual(state?.run("turn-on", on: aside.id, with: SlashArguments([])), false)
    },

    test("a command is found by its name folded to lowercase, if the shape offers it now") {
        let h = try slashHarness([LampsPlugin()])
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(area))
        expectEqual(state.command(named: "turn-on", for: lamp)?.name, "turn-on")
        expectEqual(state.command(named: "TURN-On", for: lamp)?.name, "turn-on")
        expect(state.command(named: "turn-off", for: lamp) == nil, "not offered while the lamp is off")
        expect(state.command(named: "nonsense", for: lamp) == nil)
        expect(state.command(named: "turn-on", for: ShapeID()) == nil, "no such shape")
    },

    test("a command's title is its name in words, each capitalized: the undo step it makes") {
        let h = try slashHarness([LampsPlugin(), Contributor(id: "words") { registrar in
            registrar.slashCommands(Box.self) {
                SlashCommand("set-caption", argument: "caption") { _, _ in }
                SlashCommand("move-into", argument: "@shape") { _, _, _ in }
                SlashCommand("h2") { _, _ in }
            }
        }])
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(area))
        expectEqual(state.commands(for: box).map(\.title), ["Set Caption", "Move Into", "H2"])
        expectEqual(state.commands(for: box).map(\.argument), ["caption", "@shape", nil])
    },

    test("accepts: no arguments for a command without an argument, something for one with, and a rule of its own replaces that") {
        let h = try slashHarness([CardCommandsPlugin(log: CommandLog()), LampsPlugin()])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area))
        @MainActor func command(_ name: String) throws -> OfferedSlashCommand { try require(state.command(named: name, for: card)) }
        let empty = SlashArguments([])
        let some = SlashArguments("12")
        let pill = SlashArguments([.shape(ShapeID(), label: "Groceries")])
        let grow = try command("grow")
        expect(grow.accepts(empty) && !grow.accepts(some) && !grow.accepts(pill), "none for a command without an argument")
        let width = try command("width")
        expect(!width.accepts(empty) && width.accepts(some) && width.accepts(pill), "something for one with")
        let any = try command("any")
        expect(any.accepts(empty) && any.accepts(some), "its own rule replaces the default entirely")
        let lamp = h.add(Lamp(area))
        let level = try require(state.command(named: "level", for: lamp))
        expect(level.accepts("2") && level.accepts("3") && !level.accepts("4") && !level.accepts(empty) && !level.accepts("two"))
    },

    test("an edit command runs on the shape's live value in one transaction, one undo step named for the command; setting what's there commits nothing") {
        let h = try slashHarness([LampsPlugin()])
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(area, level: 1))
        let revision = h.editor.revision
        expect(state.run("level", on: lamp, with: "3"))
        expectEqual(h.editor.lamp(lamp)?.level, 3)
        expectEqual(h.editor.revision, revision + 1)
        expectEqual(h.editor.undoHistory.undoName, "Level")
        h.editor.undo()
        expectEqual(h.editor.lamp(lamp)?.level, 1)
        h.editor.redo()
        expectEqual(h.editor.lamp(lamp)?.level, 3)
        expectEqual(h.editor.undoHistory.undoName, "Level")

        let before = h.editor.revision
        expect(state.run("level", on: lamp, with: "3"), "accepted, and runs")
        expectEqual(h.editor.revision, before, "it set what the lamp has: nothing committed")
        expectEqual(h.editor.undoHistory.undoName, "Level", "and no step of its own")
        h.editor.undo()
        expectEqual(h.editor.lamp(lamp)?.level, 1, "the undo is the first run's")
    },

    test("an edit command over an added property writes its value; the shape need not be one the command's kind knows") {
        let h = try slashHarness([LampsPlugin()])
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(area))
        h.editor.transact { $0.update(lamp) { $0[Flagged.self] = true } }
        expect(state.run("unflag", on: lamp, with: SlashArguments([])))
        expectEqual(h.editor.document[lamp]?[Flagged.self], false)
        expectEqual(h.editor.undoHistory.undoName, "Unflag")
        expect(!state.run("unflag", on: lamp, with: SlashArguments([])), "no longer offered")
    },

    test("a perform command gets the shape, the arguments and the editor; whatever it commits is one undo step") {
        let log = CommandLog()
        let h = try slashHarness([CardCommandsPlugin(log: log), twice])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area))
        let arguments = SlashArguments([.text("near "), .shape(idG, label: "Groceries")])
        expect(state.run("log", on: card, with: arguments))
        expectEqual(log.runs, ["log near @Groceries"])
        expectEqual(arguments.shapes, [idG])

        let box = h.add(Box(area))
        let revision = h.editor.revision
        expect(state.run("twice", on: box, with: SlashArguments([])))
        expectEqual(h.editor.revision, revision + 2, "two commits")
        expectEqual(h.editor.document[box]?.typed(as: Box.self)?.props.frame.size, CGSize(width: 101, height: 61))
        expectEqual(h.editor.undoHistory.undoName, "Twice")
        h.editor.undo()
        expectEqual(h.editor.document[box]?.typed(as: Box.self)?.props.frame.size, CGSize(width: 100, height: 60), "one step undoes both")
    },

    test("run does nothing and says false for arguments the command doesn't accept, a name the shape doesn't offer, and a shape that's gone") {
        let h = try slashHarness([LampsPlugin(), twice])
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(area))
        let revision = h.editor.revision
        expect(!state.run("level", on: lamp, with: "9"))
        expect(!state.run("level", on: lamp, with: SlashArguments([])))
        expect(!state.run("turn-on", on: lamp, with: "now"), "arguments to a command that takes none")
        expect(!state.run("turn-off", on: lamp, with: SlashArguments([])), "not offered while the lamp is off")
        expect(!state.run("nonsense", on: lamp, with: SlashArguments([])))
        expectEqual(h.editor.revision, revision)
        expectEqual(h.editor.undoHistory.undoName, nil)

        let offered = try require(state.command(named: "turn-on", for: lamp))
        expect(state.run(offered, on: lamp, with: SlashArguments([])))
        expect(state.run(offered, on: lamp, with: SlashArguments([])), "a command found is run as found: `when` isn't asked again")
        expect(!state.run("turn-on", on: lamp, with: SlashArguments([])), "by name it's resolved now, and the lamp no longer offers it")
        expect(!state.run(offered, on: lamp, with: "now"), "its arguments are still checked")
        h.editor.transact { $0.delete([lamp]) }
        expect(!state.run(offered, on: lamp, with: SlashArguments([])), "a shape that's gone")
        expect(!state.run("turn-on", on: lamp, with: SlashArguments([])))
    },
])

private let idG = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
