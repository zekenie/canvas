import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit
import TextEditing

// A command line typed for a target (`SlashTarget`): one shape's text, as ever, or the shapes selected,
// which the command bar types for. What a target lists (what any of its shapes offers, counted), how a
// command acts on several shapes (`SlashReach`), and running on the shapes it reaches, headless, over
// fixtures.

private let area = CGRect(x: 0, y: 0, width: 100, height: 60)
private let narrow = CGRect(x: 0, y: 0, width: 50, height: 60)

@MainActor private func targetHarness(_ log: Reached = Reached()) throws -> EditorHarness {
    try slashHarness([CardCommandsPlugin(log: CommandLog()), LampsPlugin(), FreezingPlugin(), TargetCommandsPlugin(log: log)])
}

@MainActor private func names(_ state: SlashCommandState, _ target: SlashTarget) -> [String] { state.commands(for: target).map(\.name) }

@MainActor private func width(_ id: ShapeID, in h: EditorHarness) -> CGFloat { h.editor.document[id]?.box?.width ?? 0 }

/// A line in an unshown window typing for a target, writing to no shape.
@MainActor private final class TargetLine {
    let window: NSWindow
    let view: SlashTextView

    init(_ target: SlashTarget, _ commands: SlashCommandState, takesShapes: Bool = true) {
        view = SlashTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 40), target: target, commands: commands, takesShapes: takesShapes)
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
    }

    var listed: [String] { view.slashCommands?.picker?.listed.map(\.name) ?? [] }
    /// The open list's rows: the name, and what it says after it, if anything.
    var rows: [String] {
        view.slashCommands?.picker?.rows.compactMap(\.item).map { item in item.detail.map { "\(item.title) (\($0))" } ?? item.title } ?? []
    }
}

/// The commands a card lists in `targetHarness`: its own (`CardCommandsPlugin`'s, then the target
/// fixtures'), then the scopes' (`tag`).
private let cardCommands = ["grow", "width", "log", "ping", "stack", "any", "heap", "nudge-each", "turn-on", "pick-two", "pick-all", "spread",
                            "spread-try", "tag"]

