import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import DecisionModels
import Foundation
import LanguageRules
import Mentions
import Selection
import TestKit
import Topology
import Types
import Validation

// A rule's walk: the scope LanguageRules gives Validation's issue walk for the warnings that carry a rule's key. The
// walk's own behavior is ValidationTests'; this holds what the rule gives it.

/// What the model answers, by the title of the shape asked about: a test changes it between checks.
@MainActor private final class Answers {
    var table: [String: [String: Double]]
    init(_ table: [String: [String: Double]]) { self.table = table }
}

/// A scripted model answering each question as the table says for the title of the shape asked about (0.5 for any other).
@MainActor private func answering(_ source: Answers) -> ScriptedDecisionModel {
    let model = ScriptedDecisionModel()
    model.fallback = { request in
        let answers = request.state["shape"]?["title"]?.stringValue.flatMap { source.table[$0] } ?? [:]
        return .success(DecisionAnswers(model: "scripted", yes: Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, answers[$0.id] ?? 0.5) })))
    }
    return model
}

/// The listing board with four listings, in file order: A flags the first rule, B is unsure (the rules read together are
/// between the cutoffs), C flags both, D the second.
@MainActor
private struct Lot {
    let listings = Listings()
    let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID()
    var type: ShapeID { listings.listing }

    var shapes: [AnyShapeRecord] {
        listings.shapes.filter { $0.id != listings.corolla } + [
            card("A", of: [type], id: a, at: CGPoint(x: 300, y: 0)), card("B", of: [type], id: b, at: CGPoint(x: 600, y: 0)),
            card("C", of: [type], id: c, at: CGPoint(x: 900, y: 0)), card("D", of: [type], id: d, at: CGPoint(x: 1200, y: 0))]
    }

    static let table: [String: [String: Double]] = [
        "A": ["all": 0.0, "r0": 0.9, "r1": 0.1],
        "B": ["all": 0.5, "r0": 0.9, "r1": 0.9],
        "C": ["all": 0.0, "r0": 0.95, "r1": 0.85],
        "D": ["all": 0.0, "r0": 0.1, "r1": 0.9],
    ]

    var first: RuleKey { RuleKey(type: type, says: Listings.agrees) }
    var second: RuleKey { RuleKey(type: type, says: Listings.noDamage) }

    func scene(answers: Answers = Answers(Lot.table)) throws -> RuleScene {
        let scene = try RuleScene(shapes, decisions: answering(answers))
        scene.settle()
        return scene
    }
}

extension IssueWalk {
    fileprivate var shapes: [ShapeID] { rows.map(\.shape) }
    fileprivate var states: [IssueRowState] { rows.map(\.state) }
    fileprivate var at: ShapeID? { currentRow?.shape }
}

extension RuleScene {
    /// Lets the checks settle, and the walk read what the answers brought on its next turn.
    fileprivate func land() {
        settle()
        scheduler.advance(by: .zero)
    }
}

@MainActor private func scope(_ key: RuleKey, in scene: RuleScene) throws -> IssueScope {
    try require(scene.editor.registry.issueScope(for: key.source, in: scene.editor))
}

@MainActor private func walk(_ scene: RuleScene) throws -> IssueWalk { try require(scene.editor.issueWalk) }

