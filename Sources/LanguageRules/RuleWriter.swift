import Canvas
import CanvasRPC
import DetailPanel
import Foundation
import Selection
import Types

/// The one writer of rules and of what a shape ignores: a type's `$rules`, written into its schema with the rest of
/// its JSON as typed (`HeldDirective`), and a shape's `ignoredRules`. Each write is one step; a shape that can't change
/// is refused (the core shakes it) before any transaction, and a write that changes nothing makes no step.
@MainActor
public final class RuleWriter {
    private weak var editor: CanvasEditor?
    private let directive = HeldDirective(name: RuleBook.directive)

    init(editor: CanvasEditor) { self.editor = editor }

    /// Writes `rules` as `type`'s, in order (none takes the member away): one step, "Change Rules" unless `step` says
    /// otherwise. False when nothing was written: a shape that holds no schema, a schema that isn't a JSON object, the
    /// rules as they are, or a type that can't change (refused).
    @discardableResult
    public func setRules(_ rules: [Rule], of type: ShapeID, step: String = RulesStyle.changeRules) -> Bool {
        guard let editor, let text = editor.shape(inFile: type)?[TypeSchemaProperty.self]?.text else { return false }
        let kept = rules.filter { !$0.says.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard kept != RuleBook.rules(inSchema: text) else { return false }
        guard let written = directive.text(text, setting: kept.isEmpty ? nil : RuleBook.literal(kept)), written != text else { return false }
        guard !editor.isReadOnly(inFile: type) else {
            editor.refuseChanges(to: [type])
            return false
        }
        editor.transact(step) { transaction in
            transaction.update(inFile: type) { $0[TypeSchemaProperty.self] = SchemaText(written) }
        }
        return true
    }

    /// Gives the chip `phrase` of the rule that says `says` on `type` its query (nil lets it go: words again), one step
    /// (`step`): what a chip's words became, or a query edited by hand. False when the type has no such rule or chip, the
    /// chip has that query already, or the type can't change.
    @discardableResult
    public func setQuery(_ query: String?, ofChip phrase: String, in says: String, of type: ShapeID, step: String = RulesStyle.changeRules) -> Bool {
        guard let editor else { return false }
        var rules = RuleBook.rules(of: type, in: editor)
        guard let r = rules.firstIndex(where: { $0.says == says }), let c = rules[r].find.firstIndex(where: { $0.phrase == phrase }),
              rules[r].find[c].query != query else { return false }
        rules[r].find[c].query = query
        return setRules(rules, of: type, step: step)
    }

    /// Ignores the rule that says `says` for `shape`: its warning goes while the rule says the same thing. One step,
    /// "Ignore Rule"; false when it was ignored already or the shape can't change.
    @discardableResult
    public func ignore(_ says: String, on shape: ShapeID) -> Bool {
        write(on: shape, step: RulesStyle.ignoreRule) { ignored in
            guard !ignored.contains(says) else { return false }
            ignored.append(says)
            return true
        }
    }

    /// Stops ignoring it: one step, "Stop Ignoring Rule"; false when it wasn't ignored or the shape can't change.
    @discardableResult
    public func stopIgnoring(_ says: String, on shape: ShapeID) -> Bool {
        write(on: shape, step: RulesStyle.stopIgnoringRule) { ignored in
            guard ignored.contains(says) else { return false }
            ignored.removeAll { $0 == says }
            return true
        }
    }

    private func write(on shape: ShapeID, step: String, _ change: (inout [String]) -> Bool) -> Bool {
        // A type is checked by no rule, so it ignores none.
        guard let editor, let record = editor.shape(inFile: shape), editor.registry.properties(for: record.kind).contains(IgnoredRulesProperty.key),
              record[TypeSchemaProperty.self] == nil else { return false }
        var ignored = record[IgnoredRulesProperty.self] ?? []
        guard change(&ignored) else { return false }
        guard !editor.isReadOnly(inFile: shape) else {
            editor.refuseChanges(to: [shape])
            return false
        }
        editor.transact(step) { transaction in
            transaction.update(inFile: shape) { $0[IgnoredRulesProperty.self] = ignored.isEmpty ? nil : ignored }
        }
        return true
    }
}

extension RuleWriter: EditorService {}

extension CanvasEditor {
    /// The one writer of rules and ignores: nil without LanguageRulesPlugin.
    public var ruleWriter: RuleWriter? { service(RuleWriter.self) }

    /// Shows a rule where it's written: its type selected (on its board, one step back) and the type's Rules tab.
    public func showRule(_ rule: ChainedRule) {
        guard let record = shape(inFile: rule.type) else { return }
        detailPanel?.choose(.of(RulesTab.self), for: record.kind)
        let type = rule.type
        // On the next turn: the line's button goes with the panel it's in.
        _ = scheduler.schedule(after: .zero) { [weak self] in self?.goTo([type]) }
    }
}

extension RuleBook {
    /// `rules` as the member's `const` is written: a list of objects, a rule a line's worth of JSON, spaced as a person
    /// types it.
    public static func literal(_ rules: [Rule]) -> String {
        func quoted(_ text: String) -> String { JSONValue.string(text).compactText }
        let items = rules.map { rule -> String in
            var members = ["\"says\": \(quoted(rule.says))"]
            if !rule.find.isEmpty {
                let chips = rule.find.map { chip in
                    chip.query.map { "{\"phrase\": \(quoted(chip.phrase)), \"query\": \(quoted($0))}" } ?? "{\"phrase\": \(quoted(chip.phrase))}"
                }
                members.append("\"find\": [\(chips.joined(separator: ", "))]")
            }
            return "{\(members.joined(separator: ", "))}"
        }
        return "[\(items.joined(separator: ", "))]"
    }
}
