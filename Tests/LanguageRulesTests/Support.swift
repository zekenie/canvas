import Adornments
import AppKit
import Canvas
import CanvasRPC
import CanvasTesting
import ContextMenus
import DecisionModels
import DetailPanel
import Foundation
import Keyboard
import LanguageModels
import LanguageRules
import Mentions
import ProseMaps
import Queries
import QueryTranslation
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Types
import Validation

/// A box of words that can be a type and be of one, and is checked against its types' rules: what a note is to
/// LanguageRules, with no note.
struct Card: BoxShapeProps {
    static let kind: ShapeKind = "card"
    static let properties = Properties<Card>(title: "Card") {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the card says.")
    }
    var frame: CGRect
    var text: MentionText
    init(frame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 60), text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    init() { self.init(text: "") }
}

@MainActor
enum CardStyle {
    static let text = MentionTextStyle(font: .systemFont(ofSize: 14), color: .black, lineHeight: 18)
}

extension ShapeRecord where Props == Card {
    @MainActor var placement: MentionTextPlacement { MentionTextPlacement(props.text, in: frame.insetBy(dx: 8, dy: 8), style: CardStyle.text) }
}

@MainActor
struct CardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Card>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.white.cgColor)
        context.cg.fill(shape.frame)
        context.drawMentionText(shape.placement)
    }
}

struct CardsPlugin: CanvasPlugin {
    var id: PluginID { "cards" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(CardDefinition()) { card in
            card.title()
            card.mentionText { [$0.placement] }
            card.mentionable(untitled: { $0.props.text.firstLine })
            card.typeWords(\.text, drawnIn: { $0.placement }, fitting: { _ in })
            card.canBeType()
            card.typeable()
            card.checkedByRules()
        }
    }
}

/// The prompts the product ships, read from the repository (this executable isn't the product, so `ShippedText` has
/// none).
@MainActor let shippedPrompts: RulePrompts = {
    let text = try! String(contentsOfFile: "Shipped/rule-prompt.txt", encoding: .utf8)
    return try! RulePrompts(text: text)
}()

/// What a query bound to the shape checked adds to its request, as the product ships it, read from the repository.
@MainActor let shippedBound: BoundWords = BoundWords(text: try! String(contentsOfFile: "Shipped/ask-bound.txt", encoding: .utf8))!

/// The system prompt and stored-query line the tests' translator asks with (the product's prompt is QueryPromptTests').
let askPrompt = "You write one query."
let storedRule = "The query is stored and run later."

/// Every plugin rules need: cards, the types they are of, Validation, the queries `:warned` is asked through, a
/// scripted language model for a type's sync, a chip's words and `decisions`, a scripted decision model.
@MainActor func rulePlugins(decisions: ScriptedDecisionModel, language: ScriptedLanguageModel = ScriptedLanguageModel(),
                            prompts: RulePrompts? = shippedPrompts) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), CardsPlugin(), CorralsPlugin(), ValidationPlugin(), AdornmentsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(),
     TypesPlugin(), TypeValidationPlugin(), LanguageModelsPlugin(model: language), ProseMapsPlugin(), DecisionModelsPlugin(model: decisions),
     prompts.map { LanguageRulesPlugin(prompts: $0) } ?? LanguageRulesPlugin(), RuleValidationPlugin(),
     QueriesPlugin(), TitleQueriesPlugin(), QueryTranslationPlugin(prompt: askPrompt, referenceRule: storedRule, bound: shippedBound),
     ValidationQueriesPlugin(), TypeQueriesPlugin(), ValidationDetailsPlugin(), IssueWalkPlugin(), TypeDetailsPlugin(), RuleDetailsPlugin()]
}

/// A board of cards being checked: the editor, its scheduler, and the scripted decision model it asks; a harness over
/// them for a click's menu.
@MainActor
struct RuleScene {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }
    var scheduler: ManualScheduler { h.scheduler }
    let decisions: ScriptedDecisionModel

    /// `walk: false` leaves Validation's issue walk out of the list, as a list that has none.
    init(_ shapes: [AnyShapeRecord], decisions: ScriptedDecisionModel = ScriptedDecisionModel(), language: ScriptedLanguageModel = ScriptedLanguageModel(),
         prompts: RulePrompts? = shippedPrompts, walk: Bool = true) throws {
        self.decisions = decisions
        let plugins = rulePlugins(decisions: decisions, language: language, prompts: prompts).filter { walk || $0.id != IssueWalkPlugin().id }
        let registry = try Registry(plugins: plugins)
        h = EditorHarness { CanvasEditor(registry: registry, file: CanvasFile(root: CanvasDocument(shapes: shapes)), scheduler: $0) }
        editor.ruleChecks?.today = { "2026-10-29" }
    }

    var checks: RuleChecks { editor.ruleChecks! }

    /// Lets the checks' wait for quiet run out, and the calls they make land.
    func settle() {
        scheduler.advance(by: .zero)
        scheduler.advance(by: RuleChecks.quiet)
        spinRunLoop(until: { !checks.isBusy })
    }

    /// What Validation says of a shape now.
    func warnings(of id: ShapeID) -> [String] {
        (editor.validation?.result(for: id)?.issues ?? []).filter { $0.severity == .warning }.map(\.message)
    }
}

/// A type: a card holding `schema`, called `title`, saying `words`, built on `builds`.
@MainActor func typeCard(_ title: String, rules: [String] = [], words: String = "", builds: [ShapeID] = [], id: ShapeID = ShapeID(),
                         at origin: CGPoint = CGPoint(x: 0, y: 0)) -> AnyShapeRecord {
    var record = ShapeRecord(id: id, Card(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 60)), text: MentionText(plain: words)))
    record[TypeSchemaProperty.self] = SchemaText(schema(rules: rules))
    record[TitleProperty.self] = title
    if !builds.isEmpty { record[IsAProperty.self] = builds.map(TypeLink.init) }
    return AnyShapeRecord(record)
}

/// A schema of no fields that holds `rules`.
func schema(rules: [String]) -> String {
    guard !rules.isEmpty else { return #"{"type": "object", "properties": {}}"# }
    let listed = rules.map { #"{"says": \#(JSONValue.string($0).compactText)}"# }.joined(separator: ", ")
    return #"{"type": "object", "properties": {"$rules": {"const": [\#(listed)]}}}"#
}

/// A type that holds rules with chips, as `RuleBook.literal` writes them.
@MainActor func typeCard(_ title: String, chipped rules: [Rule], builds: [ShapeID] = [], id: ShapeID = ShapeID(),
                         at origin: CGPoint = CGPoint(x: 0, y: 0)) -> AnyShapeRecord {
    var record = typeCard(title, builds: builds, id: id, at: origin)
    record[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"$rules": {"const": \#(RuleBook.literal(rules))}}}"#)
    return record
}

/// A card of the types `of`, called `title`, saying `words`.
@MainActor func card(_ title: String, of types: [ShapeID], words: String = "", id: ShapeID = ShapeID(), at origin: CGPoint = CGPoint(x: 300, y: 0)) -> AnyShapeRecord {
    var record = ShapeRecord(id: id, Card(frame: CGRect(origin: origin, size: CGSize(width: 200, height: 60)), text: MentionText(plain: words)))
    record[TitleProperty.self] = title
    record[IsAProperty.self] = types.map(TypeLink.init)
    return AnyShapeRecord(record)
}
