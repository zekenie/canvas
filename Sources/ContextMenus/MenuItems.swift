import Canvas

// MARK: Groups

/// A group of items in a context menu, with a separator between groups. The type is the group, as
/// a tab is the detail panel's: every item that names it lands in it, sharing one means importing
/// the module that declares it, and a typo doesn't compile.
///
///     public enum ChecklistMenuGroup {}
///     extension ChecklistMenuGroup: MenuGroup {
///         public static var order: Int { 50 }
///     }
public protocol MenuGroup {
    /// Groups sort by this, then by first appearance. The bands, as the detail panel's tabs: 0 for
    /// a kind's own items (the default), 50 for the items a horizontal's feature brings to the
    /// kinds that opt into it, 100 and up for groups every kind shares.
    static var order: Int { get }
}

extension MenuGroup {
    public static var order: Int { 0 }
}

/// A kind's own items: the group of an item that names none.
public enum ShapeMenuGroup {}
extension ShapeMenuGroup: MenuGroup {}

struct MenuGroupID: Hashable {
    let type: ObjectIdentifier
    let order: Int

    init(_ group: any MenuGroup.Type) {
        type = ObjectIdentifier(group)
        order = group.order
    }
}

// MARK: Items

/// One command in a context menu, over `Value`: the kind's props for a kind's own items
/// (`x.contextMenu { }`), or `AnyShapeRecord` for every shape's (`contextMenuForEveryShape { }`).
///
///     MenuItem("Mark Done", when: { $0.status != .done }) { $0.status = .done }
///
/// It shows for a shape when `when` says so (always, by default), and is dimmed where `isEnabled`
/// says not. A context menu leaves out what doesn't apply, so prefer `when`. `isChecked` puts a
/// checkmark by it. `id` (the title, by default) is what makes it the same item on two kinds and
/// what two plugins can't both claim, within its group.
public struct MenuItem<Value> {
    let entry: MenuEntry<Value>

    /// Edits the shapes it's for: `edit` runs on each one's live value, all of them in one
    /// transaction. Setting what a shape already has commits nothing.
    public init(_ title: String, in group: any MenuGroup.Type = ShapeMenuGroup.self, id: String? = nil,
                when isShown: @escaping @MainActor (Value) -> Bool = { _ in true },
                isEnabled: @escaping @MainActor (Value) -> Bool = { _ in true },
                isChecked: (@MainActor (Value) -> Bool)? = nil,
                edit: @escaping @MainActor (inout Value) -> Void) {
        entry = MenuEntry(title: title, group: MenuGroupID(group), id: id ?? title, isShown: isShown,
                          content: .item(isEnabled: isEnabled, isChecked: isChecked, action: .edit(edit)))
    }

    /// For what editing each shape can't do (reordering, deleting, selecting): `perform` gets the
    /// shapes it's for, in selection order, and the editor. It changes the document only through
    /// `editor.transact`.
    public init(_ title: String, in group: any MenuGroup.Type = ShapeMenuGroup.self, id: String? = nil,
                when isShown: @escaping @MainActor (Value) -> Bool = { _ in true },
                isEnabled: @escaping @MainActor (Value) -> Bool = { _ in true },
                isChecked: (@MainActor (Value) -> Bool)? = nil,
                perform: @escaping @MainActor ([ShapeID], CanvasEditor) -> Void) {
        entry = MenuEntry(title: title, group: MenuGroupID(group), id: id ?? title, isShown: isShown,
                          content: .item(isEnabled: isEnabled, isChecked: isChecked, action: .perform(perform)))
    }
}

/// A titled submenu. Its items group, and show, as the menu's own do; a submenu none of whose items
/// shows is left out.
public struct Submenu<Value> {
    let entry: MenuEntry<Value>

    public init(_ title: String, in group: any MenuGroup.Type = ShapeMenuGroup.self, id: String? = nil,
                when isShown: @escaping @MainActor (Value) -> Bool = { _ in true },
                @MenuBuilder<Value> items: () -> [MenuEntry<Value>]) {
        entry = MenuEntry(title: title, group: MenuGroupID(group), id: id ?? title, isShown: isShown, content: .submenu(items()))
    }
}

/// An item or a submenu, as `MenuBuilder` collects them.
public struct MenuEntry<Value> {
    let title: String
    let group: MenuGroupID
    let id: String
    let isShown: @MainActor (Value) -> Bool
    let content: Content

    enum Content {
        case item(isEnabled: @MainActor (Value) -> Bool, isChecked: (@MainActor (Value) -> Bool)?, action: Action)
        case submenu([MenuEntry<Value>])
    }

    enum Action {
        case edit(@MainActor (inout Value) -> Void)
        case perform(@MainActor ([ShapeID], CanvasEditor) -> Void)
    }

    /// Its key, and its items' under it, each as the path from the top.
    func paths(under parent: [EntryKey]) -> [[EntryKey]] {
        let path = parent + [EntryKey(group: group, id: id)]
        guard case .submenu(let entries) = content else { return [path] }
        return [path] + entries.flatMap { $0.paths(under: path) }
    }
}

@resultBuilder
public enum MenuBuilder<Value> {
    public static func buildExpression(_ item: MenuItem<Value>) -> [MenuEntry<Value>] { [item.entry] }
    public static func buildExpression(_ submenu: Submenu<Value>) -> [MenuEntry<Value>] { [submenu.entry] }
    public static func buildBlock(_ parts: [MenuEntry<Value>]...) -> [MenuEntry<Value>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [MenuEntry<Value>]?) -> [MenuEntry<Value>] { part ?? [] }
    public static func buildEither(first part: [MenuEntry<Value>]) -> [MenuEntry<Value>] { part }
    public static func buildEither(second part: [MenuEntry<Value>]) -> [MenuEntry<Value>] { part }
    public static func buildArray(_ parts: [[MenuEntry<Value>]]) -> [MenuEntry<Value>] { parts.flatMap { $0 } }
}
