import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit

// A command a plugin declared (`registrar.command`), typed on a line of a shape's text: offered by its one
// rule, asked with the shape, run on it as a try, its step named as the command is.

/// What the declared commands ran on.
@MainActor private final class Stamps {
    var on: [[ShapeID]] = []
}

/// `stamp` ("Stamp the Card"), which can act on cards whose text says something, widening each by 7;
/// `/stamp` typed for it, and `/force`, which is offered on every card and tries it there.
@MainActor private func stamping(_ stamps: Stamps) -> Contributor {
    Contributor(id: "stamping") { r in
        r.command("stamp", title: "Stamp the Card", isEnabled: { subject in
            subject.shapes.allSatisfy { subject.editor.document[$0]?.typed(as: Card.self)?.props.text.isEmpty == false }
        }) { subject in
            stamps.on.append(subject.shapes)
            subject.editor.transact { transaction in
                for id in subject.shapes { transaction.update(id, as: Card.self) { $0.props.frame.size.width += 7 } }
            }
        }
        r.slashCommands(Card.self) {
            SlashCommand("stamp", command: "stamp")
            SlashCommand("force", command: "stamp", when: { $0.frame.width < 1000 }, tries: true)
        }
    }
}

private let area = CGRect(x: 0, y: 0, width: 100, height: 60)

@MainActor let slashDeclaredCommandTests = Suite("A declared command, typed", [
    test("it's offered while its command can act on the shape, takes no arguments, runs on the shape, and its step is named as the command is") {
        let stamps = Stamps()
        let h = try slashHarness([stamping(stamps)])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area, text: ""))
        expect(!state.commands(for: card).map(\.name).contains("stamp"), "a blank card: the command can't act on it")
        h.editor.transact { $0.update(card, as: Card.self) { $0.props.text = "x" } }
        let offered = try require(state.command(named: "stamp", for: card))
        expectEqual(offered.argument, nil)
        expect(!offered.accepts(SlashArguments([.text("now")])), "no arguments")
        expectEqual(offered.stepName, "Stamp the Card", "named as the command is")
        expect(state.run(offered, on: card, with: SlashArguments([])))
        expectEqual(stamps.on, [[card]])
        expectEqual(h.editor.document[card]?.box?.width, 107)
        expectEqual(h.editor.undoHistory.undoName, "Stamp the Card")
        h.editor.undo()
        expectEqual(h.editor.document[card]?.box?.width, 100)
    },
    test("with `tries`, it's offered by `when` alone, and runs where its command can't act, which the command refuses or does as a try would") {
        let stamps = Stamps()
        let h = try slashHarness([stamping(stamps)])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area, text: ""))
        expectEqual(state.commands(for: card).map(\.name).filter { $0 == "stamp" || $0 == "force" }, ["force"], "a blank card: only the try")
        expect(state.run("force", on: card, with: SlashArguments([])))
        expectEqual(stamps.on, [[card]], "the command's action ran, its rule not asked: a try")
    },
    test("one for a command no plugin claims isn't offered") {
        let h = try slashHarness([Contributor(id: "orphan") { r in
            r.slashCommands(Card.self) {
                SlashCommand("ghost", command: "nobody")
                SlashCommand("ghost-try", command: "nobody", tries: true)
            }
        }])
        let card = h.add(Card(area, text: "x"))
        expectEqual(try require(h.editor.slashCommands).commands(for: card).map(\.name).filter { $0.hasPrefix("ghost") }, [])
    },
])
