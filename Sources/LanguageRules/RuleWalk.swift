import Canvas
import Titles
import Types
import Validation

// A rule's walk: Validation owns walking issues (`IssueWalk`), and a rule is one scope of it, given for the warnings that
// carry a rule's key (`RuleKey.source`). LanguageRules walks nothing itself: the scope says which shapes may have the
// rule's warning (the shapes it flags), which issues are its own, and what the band says of it.

/// Where a rule is as a walk follows it. A rule is named by its type and its sentence, and a sentence reworded is another
/// key (the warnings carry it), so the walk follows the rule: the sentence it has now, and its place among the type's own
/// rules as they were last seen.
@MainActor
final class RuleFollow {
    let type: ShapeID
    private(set) var says: String
    /// The type's own sentences as they were last seen, to tell a rule reworded from one taken away.
    private var seen: [String]

    init(type: ShapeID, says: String, seen: [String]) {
        self.type = type
        self.says = says
        self.seen = seen
    }

    /// The rule's key now.
    var key: RuleKey { RuleKey(type: type, says: says) }

    private func sentences(in editor: CanvasEditor) -> [String] { editor.ruleChecks?.rules(ofType: type).map(\.says) ?? [] }

    /// Where the rule is now, nil once it is gone. The rule is the one with its sentence, wherever the type has moved it;
    /// failing that, a rule reworded in place: the type has as many rules as it had, and the one at its old place is new.
    /// Reads only: `follow` is what moves the walk on.
    func now(in editor: CanvasEditor) -> (says: String, number: Int)? {
        let now = sentences(in: editor)
        if let index = now.firstIndex(of: says) { return (says, index + 1) }
        guard now.count == seen.count, let old = seen.firstIndex(of: says), !seen.contains(now[old]) else { return nil }
        return (now[old], old + 1)
    }

    /// Takes the type's rules as they are now. Whether the rule's sentence or its number changed.
    func follow(in editor: CanvasEditor) -> Bool {
        let place = now(in: editor)
        let before = seen.firstIndex(of: says).map { $0 + 1 }
        seen = sentences(in: editor)
        guard let place else { return false }
        let changed = place.says != says || place.number != before
        says = place.says
        return changed
    }
}

extension RuleValidationPlugin {
    /// The scope of a rule's warnings, nil if the rule is not among its type's own. Its stops are the warnings of its key, on
    /// the shapes it flags; its label is "Rule n" (n its place among the type's own rules) beside the type's chip, in the
    /// color Types gives the type.
    @MainActor
    static func walkScope(of key: RuleKey, in editor: CanvasEditor) -> IssueScope? {
        guard let checks = editor.ruleChecks else { return nil }
        let rules = checks.rules(ofType: key.type).map(\.says)
        guard rules.contains(key.says) else { return nil }
        let follow = RuleFollow(type: key.type, says: key.says, seen: rules)
        return IssueScope(
            id: RuleScopeID(type: key.type, says: key.says),
            includes: { $0.source == follow.key.source },
            label: { editor in
                guard let place = follow.now(in: editor),
                      let type = editor.withoutObservingDocument({ editor.file.record(follow.type) }) else { return nil }
                let name = editor.registry.title(of: type) ?? editor.registry.label(of: type.kind).name
                // The type's chip as Types looks it (its color's swatch), for the band to draw beside "Rule n"; a list
                // without Types has none.
                let chip = editor.types.map { IssueScopeChip(name, swatch: $0.look(of: follow.type).swatch) }
                return IssueScopeLabel(RulesStyle.rule(place.number), owner: follow.type, spoken: RulesStyle.ruleOf(place.number, type: name), chip: chip)
            },
            candidates: { $0.ruleChecks?.flagged(by: follow.key) ?? [] },
            isChanged: { _, editor in follow.follow(in: editor) },
            // Ignored on the shape by the rule's sentence, whoever wrote it (the walk's Ignore, the line's, Ignore Rule ▸, a redo).
            isSetAside: { shape, editor in
                editor.shape(inFile: shape)?[IgnoredRulesProperty.self]?.contains(follow.says) ?? false
            })
    }
}

/// What names a rule's walk: its type and its sentence as it began, which a walk follows through the rule's rewording.
struct RuleScopeID: Hashable {
    let type: ShapeID
    let says: String
}
