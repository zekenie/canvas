import Canvas
import CanvasRPC
import CanvasTesting
import DecisionModels
import CoreGraphics
import Foundation
import LanguageModels
import LanguageRules
import Mentions
import Queries
import TestKit
import Titles
import Topology
import Types
import Validation

/// The listing board's types: Listing, two rules, built on Car; a listing of it.
@MainActor
struct Listings {
    let car = ShapeID(), listing = ShapeID(), corolla = ShapeID()
    static let agrees = "The description agrees with the car's year, model and mileage."
    static let noDamage = "The description mentions no damage or wear."

    var shapes: [AnyShapeRecord] {
        [typeCard("Car", words: "A car: its year, make, model and the miles on it.", id: car),
         typeCard("Listing", rules: [Self.agrees, Self.noDamage], words: "A car for sale, described by its seller.", builds: [car], id: listing,
                  at: CGPoint(x: 0, y: 100)),
         card("2021 Toyota Corolla LE", of: [listing], words: "Barely driven, garage kept, like new inside and out.", id: corolla)]
    }
}

/// A scripted model answering every request as `answers` says, by question id; any other question 0.5.
@MainActor func answering(_ answers: [String: Double]) -> ScriptedDecisionModel {
    let model = ScriptedDecisionModel()
    model.fallback = { request in
        .success(DecisionAnswers(model: "scripted", yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, answers[$0.id] ?? 0.5) })))
    }
    return model
}

@MainActor let ruleContextTests = Suite("What a rule sees", [
    test("a shape's state: today, the shape in full, its types most specific first with their words, where it is, and what's beside it by name") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(["all": 0.9]))
        scene.settle()
        let sent = try require(scene.checks.check(of: board.corolla)?.verdict?.sent)
        expectEqual(sent.state, [
            "today": "2026-10-29",
            "shape": ["kind": "card", "title": "2021 Toyota Corolla LE", "is": ["Listing"], "words": "Barely driven, garage kept, like new inside and out."],
            "its types": [["type": "Listing", "words": "A car for sale, described by its seller.", "builds on": ["Car"]],
                          ["type": "Car", "words": "A car: its year, make, model and the miles on it."]],
            "in": ["board": "the board's top level"],
            "beside it, in the same place": [["title": "Car"], ["title": "Listing", "is": ["Car"]]],
        ])
        expectEqual(sent.preface?.hasPrefix("These rules come from the car's types"), true)
    },
    test("past forty shapes beside it, they're counted by type") {
        let board = Listings()
        let others = (0..<41).map { card("Other \($0)", of: [board.car], at: CGPoint(x: 600 + Double($0) * 10, y: 0)) }
        let scene = try RuleScene(board.shapes + others, decisions: answering(["all": 0.1]))
        scene.settle()
        let sent = try require(scene.checks.check(of: board.corolla)?.verdict?.sent)
        expectEqual(sent.state["beside it, in the same place"], ["count": 43, "by type": ["Car": 42, "type": 1]], "Listing builds on Car; Car is a type of none")
    },
])

