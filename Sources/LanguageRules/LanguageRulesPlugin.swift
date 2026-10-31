import Canvas
import Queries
import QueryLanguage
import Types
import Validation

// Rules in English on types: a type's schema holds sentences that should be true of every shape of it, a shape is
// checked against every rule along its types' chain, most general first, by the decision model (DecisionModels), and a
// shape the rules read together flag is warned about, the warning quoting the rule answered highest. Nothing here
// knows a kind: a kind opts in with `checkedByRules()`.

extension PluginID {
    public static let languageRules: PluginID = "language-rules"
}

/// Language rules, as a plugin: `$rules`, held in a type's schema as Types holds `$color` (`registrar.typeDirective`);
/// `ignoredRules`, the property a checked kind opts into; and the checks (`RuleChecks`, `editor.ruleChecks`). Their
/// warnings are a plugin value of their own (`RuleValidationPlugin`), so a list without Validation leaves them out.
/// The questions' words are the product's
/// (`Shipped/rule-prompt.txt`, `RulePrompts`): `LanguageRulesPlugin()` reads them from the product's own files, which
/// only the product's executables have; in any other, it has none and asks nothing (a test of notes or arrows lists it
/// for the property they opt into), and a test that checks passes words of its own (`init(prompts:)`).
public struct LanguageRulesPlugin: ListedPlugin {
    let prompts: RulePrompts?

    public init() {
        prompts = ShippedText.named(RulePrompts.file).flatMap { try? RulePrompts(text: $0) }
    }

    public init(prompts: RulePrompts) { self.prompts = prompts }

    public var id: PluginID { .languageRules }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(IgnoredRulesProperty.self)
        registrar.typeDirective(RuleBook.directive)
        let prompts = prompts
        registrar.service { RuleChecks(editor: $0, prompts: prompts) }
        registrar.service { RuleWriter(editor: $0) }
        registrar.service { RuleChips(editor: $0) }
    }
}

/// Rules in the panel and the menus, a plugin value of its own after LanguageRules, the detail panel and the context
/// menus, so a list without them leaves it out: a type's Rules tab, a checked shape's Rules section in the Issues tab,
/// the light a highlighted count or line of Shown puts on the canvas (`RuleLights`), and the menu items that do what the
/// panel's buttons do (Ignore Rule ▸, Select Flagged ▸, Retry Rules).
public struct RuleDetailsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "rule-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { RuleLights(editor: $0) }
        // One light for the rules and the issue walk (`IssueWalkStyle.light`), never both: the walk's yields to nothing, since it
        // is lit by the keyboard being in the walk's band, and the rules' by a pointer passing over a count or a line.
        registrar.outlines { $0.issueLights?.isLit == true ? Outlines() : ($0.ruleLights?.outlines ?? Outlines()) }
        registerRulePanels(into: &registrar)
        registerRuleMenus(into: &registrar)
        registerRulesChip(into: &registrar)
    }
}

/// The warnings rules give, a Validation rule on the shapes that hold `ignoredRules`: one for each rule that flags the
/// shape, from what the decision model last answered (`RuleChecks.issues(of:)`). The answer lands later than the
/// commit, so `RuleChecks` asks Validation to check the shape again as it does.
public struct RuleValidationPlugin: ListedPlugin {
    public init() {}
    public nonisolated static let id: PluginID = "rule-validation"
    public var id: PluginID { Self.id }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(holding: IgnoredRulesProperty.self) { checked in
            checked.validate(ignoringMoves: true) { shape, context in
                context.service(RuleChecks.self)?.issues(of: shape) ?? []
            }
        }
        // A rule's warnings are a scope of the issue walk: Validation walks them, knowing no rule (`RuleWalk.swift`).
        registrar.issueScopes { source, editor in
            RuleKey(source: source).flatMap { RuleValidationPlugin.walkScope(of: $0, in: editor) }
        }
        // A chip whose query the engine can't read, bound to the shape checked, warns on its type, in the engine's words:
        // on the board, and in what `canvas draw` reports of a schema it writes (the committed engine reads it there).
        registrar.forShapes(holding: TypeSchemaProperty.self) { types in
            // What the engine reads a query by changes with the file's types (a relationship type is an edge type): a
            // commit that writes one, or deletes anything, checks every type with a chip again.
            types.validate(ignoringMoves: true, affected: { changes, editor in
                guard let checks = editor.ruleChecks, !checks.chipTypes.isEmpty else { return [] }
                let written = changes.added.union(changes.changed.subtracting(changes.moved)).union(changes.elsewhere)
                let typeChanged = !changes.removed.isEmpty || written.contains { editor.shape(inFile: $0)?[TypeSchemaProperty.self] != nil }
                return typeChanged ? checks.chipTypes : []
            }) { shape, context in
                guard let text = shape[TypeSchemaProperty.self]?.text, text.contains("$" + RuleBook.directive),
                      let queries = context.committedService(QueryState.self) else { return [] }
                return RuleValidationPlugin.unreadableChips(in: text, queries: queries)
            }
        }
    }

    /// A warning for each chip of a schema's rules whose query the engine refuses, bound to the shape checked: where in
    /// the schema it is, and why, in the engine's words.
    @MainActor
    static func unreadableChips(in schema: String, queries: QueryState) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (r, rule) in RuleBook.rules(inSchema: schema).enumerated() {
            for (c, chip) in rule.find.enumerated() {
                guard let query = chip.query else { continue }
                do throws(QueryError) {
                    _ = try queries.checkStored(query, binding: .scope)
                } catch {
                    issues.append(.warning(RulesStyle.unreadableChip(chip.phrase, error.message), field: TypeSchemaProperty.key.rawValue,
                                           path: "/properties/$\(RuleBook.directive)/const/\(r)/find/\(c)/query"))
                }
            }
        }
        return issues
    }
}
