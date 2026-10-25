import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import Selection
import SlashCommands
import TestKit
import Topology

// `/query`, the command bar's question: offered on several shapes and on every shape on the board, the words
// translated as `--ask`'s are (on a selection, told only what it picks out of the selection is kept), and what the
// query finds selected. Headless, through the slash commands' state (the bar's waiting is SlashCommandsTests'),
// over captioned chores, a pocket whose board holds one more, and a scripted model.

/// Chores captioned Pantry, Cellar and Attic on the top board, and a pocket whose board holds the chore Hall.
@MainActor private struct QueryRig {
    let h: EditorHarness
    let pantry: ShapeID, cellar: ShapeID, attic: ShapeID, pocket: ShapeID, hall: ShapeID

    init(_ model: ScriptedLanguageModel) throws {
        func chore(_ label: String, x: CGFloat) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Chore(CGRect(x: x, y: 0, width: 100, height: 60))))
            record[Label.self] = label
            return record
        }
        let shapes = [chore("Pantry", x: 0), chore("Cellar", x: 150), chore("Attic", x: 300)]
        let pocketRecord = AnyShapeRecord(ShapeRecord(id: ShapeID(), Pocket(CGRect(x: 0, y: 200, width: 100, height: 100))))
        let hallRecord = chore("Hall", x: 0)
        let names = Contributor(id: "label-names") { registrar in
            registrar.declare(Label.self)
            registrar.optIn(Chore.self, to: Label.self)
            registrar.queryNames(attribute: Label.key.rawValue,
                                 source: { kind, registry in registry.properties(for: kind).contains(Label.key) ? .named : .none },
                                 named: { $0[Label.self] }, derived: { _, _ in nil }, fold: { $0 })
        }
        let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), ChoresPlugin(), PocketsPlugin(), TopologyPlugin(), QueriesPlugin(), SelectionQueriesPlugin(), names,
                                           LanguageModelsPlugin(model: model), QueryTranslationPlugin(prompt: systemPrompt, referenceRule: referenceRule),
                                           SlashCommandsPlugin(), QuerySlashPlugin()]
        h = try EditorHarness(plugins: plugins, file: CanvasFile(root: CanvasDocument(shapes: shapes + [pocketRecord]),
                                                                  children: [pocketRecord.id: CanvasDocument(shapes: [hallRecord])]))
        pantry = shapes[0].id
        cellar = shapes[1].id
        attic = shapes[2].id
        pocket = pocketRecord.id
        hall = hallRecord.id
    }

    var editor: CanvasEditor { h.editor }
    var everything: SlashTarget { .everything(editor.document.shapes.map(\.id)) }

    /// The names `/query` is offered for on a target.
    func offers(_ target: SlashTarget) throws -> Bool {
        try require(editor.slashCommands).commands(for: target).contains { $0.name == "query" }
    }

    /// `/query` asked on a target with what's typed after its name, and what it came to.
    func ask(_ words: SlashArguments, on target: SlashTarget) throws -> SlashAnswer {
        let task = try require(try require(editor.slashCommands).answer("query", for: target, with: words))
        return try awaitResult { await task.value }
    }
}

