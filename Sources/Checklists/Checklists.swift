import Canvas
import DetailPanel
import Foundation
import SwiftUI

extension PluginID {
    public static let checklists: PluginID = "checklists"
}

public struct ChecklistItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var isDone: Bool

    public init(id: UUID = UUID(), text: String = "", isDone: Bool = false) {
        self.id = id
        self.text = text
        self.isDone = isDone
    }
}

extension Array where Element == ChecklistItem {
    public var doneCount: Int { lazy.filter(\.isDone).count }
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

/// What `ShapeChecklists` stores for a kind: how to read its items, and whether the canvas shows
/// the chip. Only the sugar below makes one.
@MainActor
public struct ChecklistContribution {
    let items: @MainActor (AnyShapeRecord) -> [ChecklistItem]?
    let showsBadge: Bool
}

/// The extension point: which kinds have a checklist. At most one per kind.
public enum ShapeChecklists: KeyedExtensionPoint {
    public typealias Contribution = ChecklistContribution
    public static var owner: PluginID { .checklists }
    public static func uniqueKeys(of _: ChecklistContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

extension ShapeRegistrar {
    /// Gives this kind a checklist, stored at `items` in its props: a Checklist tab in the detail
    /// panel, and (unless `badge` is false, for kinds that draw their own) a small done/total chip
    /// on the canvas. `note.checklist(\.checklist)`.
    public mutating func checklist(_ items: WritableKeyPath<Definition.Props, [ChecklistItem]>, badge: Bool = true) {
        contribute(ChecklistContribution(items: { $0.typed(as: Definition.Props.self)?.props[keyPath: items] }, showsBadge: badge),
                   to: ShapeChecklists.self)
        details {
            DetailSection("Items", in: ChecklistTab.self) { $shape in
                ChecklistRows(items: $shape[dynamicMember: items])
            } accessory: { $shape in
                ChecklistMenu(shape: $shape, items: items)
            }
            DetailSection("Progress", in: ChecklistTab.self, when: { !$0[keyPath: items].isEmpty }) { shape in
                ChecklistProgress(items: shape.wrappedValue[keyPath: items])
            }
        }
    }
}

extension Registry {
    /// A shape's checklist; nil if its kind has none.
    public func checklist(of shape: AnyShapeRecord) -> [ChecklistItem]? {
        contributions(to: ShapeChecklists.self, for: shape.kind).first.flatMap { $0.items(shape) }
    }
}

/// A horizontal any kind can opt into: a checklist stored in the kind's own props. Opting in is one
/// line, and brings a Checklist tab in the detail panel and a done/total chip on the canvas. The
/// kind stores the items; this plugin owns their type and everything done with them.
public struct ChecklistsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .checklists }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.overlay(ChecklistOverlay())
    }
}
