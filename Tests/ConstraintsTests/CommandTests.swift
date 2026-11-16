@_spi(Host) import Canvas
import CanvasTesting
import Constraints
import CoreGraphics
import LanguageModels
import QueryTranslation
import Selection
import SlashCommands
import TestKit
import Titles
import Validation

// `/constrain <words>` and `/unconstrain`, in the command bar's state (the bar's waiting and its list are SlashCommandsTests'):
// where each is offered, what each does to one shape, several, a holder, the board shown and the root, the model asked once
// in the place's name (or not at all, for words that already are a query), each failure in the words every host says,
// cancelling, and the list `/unconstrain` offers.

private let penRect = CGRect(x: 100, y: 100, width: 400, height: 300)

extension EditorHarness {
    /// `/constrain` asked on a target with what's typed, and what it came to.
    func constrain(_ words: SlashArguments, on target: SlashTarget) throws -> SlashAnswer {
        let task = try require(try require(editor.slashCommands).answer("constrain", for: target, with: words))
        return try awaitResult { await task.value }
    }

    /// The commands a target offers, by name.
    func offered(on target: SlashTarget) throws -> [String] {
        try require(editor.slashCommands).commands(for: target).map(\.name).filter { ["constrain", "unconstrain"].contains($0) }
    }

    /// The rows `/unconstrain` lists for a target: title and detail.
    func unconstrainRows(on target: SlashTarget) throws -> [String] {
        let command = try require(try require(editor.slashCommands).command(named: "unconstrain", for: target))
        return command.choices().map { [$0.title, $0.detail].compactMap { $0 }.joined(separator: " | ") }
    }

    /// Picks a row of `/unconstrain` by its title.
    @discardableResult
    func unconstrain(_ title: String, on target: SlashTarget) throws -> Bool {
        let commands = try require(editor.slashCommands)
        let command = try require(commands.command(named: "unconstrain", for: target))
        let choice = try require(command.choices().first { $0.title == title })
        return commands.run(command, choosing: choice)
    }
}