@MainActor let querySlashTests = Suite("/query", [
    test("offered with several shapes selected and with nothing selected, never on one shape nor in a shape's text; it takes words, and is listed after what the shapes offer") {
        let rig = try QueryRig(ScriptedLanguageModel())
        expect(try rig.offers(rig.everything), "every shape on the board")
        expect(try rig.offers(.selection([rig.pantry, rig.cellar])), "several")
        expect(try !rig.offers(.selection([rig.pantry])), "never one")
        expect(try !rig.offers(.text(rig.pantry)), "nor a shape's text")
        let query = try require(try require(rig.editor.slashCommands).command(named: "query", for: rig.everything))
        expectEqual(query.argument, "question")
        expectEqual(query.waiting, "Asking")
        expect(query.answersLater)
        expect(!query.accepts(SlashArguments([])) && query.accepts("the pantry"))
        expectEqual(rig.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("query-slash") }.map(String.init)?.hasSuffix("/query → the command bar's target"),
                    true)
    },

    test("with nothing selected it asks as --ask asks, and selects every shape the query finds on the board shown; VoiceOver hears how many") {
        let model = ScriptedLanguageModel(answers: ["chore"])
        let rig = try QueryRig(model)
        expectEqual(try rig.ask("all the chores", on: rig.everything), .done)
        expectEqual(rig.editor.selectedShapeIDs, [rig.pantry, rig.cellar, rig.attic], "those on the board shown: Hall is on the pocket's")
        expectEqual(rig.editor.announcements.last, "3 shapes selected, 1 more on other boards")
        let sent = message(try require(model.requests.first))
        expect(sent.contains("<question>\nall the chores\n</question>"), sent)
        expect(sent.contains("Nothing is selected."), "as --ask tells it")
        expect(!sent.contains("picks out"), "and nothing of narrowing")
    },

    test("on a selection it narrows it: the model is told only what it picks out of the selected shapes is kept, and the selected shapes the query finds are selected") {
        let model = ScriptedLanguageModel(answers: [#""Cellar", "Attic""#])
        let rig = try QueryRig(model)
        rig.editor.selectedShapeIDs = [rig.pantry, rig.cellar]
        expectEqual(try rig.ask("the ones downstairs", on: .selection([rig.pantry, rig.cellar])), .done)
        expectEqual(rig.editor.selectedShapeIDs, [rig.cellar], "Attic was found, but isn't among them")
        expectEqual(rig.editor.announcements.last, "1 shape selected")
        let sent = message(try require(model.requests.first))
        expect(sent.contains(#"Selected: "Pantry" (chore), "Cellar" (chore). The question picks out some of the selected shapes"#), sent)
        expectEqual(model.requests.first?.system, systemPrompt, "the prompt as --ask's, no rule line")
    },

    test("nothing it finds among them is No matches, the selection as it was; the model's failures are said in its own words") {
        let model = ScriptedLanguageModel(answers: [#""Attic""#])
        let rig = try QueryRig(model)
        rig.editor.selectedShapeIDs = [rig.pantry, rig.cellar]
        expectEqual(try rig.ask("the attic", on: .selection([rig.pantry, rig.cellar])), .failed("No matches"))
        expectEqual(rig.editor.selectedShapeIDs, [rig.pantry, rig.cellar])
        model.queue(.noKey)
        expectEqual(try rig.ask("the attic", on: rig.everything), .failed("No API key"))
        model.queue("UNANSWERABLE: where shapes sit on the canvas")
        expectEqual(try rig.ask("the chore on the left", on: rig.everything), .failed("A query can't ask that: where shapes sit on the canvas."))
        expectEqual(rig.editor.selectedShapeIDs, [rig.pantry, rig.cellar], "nothing selected by a failure")
        expectEqual(rig.editor.undoHistory.undoName, nil, "and no step")
    },

    test("what it finds only on another board is selected there, that board shown, one step back; found here too, here, the rest counted") {
        let model = ScriptedLanguageModel(answers: [#""Hall""#, #""Pantry", "Hall""#])
        let rig = try QueryRig(model)
        rig.editor.selectedShapeIDs = []
        expectEqual(try rig.ask("the hall", on: rig.everything), .done)
        expectEqual(rig.editor.board, BoardID(owner: rig.pocket), "as following a mention shows it")
        expectEqual(rig.editor.selectedShapeIDs, [rig.hall])
        expectEqual(rig.editor.announcements.last, "1 shape selected")
        rig.editor.goBack()
        expectEqual(rig.editor.board, .root, "one step back")
        expectEqual(rig.editor.selectedShapeIDs, [])
        expectEqual(try rig.ask("the pantry and the hall", on: rig.everything), .done)
        expectEqual(rig.editor.board, .root, "some are here: it stays")
        expectEqual(rig.editor.selectedShapeIDs, [rig.pantry])
        expectEqual(rig.editor.announcements.last, "1 shape selected, 1 more on other boards")
    },

    test("a pill in the question is the name it shows, in quotes, as the language writes a title") {
        let model = ScriptedLanguageModel(answers: [#""Pantry""#])
        let rig = try QueryRig(model)
        _ = try rig.ask(SlashArguments([.text("next to "), .shape(rig.pantry, label: "Pantry")]), on: rig.everything)
        expect(message(try require(model.requests.first)).contains("<question>\nnext to \"Pantry\"\n</question>"))
    },

    test("a question out doesn't keep its editor alive, and cancelled it says nothing and selects nothing") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore")
        var rig: QueryRig? = try QueryRig(model)
        weak var closing = rig?.editor
        let state = try require(rig?.editor.slashCommands)
        let target = try require(rig?.everything)
        let task = try require(state.answer("query", for: target, with: "the chores"))
        spinRunLoop(until: { model.waiting == 1 })
        rig = nil
        expect(closing == nil, "a question out leaves the editor to go with its file")
        task.cancel()
        expectEqual(try awaitResult { await task.value }, .done)
        expectEqual(model.waiting, 0)

        let held = ScriptedLanguageModel()
        held.holdsAnswers = true
        held.queue("chore")
        let open = try QueryRig(held)
        let asked = try require(try require(open.editor.slashCommands).answer("query", for: open.everything, with: "the chores"))
        spinRunLoop(until: { held.waiting == 1 })
        asked.cancel()
        expectEqual(try awaitResult { await asked.value }, .done)
        expectEqual(open.editor.selectedShapeIDs, [], "cancelled, it selects nothing")
    },
])
