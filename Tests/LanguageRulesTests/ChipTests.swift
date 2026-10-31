import AppKit
import Canvas
import CanvasRPC
import CanvasTesting
import DecisionModels
import LanguageModels
import LanguageRules
import Queries
import QueryTranslation
import TestKit
import Titles
import Types
import Validation

// A rule's chips: what each finds for the shape checked goes into what the model is sent (`found by "<phrase>"`, a
// container found followed by what it holds); a commit that writes anything asks the chips again and checks again only
// the shapes whose chips find something else; a chip's words become a query through the lifecycle every host of words
// shares, asked bound to the shape checked; the line under a rule says what each found for a sample; a chip the engine
// can't read warns on its type.

/// Listings that each check the others: a rule whose chip finds the other listings, beside a lineup corral.
@MainActor struct ChippedListings {
    let listing = ShapeID(), corolla = ShapeID(), camry = ShapeID(), prius = ShapeID(), lineup = ShapeID(), model = ShapeID()
    static let others = "the other listings"
    static let unlike = "Priced unlike the other listings."
    static let query = #"card:is-a("Listing"):not(:scope)"#

    func shapes(query: String? = ChippedListings.query) -> [AnyShapeRecord] {
        [typeCard("Listing", chipped: [Rule(says: Self.unlike, find: [RuleChip(phrase: Self.others, query: query)])], id: listing),
         card("2021 Toyota Corolla LE", of: [listing], id: corolla, at: CGPoint(x: 300, y: 0)),
         card("2019 Toyota Camry SE", of: [listing], id: camry, at: CGPoint(x: 600, y: 0)),
         card("2020 Toyota Prius", of: [listing], id: prius, at: CGPoint(x: 900, y: 0)),
         AnyShapeRecord(ShapeRecord(id: lineup, Corral(CGRect(x: 0, y: 400, width: 1000, height: 400))))]
    }
}

