import Canvas
import ContextMenus
import Foundation
import Keyboard
import Selection

/// Grouping, as a plugin: shapes grouped together are selected as one from then on (tldraw's, and
/// Keynote's), until they're ungrouped. A group is something its shapes have, as a lock is, not a
/// shape: each shape in one holds the groups it's in, outermost first (`groups`, an added property
/// every kind opts into), so nothing new is on the board or in the table of contents, and whatever
/// acts on the selection (a drag, Delete, Copy, Lock, a color) acts on the whole group. What a click,
/// the marquee, the hover and Escape do with groups is Selection's (`SelectionGroups`), which this
/// plugin tells what the groups are. Group (⌥⌘G) puts the selection in a new group, inside the
/// groups it is in, a group it holds whole staying a group in the new one; Ungroup (⇧⌥⌘G) takes
/// apart the groups it holds whole, a level; both from the context menu too, and the Arrange menu.
/// A group is its shapes on one board, and counts while it holds two parts or more there
/// (`BoardGroups`). Agents group shapes with `canvas draw`'s `group` and `ungroup`
/// (`GroupDrawPlugin`), and read them with `canvas query`'s `:grouped-with` (`GroupQueriesPlugin`).
extension PluginID {
    public static let grouping: PluginID = "grouping"
}

extension CanvasCommand {
    /// Arrange › Group (⌥⌘G): the shapes put in a new group.
    public static let group: CanvasCommand = "group"
    /// Arrange › Ungroup (⌥⇧⌘G): the groups the shapes hold whole taken apart, a level.
    public static let ungroup: CanvasCommand = "ungroup"
}

/// The groups a shape is in, outermost first, each by an id no other group has (a UUID's string):
/// nothing on a shape in none. The plugin's own: no language lists or writes it (`unlisted()`),
/// since a group has no name an agent could know it by; draw writes it with `group`.
public enum GroupsProperty {}

extension GroupsProperty: ShapeProperty {
    public static let key: PropertyKey = "groups"
    public static var defaultValue: [String]? { nil }
    public static var keywords: PropertyKeywords<[String]> {
        PropertyKeywords().description("The groups the shape is in, outermost first, by id.").unlisted()
    }
    public static func isNone(_ value: [String]) -> Bool { value.isEmpty }
}

extension CanvasEditor {
    /// The groups on the board shown. Without the Grouping plugin, none.
    public var boardGroups: BoardGroups { service(GroupIndex.self)?.groups ?? BoardGroups([]) }

    /// Whether `ids` can be grouped: two parts or more, a part being a shape or a group they hold
    /// whole (tldraw's: a group of one is no group).
    public func canGroup(_ ids: [ShapeID]) -> Bool { boardGroups.canGroup(ids) }

    /// Whether `ids` hold a group whole, which Ungroup takes apart.
    public func canUngroup(_ ids: [ShapeID]) -> Bool { boardGroups.canUngroup(ids) }

    /// Puts `ids` in a new group (`BoardGroups.grouping`), in one step, "Group". All or nothing: a
    /// read-only one among them (a locked shape) leaves them as they were, and shakes. They stay
    /// selected, as the group they now are. False when nothing was grouped.
    @discardableResult
    public func group(_ ids: [ShapeID]) -> Bool {
        guard let paths = boardGroups.grouping(ids, as: UUID().uuidString) else { return false }
        return write(paths, named: "Group")
    }

    /// Takes apart the groups `ids` hold whole (`BoardGroups.ungrouping`), a level, in one step,
    /// "Ungroup". All or nothing, as `group` is. False when nothing was ungrouped.
    @discardableResult
    public func ungroup(_ ids: [ShapeID]) -> Bool {
        guard let paths = boardGroups.ungrouping(ids) else { return false }
        return write(paths, named: "Ungroup")
    }

    /// Writes each shape's path, all or nothing: a read-only shape refuses, nothing commits and no
    /// step opens, and the shapes refused shake.
    private func write(_ paths: [ShapeID: [String]], named name: String) -> Bool {
        var refused: Set<ShapeID> = []
        do {
            try transact(name) { transaction in
                for (id, path) in paths.sorted(by: { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }) {
                    transaction.update(id) { $0[GroupsProperty.self] = path }
                }
                refused = transaction.refusedShapes
                if !refused.isEmpty { throw GroupingRefused() }
            }
        } catch {
            if !refused.isEmpty { refuseChanges(to: refused) }
            return false
        }
        return true
    }
}

/// What leaves a group or ungroup a read-only shape would refuse: nothing is written.
private struct GroupingRefused: Error {}

public struct GroupingPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .grouping }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(GroupsProperty.self)
        registrar.optInEveryShape(to: GroupsProperty.self)
        registrar.service { GroupIndex(editor: $0) }
        registrar.selectionGroups { $0.service(GroupIndex.self) }
        // ⌥⌘G and ⇧⌥⌘G, Keynote's and Freeform's (⌘G is Find Next), Arrange › Group and Ungroup and the
        // context menu's items, beside Lock (Keynote's Arrange menu has them together): Group for two
        // or more shapes or groups, Ungroup for a group held whole (every kind can be grouped), while
        // nothing is under way or being edited.
        registrar.command(.group, title: "Group", menu: "Arrange", order: 0, shortcut: KeyChord("g", [.command, .option]), runs: .whenIdle,
                          isEnabled: { $0.editor.canGroup($0.shapes) }) { $0.editor.group($0.shapes) }
        registrar.command(.ungroup, title: "Ungroup", menu: "Arrange", order: 10, shortcut: KeyChord("g", [.command, .option, .shift]),
                          runs: .whenIdle, isEnabled: { $0.editor.canUngroup($0.shapes) }) { $0.editor.ungroup($0.shapes) }
        registrar.contextMenuForCanvas {
            MenuItem(command: .group, in: StateMenuGroup.self)
            MenuItem(command: .ungroup, in: StateMenuGroup.self)
        }
    }
}