@MainActor let ruleCheckTests = Suite("The checks", [
    test("once the file is quiet a shape of a type with rules is asked once, and what flags it read together is a warning quoting the rule") {
        let board = Listings()
        let decisions = answering(["all": 0.11, "r0": 0.93, "r1": 0.27])
        let scene = try RuleScene(board.shapes, decisions: decisions)
        scene.scheduler.advance(by: .zero)
        expectEqual(decisions.requests.count, 0, "nothing asked before the file is quiet")
        expect(scene.checks.isBusy, "a pass is coming")
        scene.settle()
        expectEqual(decisions.requests.count, 1, "the listing; no type is asked about")
        expectEqual(scene.warnings(of: board.corolla), [Listings.agrees], "the rule that fails, word for word")
        let verdict = try require(scene.checks.check(of: board.corolla)?.verdict)
        expect(abs((verdict.together ?? 0) - 0.89) < 1e-9, "\(String(describing: verdict.together))")
        expectEqual(verdict.each.map { $0 ?? -1 }, [0.93, 0.27])
        expectEqual(verdict.rules.map(\.rule.says), [Listings.agrees, Listings.noDamage])
        expectEqual(scene.warnings(of: board.listing), [], "a type is never checked")
    },
    test("a warning's source is its rule's key, which leads back to flagged(by:); its Ignore has the ignore role; two rules carry two keys") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(["all": 0.0, "r0": 0.75, "r1": 0.9]))
        scene.settle()
        let issues = (scene.editor.validation?.result(for: board.corolla)?.issues ?? []).filter { $0.severity == .warning }
        expectEqual(issues.map(\.message), [Listings.noDamage, Listings.agrees])
        let keys = issues.compactMap { $0.source.flatMap(RuleKey.init(source:)) }
        expectEqual(keys, [RuleKey(type: board.listing, says: Listings.noDamage), RuleKey(type: board.listing, says: Listings.agrees)])
        expectEqual(Set(issues.compactMap(\.source)).count, 2)
        expectEqual(issues.first?.source?.plugin, RuleValidationPlugin.id)
        for (issue, key) in zip(issues, keys) { expectEqual(scene.checks.flagged(by: key), [board.corolla], issue.message) }
        expectEqual(issues.first?.actions.map(\.role), [.ignore, nil])
        expectEqual(RuleKey(source: IssueSource(plugin: "other", key: issues[0].source?.key ?? "")), nil, "another plugin's source is no rule's")
        expectEqual(RuleKey(source: IssueSource(plugin: RuleValidationPlugin.id, key: "nonsense")), nil)
        let ignore = try require(issues[0].actions.first { $0.role == .ignore })
        ignore.perform()
        scene.settle()
        let left = (scene.editor.validation?.result(for: board.corolla)?.issues ?? []).filter { $0.severity == .warning }
        expectEqual(left.compactMap { $0.source.flatMap(RuleKey.init(source:)) }, [keys[1]], "only the other rule's key is left")
        expectEqual(scene.checks.flagged(by: keys[0]), [], "the ignored rule flags the shape no more")
        expectEqual(scene.checks.flagged(by: keys[1]), [board.corolla])
    },
    test("a rule's key survives a sentence with a bar in it, and a key whose first part is no id is no rule's") {
        let key = RuleKey(type: ShapeID(UUID()), says: "Fits | and agrees.")
        expectEqual(RuleKey(source: key.source), key)
        expectEqual(RuleKey(source: IssueSource(plugin: RuleValidationPlugin.id, key: "x|y")), nil)
    },
    test("a reworded rule's warning carries the new key") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(["all": 0.0, "r0": 0.9]))
        scene.settle()
        let before = try require(scene.editor.validation?.result(for: board.corolla)?.issues.first?.source)
        let reworded = "The description agrees with the car's year and model."
        scene.editor.transact("Change JSON") {
            $0.update(board.listing) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [reworded, Listings.noDamage])) }
        }
        scene.settle()
        let after = try require(scene.editor.validation?.result(for: board.corolla)?.issues.first?.source)
        expect(after != before)
        expectEqual(RuleKey(source: after), RuleKey(type: board.listing, says: reworded))
        expectEqual(scene.checks.flagged(by: try require(RuleKey(source: before))), [], "the old key flags nothing")
    },
    test("read together the rules hold: no warning, though one rule's own answer would flag; unsure shows nothing") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(["all": 0.95, "r0": 0.9, "r1": 0.1]))
        scene.settle()
        expectEqual(scene.warnings(of: board.corolla), [])
        let unsure = try RuleScene(board.shapes, decisions: answering(["all": 0.5, "r0": 0.9, "r1": 0.1]))
        unsure.settle()
        expectEqual(unsure.warnings(of: board.corolla), [])
    },
    test("every rule that flags is a warning, highest first; where none flags alone, the rule answered highest") {
        let board = Listings()
        let both = try RuleScene(board.shapes, decisions: answering(["all": 0.0, "r0": 0.75, "r1": 0.9]))
        both.settle()
        expectEqual(both.warnings(of: board.corolla), [Listings.noDamage, Listings.agrees])
        let neither = try RuleScene(board.shapes, decisions: answering(["all": 0.1, "r0": 0.4, "r1": 0.6]))
        neither.settle()
        expectEqual(neither.warnings(of: board.corolla), [Listings.noDamage])
    },
    test("a rule the shape ignores gives no warning, and with the one that flagged ignored there is none; an ignore lapses with its sentence") {
        let board = Listings()
        let scene = try RuleScene(board.shapes, decisions: answering(["all": 0.0, "r0": 0.9, "r1": 0.8]))
        scene.settle()
        scene.editor.transact("Ignore Rule") { $0.update(board.corolla) { $0[IgnoredRulesProperty.self] = [Listings.agrees] } }
        expectEqual(scene.warnings(of: board.corolla), [Listings.noDamage])
        let alone = try RuleScene(board.shapes, decisions: answering(["all": 0.0, "r0": 0.9, "r1": 0.1]))
        alone.settle()
        alone.editor.transact("Ignore Rule") { $0.update(board.corolla) { $0[IgnoredRulesProperty.self] = [Listings.agrees] } }
        expectEqual(alone.warnings(of: board.corolla), [], "the one that flagged is ignored, and no other does")
        alone.editor.transact("Ignore Rule") { $0.update(board.corolla) { $0[IgnoredRulesProperty.self] = ["The description agrees with the car's year and model."] } }
        expectEqual(alone.warnings(of: board.corolla), [Listings.agrees], "another sentence is another rule")
    },
    test("a commit to the shape asks again once quiet; a move doesn't; the same state asks the model nothing again") {
        let board = Listings()
        let decisions = answering(["all": 0.1])
        let scene = try RuleScene(board.shapes, decisions: decisions)
        scene.settle()
        expectEqual(decisions.requests.count, 1)
        scene.editor.transact("Move") { $0.moveBox(board.corolla, to: CGPoint(x: 310, y: 0)) }
        expect(!scene.checks.isBusy, "a move marks nothing, the shape's or those beside it")
        scene.settle()
        expectEqual(decisions.requests.count, 1, "a move asks nothing")
        scene.editor.transact("Title") { $0.update(board.corolla) { $0[TitleProperty.self] = "2021 Toyota Corolla XLE" } }
        scene.settle()
        expectEqual(decisions.requests.count, 2, "asked about what it is now")
        scene.editor.transact("Title") { $0.update(board.corolla) { $0[TitleProperty.self] = "2021 Toyota Corolla LE" } }
        scene.settle()
        expectEqual(decisions.requests.count, 2, "as it was before: answered from what the model said today")
    },
    test("a type's rules changing asks its shapes again; a shape put beside one asks it again; a shape whose type loses its rules loses its warning") {
        let board = Listings()
        let decisions = answering(["all": 0.0, "r0": 0.9])
        let scene = try RuleScene(board.shapes, decisions: decisions)
        scene.settle()
        expectEqual(scene.warnings(of: board.corolla), [Listings.agrees])
        scene.editor.transact("Change JSON") {
            $0.update(board.listing) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [Listings.agrees, Listings.noDamage, "It is for sale."])) }
        }
        scene.settle()
        expectEqual(decisions.requests.count, 2)
        expectEqual(decisions.lastRequest?.questions.count, 4)
        _ = scene.editor.add(Card(frame: CGRect(x: 900, y: 0, width: 200, height: 60), text: "A note beside it"))
        scene.settle()
        expectEqual(decisions.requests.count, 3, "what's beside it changed")
        scene.editor.transact("Change JSON") { $0.update(board.listing) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [])) } }
        scene.settle()
        expectEqual(scene.warnings(of: board.corolla), [], "no rule checks it now")
        expectEqual(scene.checks.check(of: board.corolla), nil)
    },
    test("a shape put in a container is beside other shapes: it and those beside it before are asked again; the container moved asks none") {
        let board = Listings()
        let other = card("2019 Toyota Camry SE", of: [board.listing], at: CGPoint(x: 600, y: 0))
        let corral = AnyShapeRecord(ShapeRecord(id: ShapeID(), Corral(CGRect(x: 0, y: 400, width: 1000, height: 400))))
        let decisions = answering(["all": 0.1])
        let scene = try RuleScene(board.shapes + [other, corral], decisions: decisions)
        scene.settle()
        expectEqual(decisions.requests.count, 2)
        scene.editor.transact("Move") { $0.moveBox(other.id, to: CGPoint(x: 600, y: 500)) }
        scene.editor.put([other.id], in: corral.id)
        scene.settle()
        expectEqual(Set(decisions.requests.dropFirst(2).compactMap { $0.state["shape"]?["title"]?.stringValue }),
                    ["2021 Toyota Corolla LE", "2019 Toyota Camry SE"], "the one put in, and the one it left")
        let camry = decisions.requests.dropFirst(2).first { $0.state["shape"]?["title"]?.stringValue == "2019 Toyota Camry SE" }
        expectEqual(camry?.state["in"]?["container"], "corral")
        let asked = decisions.requests.count
        scene.editor.transact("Move") { $0.moveBox(corral.id, to: CGPoint(x: 0, y: 500)) }
        scene.settle()
        expectEqual(decisions.requests.count, asked, "what it holds moved with it, beside the same shapes")
    },
    test("a name a state says, renamed, asks it again: a type of a shape beside it") {
        let board = Listings()
        let sedan = ShapeID()
        let neighbor = card("Showroom note", of: [sedan], at: CGPoint(x: 600, y: 0))
        let decisions = answering(["all": 0.1])
        let scene = try RuleScene(board.shapes + [typeCard("Sedan", id: sedan, at: CGPoint(x: 0, y: 200)), neighbor], decisions: decisions)
        scene.settle()
        let asked = decisions.requests.count
        scene.editor.transact("Title") { $0.update(sedan) { $0[TitleProperty.self] = "Saloon" } }
        scene.settle()
        expect(decisions.requests.count > asked, "the Corolla's state says the Showroom note is a Sedan")
        expectEqual(decisions.lastRequest?.state["beside it, in the same place"]?.arrayValue?.contains(["title": "Showroom note", "is": ["Saloon"]]), true)
    },
    test("the day turning over asks every shape again: the day is in what's sent") {
        let board = Listings()
        let decisions = answering(["all": 0.1])
        let scene = try RuleScene(board.shapes, decisions: decisions)
        scene.settle()
        expectEqual(decisions.requests.count, 1)
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        scene.settle()
        expectEqual(decisions.requests.count, 1, "the same day: nothing asked")
        scene.checks.today = { "2026-10-30" }
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        scene.settle()
        expectEqual(decisions.requests.count, 2)
        expectEqual(decisions.lastRequest?.state["today"], "2026-10-30")
    },
    test("without a key no call waiting is made, every shape says why, and the key saved asks again") {
        let board = Listings()
        let more = (0..<9).map { card("Car \($0)", of: [board.listing], at: CGPoint(x: 600 + Double($0) * 220, y: 0)) }
        let decisions = ScriptedDecisionModel()
        decisions.fallback = { _ in .failure(DecisionModelError(.noKey, provider: ScriptedDecisionModel.provider)) }
        let scene = try RuleScene(board.shapes + more, decisions: decisions)
        scene.settle()
        expectEqual(decisions.requests.count, RuleChecks.inFlight, "those out at once; the two waiting were never made")
        for id in [board.corolla] + more.map(\.id) {
            guard case let .failed(error, _)? = scene.checks.check(of: id) else { expect(false, "\(id) failed"); continue }
            expectEqual(error.message, "No Scripted key")
        }
        decisions.answerAll(0.1)
        NotificationCenter.default.post(name: .decisionModelKeyDidChange, object: nil)
        scene.scheduler.advance(by: .zero)
        spinRunLoop(until: { !scene.checks.isBusy })
        expectEqual(decisions.requests.count, RuleChecks.inFlight + 10, "every one asked again")
        if case .checked? = scene.checks.check(of: board.corolla) {} else { expect(false, "checked") }
    },
    test("while checks are out Topology settles, so a query of :warned waits for them, and lists the warning") {
        let board = Listings()
        let decisions = answering(["all": 0.0, "r0": 0.9])
        decisions.holdsAnswers = true
        let scene = try RuleScene(board.shapes, decisions: decisions)
        scene.scheduler.advance(by: .zero)
        scene.scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { decisions.waiting == 1 })
        expect(scene.editor.topology?.isSettling == true, "a call is out")
        let queries = try require(scene.editor.queries)
        var rows: [QueryRow]?
        Task { rows = try? await queries.run(QueryRequest(":warned", limit: 10, properties: .none, settle: .seconds(2))).rows }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        expect(rows == nil, "waiting for the answer")
        decisions.release()
        spinRunLoop(until: { rows != nil })
        expectEqual(rows?.map(\.id), [board.corolla])
        expectEqual(rows?.first?.problems, [ShapeProblem(field: nil, path: nil, class: "warning", message: Listings.agrees)])
        expect(scene.editor.topology?.isSettling == false)
    },
    test("an editor let go cancels the calls it has out") {
        let board = Listings()
        let decisions = answering(["all": 0.1])
        decisions.holdsAnswers = true
        var scene: RuleScene? = try RuleScene(board.shapes, decisions: decisions)
        scene?.scheduler.advance(by: .zero)
        scene?.scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { decisions.waiting == 1 })
        scene = nil
        // Let go of first, the call ends on a later turn: waiting empties before it has.
        spinRunLoop(until: { decisions.waiting == 0 && decisions.answered == 1 })
        expectEqual(decisions.answered, 1, "the held call ended, cancelled")
    },
    test("without the product's words nothing is asked") {
        let board = Listings()
        let decisions = answering(["all": 0.0, "r0": 0.9])
        let scene = try RuleScene(board.shapes, decisions: decisions, prompts: nil)
        scene.settle()
        expectEqual(decisions.requests.count, 0)
        expectEqual(scene.warnings(of: board.corolla), [])
    },
])

