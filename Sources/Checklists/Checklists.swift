import Adornments
import Canvas
import ContextMenus
import DetailPanel
import Foundation
import SwiftUI

extension PluginID {
    public static let checklists: PluginID = "checklists"
}

/// One item: what it says, whether it's done, and an id of its own from the moment it's made. An
/// item read without an id (one an agent writes, `[{"text": "Eggs"}]`) gets a new one, so the id
/// isn't required, and its schema states no default: each item's is its own.
public struct ChecklistItem: SchemaDefined, Equatable, Hashable, Identifiable {
    public static let properties = Properties<ChecklistItem>(title: "Checklist item", definition: "item") {
        Property("id", \.id)
        Property("text", \.text)
        Property("isDone", \.isDone)
    }
    public var id: UUID
    public var text: String
    public var isDone: Bool

    public init(id: UUID = UUID(), text: String = "", isDone: Bool = false) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
    public init() { self.init(id: UUID()) }
}

/// A shape's checklist: the property Checklists adds to every kind that opts in (`note.checklist()`),
/// which every shape of that kind has, empty until someone adds an item.
public enum ChecklistProperty {}
extension ChecklistProperty: ShapeProperty {
    public static let key: PropertyKey = "checklist"
    public static var defaultValue: [ChecklistItem]? { [] }
}

extension Array where Element == ChecklistItem {
    public var doneCount: Int { lazy.filter(\.isDone).count }
    /// "2/5": done over total, as the chip shows it; nil when empty.
    public var tally: String? { isEmpty ? nil : "\(doneCount)/\(count)" }
    /// Done over total; 0 when empty.
    public var progress: Double { isEmpty ? 0 : Double(doneCount) / Double(count) }

    public mutating func setAllDone(_ done: Bool) {
        for i in indices { self[i].isDone = done }
    }

    public mutating func removeDone() { removeAll(where: \.isDone) }
}

/// The Items header's menu, in order: what each action is called, when there's anything for it to
/// do, and what it does to the list.
public enum ChecklistBulkAction: CaseIterable, Sendable {
    case checkAll, uncheckAll, removeChecked

    public var title: String {
        switch self {
        case .checkAll: "Check All"
        case .uncheckAll: "Uncheck All"
        case .removeChecked: "Remove Checked"
        }
    }

    public func isEnabled(for items: [ChecklistItem]) -> Bool {
        switch self {
        case .checkAll: items.doneCount < items.count
        case .uncheckAll, .removeChecked: items.doneCount > 0
        }
    }

    public func apply(to items: inout [ChecklistItem]) {
        switch self {
        case .checkAll: items.setAllDone(true)
        case .uncheckAll: items.setAllDone(false)
        case .removeChecked: items.removeDone()
        }
    }
}

/// What `ShapeChecklists` stores for a kind: whether its shapes show `ChecklistChip`. Only the sugar
/// below makes one.
@MainActor
public struct ChecklistContribution {
    let showsBadge: Bool
}

/// The extension point: which kinds have a checklist, and how they show it. At most one per kind.
public enum ShapeChecklists: KeyedExtensionPoint {
    public typealias Contribution = ChecklistContribution
    public static var owner: PluginID { .checklists }
    public static func uniqueKeys(of _: ChecklistContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// The bulk actions in a shape's context menu: after the kind's own items.
public enum ChecklistMenuGroup {}
extension ChecklistMenuGroup: MenuGroup {
    public static var order: Int { 50 }
}

extension ShapeRegistrar {
    /// Gives this kind's shapes a checklist (`ChecklistProperty`, in the kind's schema as
    /// `checklist`): a Checklist tab in the detail panel, the bulk actions that apply in its context
    /// menu, and (unless `badge` is false, for kinds that draw their own) a small done/total chip on
    /// the canvas (`ChecklistChip`). `note.checklist()`.
    public mutating func checklist(badge: Bool = true) {
        optIn(to: ChecklistProperty.self)
        contribute(ChecklistContribution(showsBadge: badge), to: ShapeChecklists.self)
        details(of: ChecklistProperty.self) {
            DetailSection("Items", in: ChecklistTab.self) { $items in
                ChecklistRows(items: $items[dynamicMember: \.self])
            } accessory: { $items in
                ChecklistMenu(items: $items)
            }
            DetailSection("Progress", in: ChecklistTab.self, when: { !$0.isEmpty }) { items in
                ChecklistProgress(items: items.wrappedValue)
            }
        }
        // The Items menu's actions, each only where it has something to do.
        contextMenu(of: ChecklistProperty.self) {
            for action in ChecklistBulkAction.allCases {
                MenuItem(action.title, in: ChecklistMenuGroup.self, when: { action.isEnabled(for: $0) }) { action.apply(to: &$0) }
            }
        }
    }
}

extension Registry {
    /// A shape's checklist; nil if its kind has none.
    public func checklist(of shape: AnyShapeRecord) -> [ChecklistItem]? { shape[ChecklistProperty.self] }
}

/// A checklist's tally, "☑ 2/5", on the top-right corner of every shape with items whose kind shows
/// it (`badge: true`, the default); green once every item is done. Checklists places it, though it
/// defines no shape; Adornments lays it out and draws it, where the shape is drawn.
public enum ChecklistChip {}

extension ChecklistChip: Adornment {
    public static var placement: AdornmentPlacement { .onTopRightCorner }
    public static var order: Int { 50 }
}

extension Registry {
    /// Whether a kind's shapes show their checklist's chip: it opted in without `badge: false`.
    func showsChecklistChip(_ kind: ShapeKind) -> Bool {
        contributions(to: ShapeChecklists.self, for: kind).first?.showsBadge == true
    }
}

/// A horizontal any kind can opt into: a checklist on each of its shapes, as a property this plugin
/// adds (`ChecklistProperty`), so the kind declares nothing. Opting in is one line, and brings a
/// Checklist tab in the detail panel, its bulk actions in the context menu, and a done/total chip
/// on the canvas (`ChecklistChip`, an adornment). This plugin owns the items, their type and
/// everything done with them.
public struct ChecklistsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .checklists }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(ChecklistProperty.self)
        // The tally, on every shape with items whose kind shows it: Checklists places it, and defines no kind.
        registrar.adornmentForEveryShape(ChecklistChip.self, where: { $0.registry.showsChecklistChip($0.kind) }) { shape, _ in
            guard let items = shape[ChecklistProperty.self], let tally = items.tally else { return nil }
            return AdornmentLabel("☑ \(tally)", tone: items.doneCount == items.count ? .success : .neutral)
        }
    }
}