@MainActor let constrainTests = Suite("Constraints: /constrain", [
    test("offered on containers and holders selected, and with nothing selected on the board shown; never on other shapes, a line of text or a mix") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect), drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        let plain = h.add(Charter(CGRect(x: 600, y: 450, width: 100, height: 80)))
        let d = h.disc(at: CGPoint(x: 700, y: 500))
        expectEqual(try h.offered(on: .selection([pen])), ["constrain"])
        expectEqual(try h.offered(on: .selection([pen, drawer])), ["constrain"])
        expectEqual(try h.offered(on: .selection([charter])), ["constrain"], "a holder: a type")
        expectEqual(try h.offered(on: .selection([plain])), [], "a shape of a holder's kind that keeps no list")
        expectEqual(try h.offered(on: .selection([d])), [])
        expectEqual(try h.offered(on: .selection([pen, d])), [], "one that keeps none, and none is offered")
        expectEqual(try h.offered(on: .everything(h.editor.document.shapes.map(\.id))), ["constrain"], "the root board's list")
        expectEqual(try h.offered(on: .text(pen)), [])
        let command = try require(h.editor.slashCommands?.command(named: "constrain", for: .selection([pen])))
        expectEqual(command.argument, "words")
        expectEqual(command.waiting, "Interpreting…")
        expect(command.answersLater)
        expect(!command.accepts(SlashArguments([])) && command.accepts("only tiles"))
        h.editor.freeze([pen])
        expectEqual(try h.offered(on: .selection([pen])), [], "a frozen one can't change")
        expectEqual(try h.offered(on: .selection([pen, drawer])), ["constrain"], "one that can")
    },
    test("on a container: the model is asked once, in the place's name, and the constraint is added after the others in one step, Add Constraint; never replacing") {
        let model = ScriptedLanguageModel(answers: ["tile", "tile"])
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [noDiscs])
        expectEqual(try h.constrain("only tiles", on: .selection([pen])), .done)
        expectEqual(h.list(of: pen), [noDiscs, Constraint(says: "only tiles", query: "tile")])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(model.requests.count, 1)
        expect(model.lastRequest?.system?.hasSuffix("which shapes Pen accepts.") == true)
        h.settle()
        expectEqual(try h.constrain("only tiles", on: .selection([pen])), .failed("Pen already accepts only tiles."), "the same words again: said, nothing added")
        expectEqual(model.requests.count, 1)
        h.editor.undo()
        expectEqual(h.list(of: pen), [noDiscs])
    },
    test("words the list already holds fail at once, the place said: no model asked, nothing written, no step; some lists lacking them are written as now") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let log = RefusalLog()
        let h = try constraintHarness(log: log, model: model)
        let pen = h.corral("Pen", penRect, [onlyTiles]), drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        let revision = h.editor.revision
        expectEqual(try h.constrain("only  tiles", on: .selection([pen])), .failed("Pen already accepts only tiles."), "folded as a list compares them")
        expectEqual(model.requests.count, 0, "no model asked")
        expectEqual(h.editor.revision, revision, "nothing written")
        expectEqual(try h.constrain("only tiles", on: .selection([pen, drawer])), .done, "one list lacks them: the rest are written")
        expectEqual(h.list(of: pen), [onlyTiles])
        expectEqual(h.list(of: drawer), [Constraint(says: "only tiles", query: "tile")])
        expectEqual(model.requests.count, 1, "the model was asked once, for the list that lacked them")
        let step = h.editor.undoHistory.undoName
        expectEqual(try h.constrain("only tiles", on: .selection([drawer, pen])), .failed("Drawer already accepts only tiles."), "several: the first one's place")
        expectEqual(model.requests.count, 1, "no model call")
        expectEqual(h.editor.undoHistory.undoName, step, "no step")
        h.writer.add(noDiscs, to: .root)
        expectEqual(try h.constrain("no discs", on: .everything([])), .failed("This board already accepts no discs."), "the root's")
        expectEqual(log.refusals, [], "nothing shook")
    },
    test("a list holds each words once: the same words with another reach or query are not added, and a list read with them keeps the first") {
        let h = try constraintHarness(model: ScriptedLanguageModel())
        let pen = h.corral("Pen", penRect, [Constraint(says: "only tiles", query: "tile", reach: .children)])
        var list = h.list(of: pen)
        expect(!ConstraintWriter.adding(Constraint(says: "only  tiles", query: "tile", reach: .descendants), to: &list), "same words, another reach")
        expect(!ConstraintWriter.adding(Constraint(says: "only tiles", query: "disc"), to: &list), "same words, another query")
        expectEqual(list.count, 1)
        let read = ConstraintList([Constraint(says: "a", reach: .children), Constraint(says: "a", reach: .descendants), Constraint(says: "b")])
        expectEqual(read.constraints.map(\.says), ["a", "b"])
        expectEqual(read.constraints[0].reach, .children)
    },
    test("words that already read as a query skip the model") {
        let model = ScriptedLanguageModel()
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect)
        expectEqual(try h.constrain(#"tile[finish="glossy"]"#, on: .selection([pen])), .done)
        expectEqual(h.list(of: pen), [Constraint(says: #"tile[finish="glossy"]"#, query: #"tile[finish="glossy"]"#)])
        expectEqual(model.requests.count, 0)
    },
    test("several at once are one step and one call, the model told they are each of them") {
        let model = ScriptedLanguageModel(answers: [":not(disc)"])
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect, [onlyTiles]), drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        expectEqual(try h.constrain("no discs", on: .selection([pen, drawer])), .done)
        expectEqual(h.list(of: pen), [onlyTiles, Constraint(says: "no discs", query: ":not(disc)")])
        expectEqual(h.list(of: drawer), [Constraint(says: "no discs", query: ":not(disc)")])
        expectEqual(model.requests.count, 1)
        expect(model.lastRequest?.system?.hasSuffix("which shapes each of these accepts.") == true)
        h.editor.undo()
        expectEqual(h.list(of: pen), [onlyTiles])
        expectEqual(h.list(of: drawer), [], "one step")
    },
    test("a frozen one among them is passed over and shakes, the rest take it") {
        let log = RefusalLog()
        let h = try constraintHarness(log: log)
        let pen = h.corral("Pen", penRect), frozen = h.corral("Frozen", CGRect(x: 600, y: 100, width: 150, height: 150))
        h.editor.freeze([frozen])
        expectEqual(try h.constrain("tile", on: .selection([pen, frozen])), .done)
        expectEqual(h.list(of: pen), [Constraint(says: "tile", query: "tile")])
        expectEqual(h.list(of: frozen), [])
        expect(log.refusals.contains { $0.contains(frozen) }, "it shook")
    },
    test("with nothing selected it is the board shown's: the root's list on the root board, the pocket's own on its board") {
        let h = try constraintHarness()
        let drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150))
        expectEqual(try h.constrain("tile", on: .everything([])), .done)
        expectEqual(h.writer.constraints(of: .root), [Constraint(says: "tile", query: "tile")])
        expectEqual(h.editor.undoHistory.undoName, "Add Constraint")
        expectEqual(h.list(of: drawer), [])
        expect(h.editor.showBoard(BoardID(owner: drawer)))
        expectEqual(try h.offered(on: .everything([])), ["constrain"])
        expectEqual(try h.constrain("disc", on: .everything([])), .done)
        expectEqual(h.list(of: drawer), [Constraint(says: "disc", query: "disc")])
        expectEqual(h.writer.constraints(of: .root)?.count, 1, "the root's is as it was")
    },
    test("each failure is said in the words every host says, and writes nothing") {
        let model = ScriptedLanguageModel()
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect)
        model.queue(LanguageModelError.notSignedIn)
        expectEqual(try h.constrain("only tiles", on: .selection([pen])), .failed("Not signed in"))
        model.queue("UNANSWERABLE: where shapes sit")
        expectEqual(try h.constrain("only the left ones", on: .selection([pen])), .failed("No query for these words"))
        model.queue(LanguageModelError.unauthorized)
        expectEqual(try h.constrain("only tiles", on: .selection([pen])), .failed("Key rejected"))
        model.queue(#""Ghost""#)
        model.queue(#""Ghost""#)
        expectEqual(try h.constrain("only ghosts", on: .selection([pen])), .failed("No shape is called Ghost"), "a title nothing has, named")
        expectEqual(h.list(of: pen), [])
        expectEqual(h.editor.undoHistory.undoName, nil, "no step")
    },
    test("stopped while the model answers it says nothing and writes nothing") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        model.holdsAnswers = true
        let h = try constraintHarness(model: model)
        let pen = h.corral("Pen", penRect)
        let task = try require(try require(h.editor.slashCommands).answer("constrain", for: .selection([pen]), with: "only tiles"))
        spinRunLoop(until: { model.waiting == 1 }, timeout: 5)
        task.cancel()
        model.release()
        let answer = try awaitResult { await task.value }
        expectEqual(answer, .done)
        expectEqual(h.list(of: pen), [])
        expectEqual(h.editor.undoHistory.undoName, nil)
    },
    test("a holder takes it too, written through the holder, named as its section says it") {
        let model = ScriptedLanguageModel(answers: ["tile"])
        let h = try constraintHarness(model: model)
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        expectEqual(try h.constrain("only tiles", on: .selection([charter])), .done)
        expectEqual(h.list(of: charter), [Constraint(says: "only tiles", query: "tile")])
        expect(model.lastRequest?.system?.hasSuffix("which shapes each sprint accepts.") == true)
    },
])