@MainActor let heldTests = Suite("$rules held aside", [
    test("Types holds $rules as it holds $color: the model is never sent them, a schema written whole keeps them, a change to them alone is none") {
        let scene = try RuleScene([])
        let held = scene.editor.registry.heldDirectives
        let withRules = #"{"properties": {"$rules": {"const": [{"says": "It's red."}]}, "a": {}}}"#
        expectEqual(held.stripped(withRules), #"{"properties": {"a": {}}}"#)
        expectEqual(held.carried(from: withRules, into: #"{"properties": {"b": {}}}"#),
                    #"{"properties": {"$rules": {"const": [{"says": "It's red."}]}, "b": {}}}"#)
        expect(held.sameButHeld(withRules, #"{"properties": {"a": {}}}"#))
        expect(held.isHeld("$rules"))
        expect(!HeldDirectives().isHeld("$rules"), "Types' own are $color and $autofill")
        expect(scene.editor.registry.report.contains("property ignoredRules · type directive $rules · service RuleChecks"), scene.editor.registry.report)
    },
    test("a type whose rules alone change asks its sync nothing") {
        let language = ScriptedLanguageModel()
        let type = ShapeID()
        let scheduler = ManualScheduler()
        let editor = CanvasEditor(registry: try Registry(plugins: rulePlugins(decisions: ScriptedDecisionModel(), language: language)),
                                  file: CanvasFile(root: CanvasDocument(shapes: [typeCard("Car", words: "A car.", id: type)])), scheduler: scheduler)
        editor.transact("Change JSON") { $0.update(type) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: ["It has four wheels."])) } }
        scheduler.advance(by: .seconds(10))
        spinRunLoop(until: { true })
        expectEqual(language.requests.count, 0, "rules are no business of the words'")
    },
])
