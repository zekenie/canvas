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

/// What's typed after a command's name when it's one shape, named as its pill shows it.
private func shape(_ id: ShapeID, _ label: String = "Shape") -> SlashArguments { SlashArguments([.shape(id, label: label)]) }

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
            registrar.forEveryShape {
                $0.slashCommands {
                    SlashCommand("hello") { _, _, _ in }
                    SlashCommand("bye", when: { $0[Flagged.self] == true }) { _, _, _ in }
                }
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

    test("a read-only shape offers nothing, and it's offered again once it can change") {
        let log = RefusalLog()
        let h = try slashHarness([LampsPlugin(), FreezingPlugin(log: log)])
        let state = h.editor.slashCommands
        let lamp = h.add(Lamp(area))
        expectEqual(names(state, lamp), ["turn-on", "level"])
        h.editor.freeze([lamp])
        expectEqual(names(state, lamp), [], "frozen: its text can't be edited, so no command could be typed")
        expectEqual(state?.run("turn-on", on: lamp, with: SlashArguments([])), false, "nor run")
        h.editor.freeze([lamp], false)
        expectEqual(names(state, lamp), ["turn-on", "level"])
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

    test("a command's title is its name in title case, as a menu has it: every word capitalized but the articles, conjunctions and short prepositions, unless first or last; the undo step it makes") {
        let h = try slashHarness([LampsPlugin(), Contributor(id: "words") { registrar in
            registrar.slashCommands(Box.self) {
                SlashCommand("set-caption", argument: "caption") { _, _ in }
                SlashCommand("move-to-back") { box, _ in box.frame.origin.x += 1 }
                SlashCommand("turn-into-subboard") { _, _ in }
                SlashCommand("bring-the-box-to-the-front") { _, _ in }
                SlashCommand("move-into", argument: "@shape") { _, _, _ in }
                SlashCommand("on-top") { _, _ in }
                SlashCommand("h2") { _, _ in }
            }
        }])
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(area))
        expectEqual(state.commands(for: box).map(\.title), ["Set Caption", "Move to Back", "Turn into Subboard", "Bring the Box to the Front",
                                                            "Move Into", "On Top", "H2"])
        expectEqual(state.commands(for: box).map(\.argument), ["caption", nil, nil, nil, "@shape", nil, nil])
        expect(state.run("move-to-back", on: box, with: SlashArguments([])))
        expectEqual(h.editor.undoHistory.undoName, "Move to Back")
    },

    test("`step:` names the undo step otherwise, for an edit command and a perform one; without it the title does") {
        let h = try slashHarness([Contributor(id: "steps") { registrar in
            registrar.slashCommands(Box.self) {
                SlashCommand("widen", step: "Make Wider") { id, _, editor in
                    editor.transact { $0.update(id, as: Box.self) { $0.props.frame.size.width += 1 } }
                }
                SlashCommand("heighten", step: "Make Taller") { box, _ in box.frame.size.height += 1 }
                SlashCommand("shrink") { box, _ in box.frame.size.height -= 1 }
            }
        }])
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(area))
        expectEqual(state.commands(for: box).map(\.title), ["Widen", "Heighten", "Shrink"], "the title stays the name in words")
        expectEqual(state.commands(for: box).map(\.stepName), ["Make Wider", "Make Taller", "Shrink"])
        expect(state.run("widen", on: box, with: SlashArguments([])))
        expectEqual(h.editor.undoHistory.undoName, "Make Wider")
        expect(state.run("heighten", on: box, with: SlashArguments([])))
        expectEqual(h.editor.undoHistory.undoName, "Make Taller")
        expect(state.run("shrink", on: box, with: SlashArguments([])))
        expectEqual(h.editor.undoHistory.undoName, "Shrink")
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

    test("a command that takes one shape accepts exactly one shape its rule admits and nothing else; the rule is asked with that shape, the shape the line is on and the editor") {
        let log = CommandLog()
        let h = try slashHarness([CardCommandsPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area))
        let moon = h.add(Disc(area)), sun = h.add(Disc(area)), crate = h.add(Box(area))
        let stack = try require(state.command(named: "stack", for: card))
        expect(stack.accepts(shape(moon, "Moon")), "one disc")
        expectEqual(log.asked, [CommandLog.Asked(target: moon, owner: card, editor: ObjectIdentifier(h.editor))],
                    "asked with the shape, the shape the line is on and the editor")
        let refused: [(String, SlashArguments)] = [
            ("nothing", SlashArguments([])),
            ("text", "moon"),
            ("text and a shape", SlashArguments([.text("near "), .shape(moon, label: "Moon")])),
            ("a shape and text", SlashArguments([.shape(moon, label: "Moon"), .text(" please")])),
            ("two shapes", SlashArguments([.shape(moon, label: "Moon"), .text(" "), .shape(sun, label: "Sun")])),
            ("two shapes with nothing between", SlashArguments([.shape(moon, label: "Moon"), .shape(sun, label: "Sun")])),
            ("one shape twice", SlashArguments([.shape(moon, label: "Moon"), .text(" "), .shape(moon, label: "Moon")])),
            ("a shape its rule doesn't admit", shape(crate, "Crate")),
            ("a shape that isn't there", shape(ShapeID(), "Nothing")),
        ]
        for (what, arguments) in refused {
            expect(!stack.accepts(arguments), "\(what): not accepted")
            expect(!state.run(stack, on: card, with: arguments), "\(what): not run")
            expect(!state.run("stack", on: card, with: arguments), "\(what): not run by name")
        }
        expectEqual(log.runs, [], "none of them ran")
        let revision = h.editor.revision
        expect(state.run(stack, on: card, with: shape(moon, "Moon")))
        expect(state.run("STACK", on: card, with: shape(sun, "Sun")), "by name, folded")
        expectEqual(log.runs, ["stack @Moon", "stack @Sun"], "it's given what was typed: its one shape")
        expectEqual(h.editor.revision, revision, "a command that commits nothing")
        h.editor.transact { $0.delete([sun]) }
        expect(!state.run(stack, on: card, with: shape(sun, "Sun")), "a shape that's gone is no disc")
        expectEqual(log.runs.count, 2)
    },

    test("a command that names kinds takes only shapes of those, whatever its rule says: the rule is asked of those alone, and the kinds of the registry once") {
        let log = CommandLog()
        let h = try slashHarness([ParkCommandPlugin(log: log), CorralsPlugin(), PocketsPlugin()])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area)), other = h.add(Card(area))
        let pen = h.add(Corral(area)), pouch = h.add(Pocket(area)), crate = h.add(Box(area)), moon = h.add(Disc(area))
        let park = try require(state.command(named: "park", for: card))
        expectEqual(park.admittedKinds, [Corral.kind, Pocket.kind], "the kinds that hold shapes or own boards, as the registry says")
        expect(park.takesShape)
        expect(park.admits(pen) && park.admits(pouch))
        expect(!park.admits(crate) && !park.admits(moon) && !park.admits(other) && !park.admits(card) && !park.admits(ShapeID()),
               "a box, a disc and another card are shapes the rule alone would admit")
        expectEqual(Set(log.asked.map(\.target)), [pen, pouch], "the rule is asked of shapes of those kinds alone")
        expect(log.asked.allSatisfy { $0.owner == card && $0.editor == ObjectIdentifier(h.editor) })

        expect(park.accepts(shape(pen, "Pen")) && park.accepts(shape(pouch, "Pouch")))
        for (what, refused) in [("a box", crate), ("a disc", moon), ("another card", other), ("the card itself", card), ("a shape that isn't there", ShapeID())] {
            expect(!park.accepts(shape(refused)), "\(what): not accepted")
            expect(!state.run(park, on: card, with: shape(refused)), "\(what): not run")
        }
        expect(!park.accepts(SlashArguments([.shape(pen, label: "Pen"), .text(" and"), .shape(pouch, label: "Pouch")])), "still exactly one shape")
        expectEqual(log.runs, [])
        expect(state.run("park", on: card, with: shape(pouch, "Pouch")))
        expectEqual(log.runs, ["park @Pouch"])
        for _ in 0..<5 { _ = state.commands(for: card) }
        expectEqual(log.kindsAsked, 1, "the registry is frozen: its kinds are asked once, for every shape that finds the command")
        expectEqual(try require(state.command(named: "park", for: other)).admittedKinds, park.admittedKinds)
    },

    test("kinds are read through the file: a shape on another board is of the kinds if its record says so, one that isn't there never is") {
        let log = CommandLog()
        let h = try slashHarness([ParkCommandPlugin(log: log), CorralsPlugin(), PocketsPlugin()])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area)), pouch = h.add(Pocket(area))
        expect(h.enter(pouch))
        let inner = h.add(Corral(area)), crate = h.add(Box(area))
        expect(h.editor.showBoard(.root))
        let park = try require(state.command(named: "park", for: card))
        expect(park.admits(inner), "a corral on the pocket's board, which the card isn't on")
        expect(!park.admits(crate), "a box there")
        expect(park.accepts(shape(inner, "Inner")))
        h.editor.transact { $0.delete([pouch]) }
        let after = try require(state.command(named: "park", for: card))
        expect(!after.admits(inner), "its board went with its owner: the shape is in no board the file can show")
    },

    test("an offered command says whether it takes a shape, and which: a command that takes none admits none") {
        let h = try slashHarness([CardCommandsPlugin(log: CommandLog())])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area))
        let moon = h.add(Disc(area)), crate = h.add(Box(area))
        let stack = try require(state.command(named: "stack", for: card))
        expect(stack.takesShape)
        expect(stack.admits(moon) && !stack.admits(crate) && !stack.admits(card) && !stack.admits(ShapeID()))
        for name in ["grow", "width", "log", "ping", "any"] {
            let command = try require(state.command(named: name, for: card), name)
            expect(!command.takesShape, name)
            expect(!command.admits(moon) && !command.admits(crate), "\(name) takes no shape, so it admits none, a disc included")
        }
        let anything = try require(state.command(named: "log", for: card))
        expect(anything.accepts(shape(crate)), "a command that takes anything is given a pill too: it has no rule for shapes")
    },

    test("the rule is asked with the shape its command was found for, so two shapes find it as each their own") {
        let h = try slashHarness([Contributor(id: "beside") { registrar in
            registrar.slashCommands(Card.self) {
                SlashCommand("beside", shapes: { target, owner, _ in target != owner }) { _, _, _ in }
            }
        }])
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area)), b = h.add(Card(area))
        let forA = try require(state.command(named: "beside", for: a)), forB = try require(state.command(named: "beside", for: b))
        expect(!forA.admits(a) && forA.admits(b), "for the first, anything but itself")
        expect(forB.admits(a) && !forB.admits(b), "and for the second")
        expect(forA.accepts(shape(b)) && !forA.accepts(shape(a)))
        expect(forB.accepts(shape(a)) && !forB.accepts(shape(b)))
    },

    test("an offered command holds its editor weakly: kept after the editor is gone, it admits nothing and accepts no shape") {
        var kept: OfferedSlashCommand?
        weak var editor: CanvasEditor?
        var moon = ShapeID()
        do {
            let h = try slashHarness([CardCommandsPlugin(log: CommandLog())])
            editor = h.editor
            let card = h.add(Card(area))
            moon = h.add(Disc(area))
            kept = h.editor.slashCommands?.command(named: "stack", for: card)
            expectEqual(kept?.admits(moon), true, "while the editor is there")
        }
        expect(editor == nil, "the command keeps no editor alive")
        expectEqual(kept?.takesShape, true)
        expectEqual(kept?.admits(moon), false)
        expectEqual(kept?.accepts(shape(moon)), false)
    },

    test("a command that takes one shape is offered `when` its shape says so, and names its step as the other forms do") {
        let h = try slashHarness([Contributor(id: "tidy") { registrar in
            registrar.slashCommands(Card.self) {
                SlashCommand("tidy-up", when: { $0.frame.width >= 110 }, shapes: { _, _, _ in true }, step: "Tidy") { id, _, editor in
                    editor.transact { $0.update(id, as: Card.self) { $0.props.frame.size.width = 100 } }
                }
            }
        }])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area)), moon = h.add(Disc(area))
        expectEqual(state.commands(for: card).map(\.name), [], "not while the card is narrow")
        expect(!state.run("tidy-up", on: card, with: shape(moon)))
        h.editor.transact { $0.update(card, as: Card.self) { $0.props.frame.size.width = 120 } }
        let tidy = try require(state.command(named: "tidy-up", for: card))
        expectEqual(tidy.title, "Tidy Up")
        expectEqual(tidy.stepName, "Tidy")
        expect(state.run(tidy, on: card, with: shape(moon)))
        expectEqual(h.editor.document[card]?.typed(as: Card.self)?.props.frame.width, 100)
        expectEqual(h.editor.undoHistory.undoName, "Tidy")
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