@MainActor let unconstrainTests = Suite("Constraints: /unconstrain", [
    test("offered where the target has constraints of its own that can change: none for none, nor for what is only given") {
        let given = Given()
        let h = try constraintHarness(given)
        let pen = h.corral("Pen", penRect), kept = h.corral("Kept", CGRect(x: 600, y: 100, width: 150, height: 150), [onlyTiles])
        expectEqual(try h.offered(on: .selection([pen])), ["constrain"])
        expectEqual(try h.offered(on: .selection([kept])), ["constrain", "unconstrain"])
        expectEqual(try h.offered(on: .selection([pen, kept])), ["constrain", "unconstrain"], "one of them has")
        given.lists[pen] = [ConstraintSource(holder: ShapeID(), constraints: [noDiscs])]
        h.index.inheritedConstraintsDidChange(of: [pen])
        h.wait(0)
        expectEqual(try h.offered(on: .selection([pen])), ["constrain"], "what it is given is never offered")
        expectEqual(try h.offered(on: .everything([])), ["constrain"], "the root has none")
        h.writer.add(noDiscs, to: .root)
        expectEqual(try h.offered(on: .everything([])), ["constrain", "unconstrain"])
        expectEqual(try h.offered(on: .text(kept)), [])
        h.editor.freeze([kept])
        expectEqual(try h.offered(on: .selection([kept])), [], "frozen: it can't change")
    },
    test("it lists each of the target's own by its words with its reach, then all with how many; a row takes it away in one step, Remove Constraint") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, Constraint(says: "no discs", query: ":not(disc)", reach: .descendants)])
        let target = SlashTarget.selection([pen])
        expectEqual(try h.unconstrainRows(on: target), ["only tiles | Directly inside", "no discs | Anywhere inside", "all | 2 constraints"])
        let command = try require(h.editor.slashCommands?.command(named: "unconstrain", for: target))
        expectEqual(command.argument, "constraint")
        expect(command.takesChoice)
        expect(!command.accepts(SlashArguments("tiles")), "it runs with a pick, never with words")
        expect(try h.unconstrain("only tiles", on: target))
        expectEqual(h.list(of: pen), [Constraint(says: "no discs", query: ":not(disc)", reach: .descendants)])
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraint")
        h.editor.undo()
        expectEqual(h.list(of: pen).count, 2)
    },
    test("all takes every one away, one step, Remove Constraints") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs])
        expect(try h.unconstrain("all", on: .selection([pen])))
        expectEqual(h.list(of: pen), [])
        expectEqual(h.editor.undoHistory.undoName, "Remove Constraints")
        expect(h.editor.registry.isConstrainable(Corral.kind))
        expect(!h.editor.slashCommands!.commands(for: .selection([pen])).contains { $0.name == "unconstrain" }, "nothing left to offer")
    },
    test("on several, each constraint once with in how many it is, taken from every list that has it, in one step") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [onlyTiles, noDiscs]), drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        let target = SlashTarget.selection([pen, drawer])
        expectEqual(try h.unconstrainRows(on: target), ["only tiles | in 1 of 2", "no discs | in 2 of 2", "all | 3 constraints"])
        expect(try h.unconstrain("no discs", on: target))
        expectEqual(h.list(of: pen), [onlyTiles])
        expectEqual(h.list(of: drawer), [])
        h.editor.undo()
        expectEqual(h.list(of: drawer), [noDiscs], "one step")
    },
    test("a holder's own list, and the root's with nothing selected") {
        let h = try constraintHarness()
        let charter = h.add(Charter(CGRect(x: 600, y: 300, width: 100, height: 80), name: "Sprint"))
        h.writer.add(onlyTiles, to: .shape(charter))
        expectEqual(try h.unconstrainRows(on: .selection([charter])), ["only tiles | Directly inside"], "one constraint: its row does all there is")
        expect(try h.unconstrain("only tiles", on: .selection([charter])))
        expectEqual(h.list(of: charter), [])
        h.writer.add(noDiscs, to: .root)
        expect(try h.unconstrain("no discs", on: .everything([charter])))
        expectEqual(h.writer.constraints(of: .root), [])
    },
    test("all is offered only where the lists hold two or more constraints to tell apart: the same one in several lists is one row") {
        let h = try constraintHarness()
        let pen = h.corral("Pen", penRect, [noDiscs]), drawer = h.pocket("Drawer", CGRect(x: 600, y: 100, width: 200, height: 150), [noDiscs])
        expectEqual(try h.unconstrainRows(on: .selection([pen, drawer])), ["no discs | in 2 of 2"])
        let other = h.corral("Other", CGRect(x: 900, y: 100, width: 150, height: 150), [onlyTiles])
        expectEqual(try h.unconstrainRows(on: .selection([pen, other])), ["no discs | in 1 of 2", "only tiles | in 1 of 2", "all | 2 constraints"],
                    "different ones: all takes both")
    },
])