@MainActor let chipCheckTests = Suite("What a rule's chips find", [
    test("each chip's finds are in the state, under found by and its phrase, in full, and in what the panel shows as Shown") {
        let board = ChippedListings()
        let decisions = answering(["all": 0.1])
        let scene = try RuleScene(board.shapes(), decisions: decisions)
        scene.settle()
        let sent = try require(scene.checks.check(of: board.corolla)?.verdict?.sent)
        expectEqual(sent.state[#"found by "the other listings""#], [
            ["kind": "card", "title": "2019 Toyota Camry SE", "is": ["Listing"]],
            ["kind": "card", "title": "2020 Toyota Prius", "is": ["Listing"]],
        ], "the others, bound to the corolla")
        let shown = try require(scene.checks.sent(for: board.corolla)).groups.first { $0.label == #"found by "the other listings""# }
        expectEqual(shown?.shapes, [board.camry, board.prius])
        expectEqual(decisions.requests.count, 3, "the three listings, in one pass")
    },
    test("a container a chip finds brings what it holds, after it") {
        let board = ChippedListings()
        let scene = try RuleScene(board.shapes(query: #"corral"#), decisions: answering(["all": 0.1]))
        let held = card("2022 Toyota bZ4X", of: [], id: board.model, at: CGPoint(x: 100, y: 500))
        scene.editor.transact("Add") { $0.insert(held) }
        scene.editor.put([board.model], in: board.lineup)
        scene.settle()
        let found = try require(scene.checks.check(of: board.corolla)?.verdict?.sent).state[#"found by "the other listings""#]
        expectEqual(found?.arrayValue?.count, 2, "the corral, then what it holds")
        expectEqual(found?.arrayValue?.last?["title"], "2022 Toyota bZ4X")
    },
    test("a commit that writes anything asks the chips again; only the shapes whose chips find something else are asked again") {
        let board = ChippedListings()
        let decisions = answering(["all": 0.1])
        let scene = try RuleScene(board.shapes(), decisions: decisions)
        let tucked = card("A brochure", of: [], at: CGPoint(x: 100, y: 450))
        scene.editor.transact("Add") { $0.insert(tucked) }
        scene.editor.put([tucked.id], in: board.lineup)
        scene.settle()
        let asked = decisions.requests.count
        scene.editor.transact("Title") { $0.update(tucked.id) { $0[TitleProperty.self] = "A price list" } }
        scene.settle()
        expectEqual(decisions.requests.count, asked, "what no state read and no chip finds changed: nothing asked")
        let another = card("2018 Toyota Yaris", of: [board.listing], at: CGPoint(x: 100, y: 900))
        scene.editor.transact("Add") { $0.insert(another) }
        scene.settle()
        let titles = Set(decisions.requests.dropFirst(asked).compactMap { $0.state["shape"]?["title"]?.stringValue })
        expectEqual(titles, ["2021 Toyota Corolla LE", "2019 Toyota Camry SE", "2020 Toyota Prius", "2018 Toyota Yaris"],
                    "each listing's other listings changed, and the new one is checked")
    },
    test("a chip with no query finds nothing to say; one the engine can't read warns on its type, in its words") {
        let board = ChippedListings()
        let scene = try RuleScene(board.shapes(query: nil), decisions: answering(["all": 0.1]))
        scene.settle()
        expectEqual(try require(scene.checks.check(of: board.corolla)?.verdict?.sent).state[#"found by "the other listings""#], nil)
        expectEqual(scene.warnings(of: board.listing), [])
        let unreadable = try RuleScene(board.shapes(query: "card:glows"), decisions: answering(["all": 0.1]))
        unreadable.settle()
        let warning = try require(unreadable.warnings(of: board.listing).first)
        expect(warning.hasPrefix("“the other listings” can’t be read: "), warning)
        expect(warning.contains(":glows"), warning)
        expectEqual((unreadable.editor.validation?.result(for: board.listing)?.issues ?? []).map(\.source), [nil], "the chip's warning has no source")
    },
])

@MainActor let chipWordsTests = Suite("A chip's words", [
    test("a shape picked is a chip whose query is its title, quoted, where no other shape has it, else its id; nothing is asked") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel()
        let scene = try RuleScene(board.shapes(), language: language)
        let chips = try require(scene.editor.ruleChips)
        let box = RuleBox(type: board.listing, index: nil)
        chips.chip(shape: board.camry, named: "2019 Toyota Camry SE", in: box, text: "Cheaper than 2019 Toyota Camry SE.", stored: nil)
        expectEqual(chips.rule(in: box, stored: nil).find, [RuleChip(phrase: "2019 Toyota Camry SE", query: #""2019 Toyota Camry SE""#)])
        let twin = card("2019 Toyota Camry SE", of: [], at: CGPoint(x: 0, y: 900))
        scene.editor.transact("Add") { $0.insert(twin) }
        chips.chip(shape: board.camry, named: "2019 Toyota Camry SE", in: box, text: "Cheaper than 2019 Toyota Camry SE.", stored: nil)
        expectEqual(chips.rule(in: box, stored: nil).find.first?.query, "#" + board.camry.description, "a title two shapes have: the id")
        expectEqual(language.requests.count, 0)
    },
    test("words that read as a query bound to the shape checked are that query, with no model asked") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel()
        let scene = try RuleScene(board.shapes(), language: language)
        let chips = try require(scene.editor.ruleChips)
        let box = RuleBox(type: board.listing, index: nil)
        chips.chip(words: "card:not(:scope)", in: box, text: "Unlike card:not(:scope).", stored: nil)
        expectEqual(chips.rule(in: box, stored: nil).find.first?.query, "card:not(:scope)")
        expectEqual(language.requests.count, 0)
    },
    test("words are asked as a query bound to the type's shapes, with the rule's sentence, its phrase in brackets; a draft while the box is typed, written with the rule") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel(answers: [#"card:is-a("Listing"):not(:scope)"#])
        let scene = try RuleScene(board.shapes(), language: language)
        let chips = try require(scene.editor.ruleChips)
        let box = RuleBox(type: board.listing, index: 0)
        let stored = RuleBook.rules(of: board.listing, in: scene.editor).first
        chips.chip(words: "the rest", in: box, text: "Priced unlike the rest.", stored: stored)
        spinRunLoop(until: { chips.preview(of: RuleChip(phrase: "the rest", query: nil), type: board.listing).query != nil })
        let request = try require(language.requests.first)
        let system = request.system ?? ""
        expect(system.contains(#"in a rule on the type "Listing", whose shapes are cards"#), system)
        expect(system.contains("“Priced unlike [the rest].”"), "the sentence, the phrase in brackets")
        expect(!system.contains(":scope-start"), "a card has no ends")
        let message = request.messages.first?.text ?? ""
        expect(message.contains("<question>\nthe rest\n</question>"), "the phrase is the question")
        expect(message.contains("- :scope — the shape the rule is checking. Example: :scope"))
        expectEqual(scene.editor.undoHistory.undoName, nil, "a draft: nothing written while the box is typed")
        chips.commit(box)
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).first?.find,
                    [RuleChip(phrase: "the rest", query: #"card:is-a("Listing"):not(:scope)"#)], "the chip and the draft's query")
        expectEqual(scene.editor.undoHistory.undoName, "Change Rules")
        expectEqual(language.requests.count, 1, "no second call")
    },
    test("an answer that comes after the box was done with lands as its own step, Interpret; undone, the words are let be") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel(answers: [#"card:is-a("Listing"):not(:scope)"#])
        language.holdsAnswers = true
        let scene = try RuleScene(board.shapes(), language: language)
        let chips = try require(scene.editor.ruleChips)
        let box = RuleBox(type: board.listing, index: 0)
        let stored = RuleBook.rules(of: board.listing, in: scene.editor).first
        chips.chip(words: "the rest", in: box, text: "Priced unlike the rest.", stored: stored)
        spinRunLoop(until: { language.waiting == 1 })
        chips.commit(box)
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).first?.find, [RuleChip(phrase: "the rest", query: nil)], "written as words")
        language.release()
        spinRunLoop(until: { RuleBook.rules(of: board.listing, in: scene.editor).first?.find.first?.query != nil })
        expectEqual(scene.editor.undoHistory.undoName, "Interpret")
        scene.editor.undo()
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).first?.find, [RuleChip(phrase: "the rest", query: nil)])
        expectEqual(language.requests.count, 1, "undo asks nothing")
    },
    test("a failure says what every host of words says, with its button; Retry asks again") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel()
        language.queue(.notSignedIn)
        let scene = try RuleScene(board.shapes(), language: language)
        let chips = try require(scene.editor.ruleChips)
        let box = RuleBox(type: board.listing, index: 0)
        chips.chip(words: "the rest", in: box, text: "Priced unlike the rest.", stored: RuleBook.rules(of: board.listing, in: scene.editor).first)
        chips.commit(box)
        let chip = RuleChip(phrase: "the rest", query: nil)
        spinRunLoop(until: { chips.preview(of: chip, type: board.listing).status == .notSignedIn })
        expectEqual(chips.look(of: chip, type: board.listing), .failed)
        language.queue(#"card:is-a("Listing")"#)
        chips.retry("the rest", type: board.listing)
        spinRunLoop(until: { RuleBook.rules(of: board.listing, in: scene.editor).first?.find.first?.query != nil })
        expectEqual(scene.editor.undoHistory.undoName, "Interpret")
    },
    test("the line under a chip: its query, the sample, what it found for it by name; ‹ › steps the samples") {
        let board = ChippedListings()
        let scene = try RuleScene(board.shapes())
        let chips = try require(scene.editor.ruleChips)
        let chip = RuleChip(phrase: ChippedListings.others, query: ChippedListings.query)
        _ = chips.preview(of: chip, type: board.listing)
        spinRunLoop(until: { chips.preview(of: chip, type: board.listing).rows != nil })
        var line = chips.preview(of: chip, type: board.listing)
        expectEqual(line.query, ChippedListings.query)
        expectEqual(line.sample, "2021 Toyota Corolla LE", "the type's first shape in file order")
        expectEqual(line.samples, 3)
        expectEqual(line.rows?.map(\.name), ["2019 Toyota Camry SE", "2020 Toyota Prius"])
        chips.step(board.listing, by: 1)
        _ = chips.preview(of: chip, type: board.listing)
        spinRunLoop(until: { chips.preview(of: chip, type: board.listing).rows != nil })
        line = chips.preview(of: chip, type: board.listing)
        expectEqual(line.sample, "2019 Toyota Camry SE")
        expectEqual(line.rows?.map(\.name), ["2021 Toyota Corolla LE", "2020 Toyota Prius"])
        chips.step(board.listing, by: -2)
        expectEqual(chips.preview(of: chip, type: board.listing).sample, "2020 Toyota Prius", "round the ends")
    },
    test("a draft is written over the rule it began from wherever it is by then; one whose rule went is added, never written over another") {
        let board = ChippedListings()
        let scene = try RuleScene(board.shapes())
        let chips = try require(scene.editor.ruleChips), writer = try require(scene.editor.ruleWriter)
        writer.setRules([Rule(says: "First."), Rule(says: "Second."), Rule(says: "Third.")], of: board.listing)
        let second = RuleBox(type: board.listing, index: 1)
        chips.typed("Second, edited.", in: second, stored: Rule(says: "Second."))
        writer.setRules([Rule(says: "Second."), Rule(says: "Third.")], of: board.listing)
        chips.commit(second)
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).map(\.says), ["Second, edited.", "Third."], "the rule it began from, now first")
        let third = RuleBox(type: board.listing, index: 1)
        chips.typed("Third, edited.", in: third, stored: Rule(says: "Third."))
        writer.setRules([Rule(says: "Second, edited.")], of: board.listing)
        chips.commit(third)
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).map(\.says), ["Second, edited.", "Third, edited."], "its rule gone: added")
    },
    test("words nobody is asking about (asked before the file was opened) offer Interpret, which asks") {
        let board = ChippedListings()
        let language = ScriptedLanguageModel(answers: [ChippedListings.query])
        let scene = try RuleScene(board.shapes(query: nil), language: language)
        let chips = try require(scene.editor.ruleChips)
        let chip = RuleChip(phrase: ChippedListings.others, query: nil)
        let line = chips.preview(of: chip, type: board.listing)
        expectEqual(line.status, nil, "not said to be no query: nobody asked")
        expect(line.offersInterpret)
        chips.interpret(ChippedListings.others, type: board.listing)
        spinRunLoop(until: { RuleBook.rules(of: board.listing, in: scene.editor).first?.find.first?.query != nil })
        expectEqual(scene.editor.undoHistory.undoName, "Interpret")
        expectEqual(language.requests.count, 1)
    },
    test("a query typed by hand is written if the engine reads it bound, else refused in its words") {
        let board = ChippedListings()
        let scene = try RuleScene(board.shapes())
        let chips = try require(scene.editor.ruleChips)
        let refusal = chips.write("card:glows", forChip: ChippedListings.others, of: ChippedListings.unlike, type: board.listing)
        expect(refusal?.contains(":glows") ?? false, refusal ?? "nil")
        expectEqual(chips.write("card:not(:scope)", forChip: ChippedListings.others, of: ChippedListings.unlike, type: board.listing), nil)
        expectEqual(RuleBook.rules(of: board.listing, in: scene.editor).first?.find.first?.query, "card:not(:scope)")
        expectEqual(scene.editor.undoHistory.undoName, "Change Rules")
    },
])
