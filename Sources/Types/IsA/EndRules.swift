import Canvas
import ContextMenus
import DetailPanel
import Foundation
import SwiftUI

// Needed and Only one are set on an end's arrow: in its context menu, in its panel, and by `canvas draw` (`endRule:`), all through
// one writer. They are shown only while the arrow is an end of a relationship type (`relationships.end(arrow)`): on any other arrow
// `endRule` is inert, and nothing offers it.

extension TypesStyle {
    /// The steps: what a person did to the rule of an end, named by the item they chose (unchecking Needed makes it optional,
    /// unchecking Only one allows several).
    public static let makeNeeded = "Make Needed"
    public static let makeOptional = "Make Optional"
    public static let allowOnlyOne = "Allow Only One"
    public static let allowSeveral = "Allow Several"
    /// The two items, in the arrow's menu and its panel.
    static let neededChoice = "Needed"
    static let onlyOneChoice = "Only one"
    /// The panel's section.
    static let endTitle = "End"
}

extension CanvasEditor {
    /// What the rule of each of these arrows is, less the ones that are not ends: set the members named (nil leaves a member
    /// be), in one step named for the first change, `Make Needed`, `Make Optional`, `Allow Only One` or `Allow Several`. Both
    /// members false take the property off. An arrow that is no end of a relationship type is passed by; a read-only arrow is
    /// refused by the core, and shakes, while the rest changes. True once something was written.
    @discardableResult
    public func setEndRule(_ arrows: [ShapeID], needed: Bool? = nil, onlyOne: Bool? = nil) -> Bool {
        guard let relationships else { return false }
        var changes: [(id: ShapeID, rule: EndRule)] = []
        var first: String?
        for id in arrows {
            guard relationships.end(id) != nil, let record = shape(inFile: id) else { continue }
            let held = record[RelationshipEndProperty.self] ?? EndRule()
            let rule = EndRule(needed: needed ?? held.needed, onlyOne: onlyOne ?? held.onlyOne)
            guard rule != held else { continue }
            changes.append((id, rule))
            if first == nil {
                if rule.needed != held.needed {
                    first = rule.needed ? TypesStyle.makeNeeded : TypesStyle.makeOptional
                } else {
                    first = rule.onlyOne ? TypesStyle.allowOnlyOne : TypesStyle.allowSeveral
                }
            }
        }
        guard let name = first else { return false }
        let before = revision
        transact(name) { transaction in
            for change in changes {
                transaction.update(inFile: change.id) { $0[RelationshipEndProperty.self] = change.rule.isNone ? nil : change.rule }
            }
        }
        return revision != before
    }
}

/// What the selection's ends have, for the menu's checks: every one of them.
@MainActor
private struct EndRuleMenu {
    let needed: Bool
    let onlyOne: Bool

    /// Nil unless every shape is an end, and there is one.
    init?(_ shapes: [ShapeID], in editor: CanvasEditor) {
        guard !shapes.isEmpty, let relationships = editor.relationships,
              shapes.allSatisfy({ relationships.end($0) != nil && editor.shape(inFile: $0) != nil }) else { return nil }
        let rules = shapes.map { editor.shape(inFile: $0)?[RelationshipEndProperty.self] ?? EndRule() }
        needed = rules.allSatisfy(\.needed)
        onlyOne = rules.allSatisfy(\.onlyOne)
    }
}

/// Needed and Only one, checked, in the menu of an arrow that is an end (every arrow selected is one), beside Lock and Is a ▸. An
/// unchecked item gives the rule to the ends among them that don't have it; a checked one takes it from all. Never dimmed: a locked
/// arrow is refused by the core and shakes, while the rest of the selection changes in the one step.
@MainActor
func registerEndRuleMenu(into registrar: inout PluginRegistrar) {
    registrar.contextMenuForCanvas {
        MenuItems(in: StateMenuGroup.self, id: "end-rule") { subject in
            if let menu = EndRuleMenu(subject.shapes, in: subject.editor) {
                MenuItem(TypesStyle.neededChoice, in: StateMenuGroup.self, id: "end-needed", isChecked: { _ in menu.needed },
                         stepName: menu.needed ? TypesStyle.makeOptional : TypesStyle.makeNeeded) { ids, editor in
                    editor.setEndRule(ids, needed: !menu.needed)
                }
                MenuItem(TypesStyle.onlyOneChoice, in: StateMenuGroup.self, id: "end-only-one", isChecked: { _ in menu.onlyOne },
                         stepName: menu.onlyOne ? TypesStyle.allowSeveral : TypesStyle.allowOnlyOne) { ids, editor in
                    editor.setEndRule(ids, onlyOne: !menu.onlyOne)
                }
            }
        }
    }
}

/// The arrow's panel, in the Types tab while it is an end: Needed and Only one, two checkboxes.
@MainActor
func registerEndRulePanel(into registrar: inout PluginRegistrar) {
    // On the kinds that relate, while the arrow is an end.
    registrar.forShapes(holding: RelationshipEndProperty.self) { relating in
        relating.details {
            DetailSection<AnyShapeRecord>(TypesStyle.endTitle, in: TypesTab.self, id: "end-rule") { shape in
                EndRuleControls(id: shape.shapeID, rule: shape.wrappedValue[RelationshipEndProperty.self] ?? EndRule(), index: shape.service(RelationshipIndex.self))
            }
            .shownWhile { shape, context in context.service(RelationshipIndex.self)?.end(shape.id) != nil }
        }
    }
}

struct EndRuleControls: View {
    let id: ShapeID
    let rule: EndRule
    let index: RelationshipIndex?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DetailCheckbox(TypesStyle.neededChoice, isOn: Binding(get: { rule.needed }, set: { [index, id] in index?.editor?.setEndRule([id], needed: $0) }))
            DetailCheckbox(TypesStyle.onlyOneChoice, isOn: Binding(get: { rule.onlyOne }, set: { [index, id] in index?.editor?.setEndRule([id], onlyOne: $0) }))
        }
    }
}