@MainActor let ruleWalkTests = Suite("A rule's walk", [
    test("a rule's stops are the shapes it flags, in board order; a shape the rules are unsure of is no stop; each rule has its own") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .first)
        expect(!walk.isGathering, "the rule says its shapes: nothing is asked")
        expectEqual(walk.shapes, [lot.a, lot.c], "A and C flag the first rule; B is unsure")
        expectEqual(walk.at, lot.a)
        expectEqual(scene.editor.selectedShapeIDs, [lot.a])
        walk.step(forward: true)
        expectEqual(walk.at, lot.c)
        walk.step(forward: true)
        expectEqual(walk.at, lot.a, "round the end")
        expectEqual(walk.rows.map(\.message), [Listings.agrees, Listings.agrees], "the rule's sentence, word for word")
        walk.begin(try scope(lot.second, in: scene), at: .first)
        expectEqual(walk.shapes, [lot.c, lot.d], "a shape with both rules' warnings is a stop in each")
        expect(!walk.shapes.contains(lot.b))
    },
    test("a rule's scope says its place among the type's own rules and its type, and is found for a rule that exists, by its source") {
        let lot = Lot()
        let scene = try lot.scene()
        let first = try scope(lot.first, in: scene), second = try scope(lot.second, in: scene)
        let chip = IssueScopeChip("Listing", swatch: try require(scene.editor.types).look(of: lot.type).swatch)
        expectEqual(first.label(scene.editor), IssueScopeLabel("Rule 1", owner: lot.type, spoken: "Rule 1 of Listing", chip: chip), "the type's chip, in the color Types gives it")
        expectEqual(second.label(scene.editor), IssueScopeLabel("Rule 2", owner: lot.type, spoken: "Rule 2 of Listing", chip: chip))
        expect(first.id != second.id)
        let registry = scene.editor.registry
        expect(registry.issueScope(for: RuleKey(type: lot.type, says: "No such rule.").source, in: scene.editor) == nil, "a sentence the type does not hold")
        expect(registry.issueScope(for: RuleKey(type: lot.listings.car, says: Listings.agrees).source, in: scene.editor) == nil, "Car holds no rules")
        expect(registry.issueScope(for: IssueSource(plugin: RuleValidationPlugin.id, key: "nonsense"), in: scene.editor) == nil)
        expect(registry.issueScope(for: IssueSource(plugin: "someone-else", key: lot.first.source.key), in: scene.editor) == nil, "only the plugin that owns the source")
    },
    test("the scope includes the warnings of its rule's key and no other, and the chip warnings of a type carry none") {
        let lot = Lot()
        let scene = try lot.scene()
        let scope = try scope(lot.first, in: scene)
        let issues = scene.editor.validation?.result(for: lot.c)?.issues.filter { $0.severity == .warning } ?? []
        expectEqual(issues.map { scope.includes($0) }, [true, false], "C flags both rules, the first the higher")
        expect(!scope.includes(.warning("A warning of no source.")))
    },
    test("Ignore is one step that keeps the place: the row reads ignored, the count drops, the number stays, undo brings it back") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .first)
        expect(walk.canIgnore)
        let before = scene.editor.undoHistory.undoName
        expect(walk.ignoreCurrent())
        expectEqual(scene.editor.undoHistory.undoName, RulesStyle.ignoreRule, "one undo step, named")
        expectEqual(scene.editor.document[lot.a]?[IgnoredRulesProperty.self], [Listings.agrees])
        expectEqual(walk.shapes, [lot.a, lot.c], "the row stays")
        expectEqual(walk.states, [.ignored, .open])
        expectEqual(walk.total, 1)
        expectEqual(walk.at, lot.a, "the place does not move")
        expectEqual(walk.number, 1)
        scene.settle()
        expectEqual(walk.states, [.ignored, .open], "and it stays so as the model answers again")
        scene.editor.undo()
        expectEqual(walk.states, [.open, .open])
        expectEqual(scene.editor.document[lot.a]?[IgnoredRulesProperty.self], nil)
        expectEqual(walk.at, lot.a)
        expectEqual(scene.editor.undoHistory.undoName, before, "one undo took the whole ignore back")
    },
    test("a redone Ignore and Ignore Rule from the shape's menu read ignored in a rule's walk (CompositionTests: the All Issues walk's), and a fix still reads holds") {
        let lot = Lot()
        let answers = Answers(Lot.table)
        let scene = try lot.scene(answers: answers)
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .first)
        scene.land()
        let a = { walk.rows.first { $0.shape == lot.a && $0.message == Listings.agrees }?.state }
        expectEqual(a(), .open, "A is a stop")
        expect(walk.ignoreCurrent())
        expectEqual(a(), .ignored)
        scene.editor.undo()
        expectEqual(a(), .open, "found again")
        scene.editor.redo()
        expectEqual(a(), .ignored, "a redo of the Ignore reads ignored, not holds")
        scene.editor.undo()
        expectEqual(a(), .open)
        scene.editor.selectedShapeIDs = [lot.a]
        let menu = try require(scene.h.secondaryClick(at: CGPoint(x: 400, y: 30)))
        try menu.choose("Ignore Rule", Listings.agrees.count <= 60 ? Listings.agrees : String(Listings.agrees.prefix(59)) + "…")
        scene.land()
        expectEqual(scene.editor.document[lot.a]?[IgnoredRulesProperty.self], [Listings.agrees])
        expectEqual(a(), .ignored, "Ignore Rule from the menu is an ignore")
        scene.editor.undo()
        expectEqual(a(), .open)
        // A fix: the model no longer flags A; nothing was set aside.
        answers.table["A"] = ["all": 1.0, "r0": 0.1, "r1": 0.1]
        scene.editor.transact("Reword") { $0.update(lot.a, as: Card.self) { $0.props.text = MentionText(plain: "Different words.") } }
        scene.land()
        expectEqual(a(), .holds, "a fix reads holds")
    },
    test("a rule reworded keeps its walk, which follows the new words and the place on its shape") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .shape(lot.c))
        expectEqual(walk.at, lot.c)
        let reworded = "The description agrees with the car's year and model."
        scene.editor.transact("Change JSON") {
            $0.update(lot.type) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [reworded, Listings.noDamage])) }
        }
        expect(walk.isRunning, "a reworded rule is the same walk")
        scene.settle()
        scene.land()
        expectEqual(walk.shapes, [lot.a, lot.c], "the stops of the new words, as the answers come")
        expectEqual(walk.rows.map(\.message), [reworded, reworded])
        expectEqual(walk.at, lot.c, "the place stays on its shape")
        expectEqual(walk.currentRow?.state, .open)
        expectEqual(walk.scope?.label(scene.editor)?.title, "Rule 1")
        scene.editor.undo()
        scene.land()
        expectEqual(walk.rows.map(\.message), [Listings.agrees, Listings.agrees], "and an undo of the reword follows it back")
        expectEqual(walk.at, lot.c)
    },
    test("a rule moved among the type's rules is the same walk, with the number it has now") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .shape(lot.c))
        scene.editor.transact("Change JSON") {
            $0.update(lot.type) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [Listings.noDamage, Listings.agrees])) }
        }
        scene.land()
        expect(walk.isRunning)
        expectEqual(walk.scope?.label(scene.editor)?.title, "Rule 2")
        // The scripted model answers by question id, which moved with the rule: the walk follows what flags it now.
        expectEqual(Set(walk.rows.filter(\.isOpen).map(\.shape)), scene.checks.flagged(by: lot.first), "the first sentence's warnings, wherever the rule is")
        expectEqual(Set(walk.rows.filter(\.isOpen).map(\.message)), [Listings.agrees])
        expectEqual(walk.at, lot.c, "the place on its shape")
    },
    test("a rule moved among the type's rules keeps the rows it set aside: the stop it ignored is still ignored, the place on it") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .first)
        expect(walk.ignoreCurrent())
        expectEqual(walk.states, [.ignored, .open])
        scene.editor.transact("Change JSON") {
            $0.update(lot.type) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [Listings.noDamage, Listings.agrees])) }
        }
        scene.land()
        expect(walk.isRunning)
        expectEqual(walk.scope?.label(scene.editor)?.title, "Rule 2")
        expectEqual(walk.rows.first { $0.shape == lot.a }?.state, .ignored, "the ignore is the rule's, wherever the rule is")
        expectEqual(walk.at, lot.a, "and the place is on it")
        // The scripted model answers by question id, which moved with the rule, so what flags is what it says now: the ignored row
        // stays first and ignored, every other row is open and flagged now, and no shape has two rows.
        let flagged = scene.checks.flagged(by: lot.first)
        expectEqual(walk.total, flagged.subtracting([lot.a]).count, "the rows that are open are the shapes flagged now, less the ignored one")
        expectEqual(walk.states, [.ignored] + Array(repeating: .open, count: walk.total))
        expectEqual(Set(walk.shapes).count, walk.shapes.count, "no row doubled")
    },
    test("the answers change while a rule's walk runs: a shape no longer flagged reads holds, one newly flagged joins in board order, one gone unsure still holds its row") {
        let answers = Answers(Lot.table)
        let lot = Lot()
        let scene = try lot.scene(answers: answers)
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .shape(lot.c))
        expectEqual(walk.shapes, [lot.a, lot.c])
        expectEqual(walk.number, 2)
        answers.table["A"] = ["all": 1.0, "r0": 0.1, "r1": 0.1]
        answers.table["B"] = ["all": 0.0, "r0": 0.9, "r1": 0.9]
        for shape in [lot.a, lot.b] {
            scene.editor.transact("Reword") { $0.update(shape, as: Card.self) { $0.props.text = MentionText(plain: "Different words.") } }
        }
        scene.land()
        expectEqual(walk.shapes, [lot.a, lot.b, lot.c], "B is flagged now, between A and C")
        expectEqual(walk.states, [.holds, .open, .open], "A no longer is")
        expectEqual(walk.at, lot.c, "the current stop stays")
        expectEqual(walk.number, 2, "its number follows the stop that arrived before it")
        expectEqual(walk.total, 2)
        answers.table["C"] = ["all": 0.5, "r0": 0.95, "r1": 0.85]
        scene.editor.transact("Reword") { $0.update(lot.c, as: Card.self) { $0.props.text = MentionText(plain: "Other words.") } }
        scene.land()
        expectEqual(walk.shapes, [lot.a, lot.b, lot.c], "a shape the rules are unsure of is no stop, and keeps its row")
        expectEqual(walk.states, [.holds, .open, .holds])
        expectEqual(walk.at, lot.c)
        expectEqual(walk.total, 1)
        expectEqual(scene.editor.selectedShapeIDs, [lot.c], "nothing was selected by the answers")
    },
    test("a step is announced with the shape's title, and the board only when it changes") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .first)
        let first = try require(scene.editor.announcements.last)
        expect(first.hasPrefix("Issue 1 of 2, ") && first.hasSuffix(", A, \(Listings.agrees)"), first)
        walk.step(forward: true)
        expectEqual(scene.editor.announcements.last, "Issue 2 of 2, C, \(Listings.agrees)")
    },
    test("a rule deleted ends the walk, and so does the type losing its rules") {
        let lot = Lot()
        let scene = try lot.scene()
        let walk = try walk(scene)
        walk.begin(try scope(lot.first, in: scene), at: .first)
        scene.editor.transact("Change JSON") {
            $0.update(lot.type) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [Listings.noDamage])) }
        }
        expect(!walk.isRunning, "its rule is gone")
        expectEqual(walk.rows.count, 0)
        walk.begin(try scope(lot.second, in: scene), at: .first)
        expect(walk.isRunning, "the other rule is another walk")
        scene.editor.transact("Change JSON") { $0.update(lot.type) { $0[TypeSchemaProperty.self] = SchemaText(schema(rules: [])) } }
        expect(!walk.isRunning)
    },
])
