import Canvas
import ContextMenus
import DecisionModels
import Selection
import Types
import Validation

extension CanvasCommand {
    /// Asks again what failed: the Rules tab's and the Issues tab's Retry, by keys.
    public static let retryRuleChecks: CanvasCommand = "retryRuleChecks"
}

/// What the panel's buttons do, in the menus too, so none of it waits on Keyboard navigation: Ignore Rule ▸ in a
/// checked shape's menu (each rule of its chain, a check by those it ignores: a pick ignores it or stops, one step),
/// Select Flagged ▸ in a type's (each of its rules that flags shapes, with the count: a pick selects them), and Retry
/// Rules while a check failed for a reason trying again may mend.
@MainActor
func registerRuleMenus(into registrar: inout PluginRegistrar) {
    registrar.command(.retryRuleChecks, title: RulesStyle.retryRules, runs: .betweenPresses,
                      isEnabled: { $0.editor.ruleChecks?.failure.map { !$0.needsKey } ?? false }) { subject in
        subject.editor.ruleChecks?.retry()
    }
    registrar.forShapes(holding: IgnoredRulesProperty.self) { checked in
        checked.contextMenuForCanvas {
            MenuItems(in: StateMenuGroup.self, id: "ignore-rule") { subject in
                if subject.shapes.count == 1, let id = subject.shapes.first, let record = subject.editor.document[id],
                   let rules = subject.editor.ruleChecks?.currentChain(for: id), !rules.isEmpty {
                    let ignored = Set(record[IgnoredRulesProperty.self] ?? [])
                    Submenu(RulesStyle.ignoreRuleMenu, in: StateMenuGroup.self, id: "ignore-rule") {
                        for (i, rule) in rules.enumerated() {
                            let says = rule.rule.says, has = ignored.contains(says)
                            MenuItem(RulesStyle.cut(says), in: StateMenuGroup.self, id: "ignore-rule-\(i)", isChecked: { _ in has },
                                     stepName: has ? RulesStyle.stopIgnoringRule : RulesStyle.ignoreRule) { _, editor in
                                if has { editor.ruleWriter?.stopIgnoring(says, on: id) } else { editor.ruleWriter?.ignore(says, on: id) }
                            }
                        }
                    }
                }
            }
            MenuItems(in: StateMenuGroup.self, id: "walk-flagged-here") { subject in
                if subject.shapes.count == 1, let id = subject.shapes.first, let checks = subject.editor.ruleChecks, subject.editor.issueWalk != nil {
                    let flagging = checks.currentChain(for: id).compactMap { rule -> (key: RuleKey, says: String, count: Int)? in
                        let key = RuleKey(type: rule.type, says: rule.rule.says), ids = checks.flagged(by: key)
                        return ids.contains(id) ? (key, rule.rule.says, ids.count) : nil
                    }
                    if !flagging.isEmpty {
                        Submenu(RulesStyle.walkFlagged, in: StateMenuGroup.self, id: "walk-flagged-here") {
                            for (i, entry) in flagging.enumerated() {
                                MenuItem(RulesStyle.flaggedItem(entry.says, count: entry.count), in: StateMenuGroup.self, id: "walk-flagged-here-\(i)") { _, editor in
                                    editor.ruleLights?.walk(entry.key, at: .shape(id))
                                }
                            }
                        }
                    }
                }
            }
            MenuItem(command: .retryRuleChecks)
        }
    }
    registrar.forShapes(holding: TypeSchemaProperty.self) { types in
        types.contextMenuForCanvas {
            MenuItems(in: StateMenuGroup.self, id: "select-flagged") { subject in
                if subject.shapes.count == 1, let id = subject.shapes.first, let checks = subject.editor.ruleChecks {
                    let flagging = checks.rules(ofType: id).compactMap { rule -> (says: String, ids: Set<ShapeID>)? in
                        let ids = checks.flagged(by: RuleKey(type: id, says: rule.says))
                        return ids.isEmpty ? nil : (rule.says, ids)
                    }
                    if !flagging.isEmpty {
                        Submenu(RulesStyle.selectFlagged, in: StateMenuGroup.self, id: "select-flagged") {
                            for (i, entry) in flagging.enumerated() {
                                let ids = Array(entry.ids)
                                MenuItem(RulesStyle.flaggedItem(entry.says, count: ids.count), in: StateMenuGroup.self, id: "select-flagged-\(i)") { _, editor in
                                    editor.goTo(ids)
                                }
                            }
                        }
                    }
                }
            }
            MenuItems(in: StateMenuGroup.self, id: "walk-flagged") { subject in
                if subject.shapes.count == 1, let id = subject.shapes.first, let checks = subject.editor.ruleChecks, subject.editor.issueWalk != nil {
                    let flagging = checks.rules(ofType: id).compactMap { rule -> (says: String, count: Int)? in
                        let ids = checks.flagged(by: RuleKey(type: id, says: rule.says))
                        return ids.isEmpty ? nil : (rule.says, ids.count)
                    }
                    if !flagging.isEmpty {
                        Submenu(RulesStyle.walkFlagged, in: StateMenuGroup.self, id: "walk-flagged") {
                            for (i, entry) in flagging.enumerated() {
                                let key = RuleKey(type: id, says: entry.says)
                                MenuItem(RulesStyle.flaggedItem(entry.says, count: entry.count), in: StateMenuGroup.self, id: "walk-flagged-\(i)") { _, editor in
                                    editor.ruleLights?.walk(key, at: .first)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