@MainActor let slashTargetTests = Suite("Slash commands for a target", [
    test("a selection of one shape lists what its text lists, in that order, on it, none partial; frozen, its text lists nothing and its selection only a declared command whose rule acts on it alone") {
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area, text: "x"))
        expectEqual(names(state, .text(card)), cardCommands)
        expectEqual(state.commands(for: card).map(\.name), cardCommands, "a shape's text is `.text`")
        let one = state.commands(for: .selection([card]))
        expectEqual(one.map(\.name), cardCommands)
        expect(one.allSatisfy { $0.shapes == [card] && $0.targetCount == 1 && !$0.isPartial })
        expectEqual(one.first { $0.name == "ping" }?.reach, .one)
        expectEqual(one.first { $0.name == "grow" }?.reach, .each, "an edit acts on each")
        expectEqual(one.first { $0.name == "heap" }?.reach, .together)
        expectEqual(one.first { $0.name == "spread" }?.reach, .together, "a declared command acts on all together")
        h.editor.freeze([card])
        expectEqual(names(state, .text(card)), [], "its text can't be written")
        expectEqual(names(state, .selection([card])), ["thaw"], "spread's rule can't act on it, nor its try's")
        expect(state.run("thaw", for: .selection([card]), with: SlashArguments([])))
        expect(h.editor.document[card]?[Frozen.self] != true)
        expectEqual(h.editor.undoHistory.undoName, "Thaw")
    },

    test("a mixed selection lists every command some of its shapes offer: the first shape's order, then what only later ones offer, each on the shapes that offer it, counted; `when` narrows a reach") {
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let box = h.add(Box(area))
        let card = h.add(Card(area, text: "x"))
        let disc = h.add(Disc(area))
        let wide = h.add(Card(CGRect(x: 0, y: 0, width: 120, height: 60), text: "y"))
        let target = SlashTarget.selection([box, card, disc, wide])
        let found = state.commands(for: target)
        expectEqual(found.map(\.name), ["tag", "grow", "width", "heap", "nudge-each", "turn-on", "pick-two", "pick-all", "spread", "spread-try", "wide"],
                    "the box's, then the card's, then what only the wide card offers; none on one shape alone")
        let tag = try require(found.first)
        expectEqual(tag.shapes, [box, card, disc, wide])
        expectEqual(tag.targetCount, 4)
        expect(!tag.isPartial)
        let grow = try require(found.first { $0.name == "grow" })
        expectEqual(grow.shapes, [card, wide], "the cards, in target order")
        expect(grow.isPartial)
        expectEqual(found.first { $0.name == "wide" }?.shapes, [wide], "`when` holds for the wide card alone")
        h.editor.transact { $0.update(wide, as: Card.self) { $0.props.frame.size.width = 100 } }
        expect(!names(state, target).contains("wide"), "and then for none")
        expectEqual(state.commands(for: .selection([box, disc])).map(\.name), ["tag"])
        expectEqual(state.commands(for: .selection([])).map(\.name), [], "no shapes, no commands")
    },

    test("a command on one shape is listed where the target is one shape, and not for two, of one kind or of two") {
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area, text: "a"))
        let other = h.add(Card(area, text: "b"))
        let box = h.add(Box(area))
        for name in ["log", "ping", "stack", "any"] {
            expect(names(state, .selection([card])).contains(name), "\(name) on one card")
            expect(!names(state, .selection([card, other])).contains(name), "\(name) on two cards")
            expect(!names(state, .selection([card, box])).contains(name), "\(name) on a card and a box")
        }
        expect(names(state, .selection([card, box])).contains("grow"), "an edit acts on each")
        expectEqual(names(state, .selection([card, card])), cardCommands, "a shape named twice is one")
    },

    test("an edit runs on each shape in one transaction and one undo step named for it; a perform on each runs once a shape in one step; one together is handed every shape once, in target order") {
        let log = Reached()
        let h = try targetHarness(log)
        let state = try require(h.editor.slashCommands)
        let cards = (0..<3).map { h.add(Card(area.offsetBy(dx: CGFloat($0) * 200, dy: 0), text: "\($0)")) }
        let before = h.editor.revision
        expect(state.run("grow", for: .selection(cards), with: SlashArguments([])))
        expectEqual(h.editor.revision, before + 1, "one transaction")
        expectEqual(cards.map { width($0, in: h) }, [110, 110, 110])
        expectEqual(h.editor.undoHistory.undoName, "Grow")
        h.editor.undo()
        expectEqual(cards.map { width($0, in: h) }, [100, 100, 100], "undone whole")
        expect(state.run("nudge-each", for: .selection(cards), with: SlashArguments([])))
        expectEqual(log.runs, ["nudge", "nudge", "nudge"])
        expectEqual(h.editor.undoHistory.undoName, "Nudge Each")
        h.editor.undo()
        expectEqual(cards.map { h.editor.document[$0]?.box?.minX ?? -1 }, [0, 200, 400], "one step")
        log.runs = []
        let backwards = Array(cards.reversed())
        expect(state.run("heap", for: .selection(backwards), with: SlashArguments([])))
        expectEqual(log.runs, ["heap"])
        expectEqual(log.handed, [backwards], "once, in target order")
        expect(!state.run("heap", for: .selection(cards), with: SlashArguments("now")), "arguments it doesn't accept")
        expectEqual(log.handed.count, 1)
    },

    test("a declared command is listed while its rule can act on the shapes that offer it; a read-only one is reached only where the rule acts on it alone, a try's too; a try is offered by `when` alone otherwise") {
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let wide = h.add(Card(area, text: "w"))
        let thin = h.add(Card(narrow, text: "t"))
        let frozen = h.add(Card(area, text: "f"))
        h.editor.freeze([frozen])
        expect(state.command(named: "spread", for: .selection([thin])) == nil, "its rule needs a card 100 wide")
        expectEqual(state.command(named: "spread-try", for: .selection([thin]))?.shapes, [thin], "a try, by `when` alone")
        expectEqual(state.command(named: "spread", for: .selection([thin, wide]))?.shapes, [thin, wide], "the rule asked of both, together")
        let mixed = state.commands(for: .selection([frozen, wide]))
        expectEqual(mixed.first?.name, "thaw", "the frozen card's one command, first")
        expectEqual(mixed.first { $0.name == "thaw" }?.shapes, [frozen])
        expectEqual(mixed.first { $0.name == "spread" }?.shapes, [wide])
        expectEqual(mixed.first { $0.name == "spread-try" }?.shapes, [wide])
        expectEqual(mixed.filter { $0.shapes.contains(frozen) }.map(\.name), ["thaw"], "nothing else reaches it")
        let spread = try require(mixed.first { $0.name == "spread" })
        expectEqual(spread.stepName, "Spread Out")
        expect(state.run(spread, with: SlashArguments([])))
        expectEqual(width(wide, in: h), 105)
        expectEqual(width(frozen, in: h), 100, "not reached")
        expectEqual(h.editor.undoHistory.undoName, "Spread Out")
    },

    test("two kinds' own commands of one name are one row, each kind's run on its own shapes in one step; a choice of one name that is two commands is left out") {
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let lamp = h.add(Lamp(area))
        let card = h.add(Card(area, text: "c"))
        let row = try require(state.command(named: "turn-on", for: .selection([lamp, card])))
        expectEqual(row.shapes, [lamp, card])
        expect(!row.isPartial)
        expect(state.run(row, with: SlashArguments([])))
        expectEqual(h.editor.lamp(lamp)?.isOn, true)
        expectEqual(width(card, in: h), 102)
        expectEqual(h.editor.undoHistory.undoName, "Turn On")
        h.editor.undo()
        expectEqual(h.editor.lamp(lamp)?.isOn, false)
        expectEqual(width(card, in: h), 100, "one step")
        expect(state.command(named: "pick-two", for: .selection([lamp, card])) == nil, "two lists of rows can't be one")
        expectEqual(state.command(named: "pick-two", for: .selection([card]))?.choices().map(\.title), ["X"])
        expectEqual(state.command(named: "pick-two", for: .selection([lamp]))?.choices().map(\.title), ["Y"])
        expectEqual(names(state, .selection([lamp, card])).filter { $0.hasPrefix("turn") }, ["turn-on"], "a lamp's and a card's, once")
    },

    test("a choice made together asks its rows for the shapes it acts on, when asked, and a pick runs on them all in one step named by the row") {
        let log = Reached()
        let h = try targetHarness(log)
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a"))
        let box = h.add(Box(area))
        let b = h.add(Card(area, text: "b"))
        let command = try require(state.command(named: "pick-all", for: .selection([a, box, b])))
        expectEqual(log.rowsAskedFor, [], "made when asked, not when listed")
        expect(command.takesChoice)
        let rows = command.choices()
        expectEqual(rows.map(\.title), ["All 2"])
        expectEqual(log.rowsAskedFor, [[a, b]])
        expect(state.run(command, choosing: rows[0]))
        expectEqual(log.handed, [[a, b]])
        expectEqual([width(a, in: h), width(b, in: h)], [101, 101])
        expectEqual(h.editor.undoHistory.undoName, "Pick All")
        expect(!state.run(command, with: SlashArguments([])), "a choice command runs with a pick")
        expect(!state.run(try require(state.command(named: "heap", for: .selection([a, b]))), choosing: rows[0]), "and another with none")
    },

    test("a shape gone between finding a command and running it: it runs on the rest; with none left, false, and no step") {
        let log = Reached()
        let h = try targetHarness(log)
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a"))
        let b = h.add(Card(area, text: "b"))
        let heap = try require(state.command(named: "heap", for: .selection([a, b])))
        h.editor.transact { $0.delete([b]) }
        expect(state.run(heap, with: SlashArguments([])))
        expectEqual(log.handed, [[a]])
        h.editor.transact { $0.delete([a]) }
        let step = h.editor.undoHistory.undoName
        expect(!state.run(heap, with: SlashArguments([])))
        expectEqual(log.handed, [[a]])
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        expect(!state.run(heap, on: a, with: SlashArguments([])), "found for two, it isn't one shape's")
    },

    test("what a selection lists is kept while the file stands: asked twice it reads its records once, and again after a commit; a shape's text reads its one record each time") {
        #if DEBUG
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let cards = (0..<5).map { h.add(Card(area, text: "\($0)")) }
        let first = state.recordsRead
        _ = state.commands(for: .selection(cards))
        expectEqual(state.recordsRead - first, 5)
        _ = state.commands(for: .selection(cards))
        _ = state.command(named: "heap", for: .selection(cards))
        expectEqual(state.recordsRead - first, 5, "kept")
        h.editor.transact { $0.update(cards[0], as: Card.self) { $0.props.text = "changed" } }
        _ = state.commands(for: .selection(cards))
        expectEqual(state.recordsRead - first, 10, "read again after a commit")
        _ = state.commands(for: .text(cards[0]))
        _ = state.commands(for: .text(cards[0]))
        expectEqual(state.recordsRead - first, 12, "a text keeps nothing")
        _ = state.commands(for: .selection(Array(cards.prefix(2))))
        expectEqual(state.recordsRead - first, 14, "another selection is read")
        #endif
    },

    test("a row of a command that acts on fewer than the target's shapes says how many after its hint, and VoiceOver hears it; one that acts on all reads as in a note") {
        let h = try targetHarness()
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a"))
        let b = h.add(Card(area, text: "b"))
        let box = h.add(Box(area))
        let picker = SlashCommandPicker(at: 0, offering: state.commands(for: .selection([a, b, box])))
        let items = picker.rows.compactMap(\.item)
        let by = Dictionary(items.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })
        expectEqual(by["heap"]?.detail, "2 of 3")
        expectEqual(by["heap"]?.spoken, "heap, acts on 2 of 3 shapes")
        expectEqual(by["width"]?.detail, "points · 2 of 3")
        expectEqual(by["width"]?.spoken, "width, takes points, acts on 2 of 3 shapes")
        expectEqual(by["tag"]?.detail, nil, "on every shape: no count")
        expectEqual(by["tag"]?.spoken, "tag")
        let note = SlashCommandPicker(at: 0, offering: state.commands(for: .text(a))).rows.compactMap(\.item)
        expectEqual(note.first { $0.title == "width" }?.detail, "points", "a text's line is never partial")
        expectEqual(note.first { $0.title == "width" }?.spoken, "width, takes points")
    },

    test("a line typed for the selection lists its commands, counted, and Return takes the line out, tells the host the command will run, then runs it on its reach") {
        let log = Reached()
        let h = try targetHarness(log)
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a"))
        let box = h.add(Box(area))
        let b = h.add(Card(area, text: "b"))
        let line = TargetLine(.selection([a, box, b]), state)
        line.view.slashCommands?.willRun = { command, choice in log.runs.append("will run \(command.name) \(choice?.id ?? "-")") }
        expectEqual(line.view.slashCommands?.target, .selection([a, box, b]))
        line.window.type("/")
        expectEqual(line.listed, ["grow", "width", "heap", "nudge-each", "turn-on", "pick-two", "pick-all", "spread", "spread-try", "tag"])
        expectEqual(Array(line.rows.prefix(3)), ["grow (2 of 3)", "width (points · 2 of 3)", "heap (2 of 3)"])
        line.window.type("heap")
        line.window.pressReturn()
        expectEqual(log.runs, ["will run heap -", "heap"], "the host first, told what runs")
        expectEqual(log.handed, [[a, b]])
        expectEqual(line.view.string, "", "the line went first")
    },

    test("a pick of a choice typed for the selection tells the host first too, and runs on every shape the command reaches") {
        let log = Reached()
        let h = try targetHarness(log)
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a"))
        let b = h.add(Card(area, text: "b"))
        let line = TargetLine(.selection([a, b]), state)
        line.view.slashCommands?.willRun = { command, choice in log.runs.append("will run \(command.name) \(choice?.id ?? "-")") }
        line.window.type("/pick-all")
        line.window.pressReturn()
        expect(line.view.slashCommands?.choices != nil, "Return completed the name and opened its rows")
        line.window.pressReturn()
        expectEqual(log.runs, ["will run pick-all all"], "told the command and the row")
        expectEqual(log.handed, [[a, b]])
        expectEqual(h.editor.undoHistory.undoName, "Pick All")
    },

    test("a field that can't name a shape leaves out the commands that take one, from its list, its marks and its Return") {
        let log = CommandLog()
        let h = try slashHarness([CardCommandsPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let card = h.add(Card(area, text: "a"))
        let plain = TargetLine(.selection([card]), state, takesShapes: false)
        plain.window.type("/")
        expect(!plain.listed.contains("stack"), "stack takes a shape")
        expect(plain.listed.contains("ping"))
        plain.window.type("stack")
        expectEqual(plain.listed, [], "nothing of that name for it")
        plain.window.pressEscape()
        expectEqual(plain.view.string, "/stack")
        expect(plain.view.highlights.isEmpty, "not marked as a command")
        plain.window.pressReturn()
        expectEqual(log.runs, [], "nor run: Return is a new line")
        expectEqual(plain.view.string, "/stack\n")
        let named = TargetLine(.selection([card]), state)
        named.window.type("/")
        expect(named.listed.contains("stack"), "a field that can name one lists it")
    },

    // MARK: Every shape, and commands about the target

    test("with nothing selected the bar types for every shape on the board: they list what a selection of them all lists, then a command about the target, which a text's line and a selection of one don't list") {
        let log = AskLog()
        let h = try slashHarness([CardCommandsPlugin(log: CommandLog()), LampsPlugin(), FreezingPlugin(), TargetCommandsPlugin(log: Reached()), AskPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a")), b = h.add(Card(area.offsetBy(dx: 200, dy: 0), text: "b"))
        let frozen = h.add(Card(area.offsetBy(dx: 400, dy: 0), text: "c"))
        h.editor.freeze([frozen])
        let all = h.editor.document.shapes.map(\.id)
        expectEqual(names(state, .everything(all)), names(state, .selection(all)), "every shape is a selection of them all")
        expectEqual(names(state, .everything(all)).last, "ask", "after what the shapes offer")
        expect(!names(state, .text(a)).contains("ask"), "never in a shape's text")
        expect(!names(state, .selection([a])).contains("ask"), "its rule: never one shape")
        expect(names(state, .everything([a])).contains("ask"), "but every shape, though the board holds one")
        let ask = try require(state.commands(for: .everything(all)).first { $0.name == "ask" })
        expectEqual(ask.shapes, [a, b, frozen], "every shape of the target, the frozen one too")
        expectEqual(ask.targetCount, 3)
        expect(!ask.isPartial && ask.answersLater && ask.reach == .together && !ask.takesShape && !ask.takesChoice)
        expectEqual(ask.argument, "words")
        expectEqual(ask.waiting, "Asking")
        expect(state.commands(for: .everything(all)).filter { $0.name != "ask" }.allSatisfy { !$0.answersLater })
        expectEqual(log.asked.count, 0, "listing it starts nothing")
    },

    test("a command that answers later isn't run but started: its task, with the target and what was typed; it takes what its rule takes, and the task's cancellation is the caller's") {
        let log = AskLog()
        let h = try slashHarness([CardCommandsPlugin(log: CommandLog()), AskPlugin(log: log)])
        let state = try require(h.editor.slashCommands)
        let a = h.add(Card(area, text: "a")), b = h.add(Card(area.offsetBy(dx: 200, dy: 0), text: "b"))
        let ask = try require(state.command(named: "ask", for: .selection([a, b])))
        expect(!state.run(ask, with: "red ones"), "run refuses it")
        expectEqual(state.answer(ask, with: SlashArguments([])) == nil, true, "it takes words")
        expectEqual(log.asked.count, 0)
        let task = try require(state.answer(ask, with: "  the red ones "))
        expectEqual(log.asked.count, 1)
        expectEqual(log.asked.first?.target, .selection([a, b]))
        expectEqual(log.asked.first?.arguments.text, "the red ones")
        expectEqual(h.editor.undoHistory.undoName, nil, "starting it is no step")
        expect(spinRunLoop(until: { log.waitingCount == 1 }), "its task waits")
        log.answer(.failed("No luck"))
        expectEqual(try awaitResult { await task.value }, .failed("No luck"))
        let stopped = try require(state.answer("ask", for: .selection([a, b]), with: "again"))
        expect(spinRunLoop(until: { log.waitingCount == 1 }))
        stopped.cancel()
        expectEqual(try awaitResult { await stopped.value }, .done)
        expectEqual(log.cancelled, 1)
        expectEqual(state.answer("ask", for: .selection([a]), with: "x") == nil, true, "by name, offered now or not at all")
    },
])
