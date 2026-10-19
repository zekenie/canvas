import Canvas

// MARK: Groups

/// A group of items in a context menu, with a separator between groups. The type is the group, as
/// a tab is the detail panel's: every item that names it lands in it, sharing one means importing
/// the module that declares it, and a typo doesn't compile.
///
///     public enum MentionsMenuGroup {}
///     extension MentionsMenuGroup: MenuGroup {
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
    /// transaction. Setting what a shape already has commits nothing. Over a `MenuSubject` (an item
    /// for the canvas), `edit` is handed the subject instead, once, in the item's undo group and in
    /// no transaction, and changes the document only through `editor.transact`, as `perform` does.
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
    /// `editor.transact`. The undo step is named by the title unless `stepName` says otherwise (an item
    /// in a submenu whose title only makes sense there: "Set Level" ▸ "High" is the step "Set Level
    /// High").
    public init(_ title: String, in group: any MenuGroup.Type = ShapeMenuGroup.self, id: String? = nil,
                when isShown: @escaping @MainActor (Value) -> Bool = { _ in true },
                isEnabled: @escaping @MainActor (Value) -> Bool = { _ in true },
                isChecked: (@MainActor (Value) -> Bool)? = nil,
                stepName: String? = nil,
                perform: @escaping @MainActor ([ShapeID], CanvasEditor) -> Void) {
        entry = MenuEntry(title: title, group: MenuGroupID(group), id: id ?? title, isShown: isShown,
                          content: .item(isEnabled: isEnabled, isChecked: isChecked, action: .perform(perform)), stepName: stepName)
    }

    /// An item that runs a command a plugin declared (`registrar.command`), as its key and its menu bar
    /// item do, on what the menu is for: the menu's shapes, and its click (`editor.perform(_:on:at:)`).
    /// It shows while the command can act on them (its rule, the one rule its key and every item of it
    /// go by), and while a plugin claims the command; `when` leaves it out where else it would show
    /// (Select All on empty canvas only). With `dims: true` it shows wherever `when` says, dimmed while
    /// the command can't act (Go to Original, for a reference whose original is gone). It is titled as
    /// the command is (`registry.title(of:)`), unless `title` says otherwise, shows the command's key
    /// (`registry.menuKey(of:)`), and its `id` is the title, else the command's name. In the selection's
    /// menu it is dimmed while the command can't run there (its moment too: a shape being edited dims what
    /// runs `.whenIdle`).
    ///
    ///     registrar.contextMenuForCanvas { MenuItem(command: .group, in: StateMenuGroup.self) }
    public init(command: CanvasCommand, title: String? = nil, in group: any MenuGroup.Type = ShapeMenuGroup.self, id: String? = nil,
                when isShown: @escaping @MainActor (Value) -> Bool = { _ in true }, dims: Bool = false) {
        entry = MenuEntry(title: title, group: MenuGroupID(group), id: id ?? title ?? command.rawValue, isShown: isShown,
                          content: .command(command, dims: dims))
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

/// Entries made when the menu opens, from what the menu is for (an item for the canvas: they come
/// from the file, not from the registry). `make` is asked once per menu, with its `MenuSubject`,
/// and what it returns is shown as if written out in place: items and submenus, in its order.
/// Registered like any item, by `(group, id)`: two plugins claiming one are a `conflict`. The ids
/// of what `make` returns are the menu's to deduplicate, the first of each key (in this level)
/// staying. A kind's own item with the same group and id as one of them takes its place, as for any
/// item for the canvas.
///
///     registrar.contextMenuForCanvas {
///         MenuItems(in: FlagMenuGroup.self, id: "recent-flags") { subject in
///             for flag in recentFlags(in: subject.editor) {
///                 MenuItem("Flag as \(flag.name)", in: FlagMenuGroup.self, id: flag.id) { ids, editor in … }
///             }
///         }
///     }
public struct MenuItems<Value> {
    let entry: MenuEntry<Value>
}

extension MenuItems where Value == MenuSubject {
    public init(in group: any MenuGroup.Type, id: String,
                @MenuBuilder<MenuSubject> make: @escaping @MainActor (MenuSubject) -> [MenuEntry<MenuSubject>]) {
        entry = MenuEntry(title: id, group: MenuGroupID(group), id: id, isShown: { _ in true }, content: .dynamic(make))
    }
}

/// An item or a submenu, as `MenuBuilder` collects them.
public struct MenuEntry<Value> {
    /// Nil: the command's title (`registry.title(of:)`).
    let title: String?
    let group: MenuGroupID
    let id: String
    let isShown: @MainActor (Value) -> Bool
    let content: Content
    /// What the undo step is called, if not the title.
    var stepName: String?

    enum Content {
        case item(isEnabled: @MainActor (Value) -> Bool, isChecked: (@MainActor (Value) -> Bool)?, action: Action)
        /// A command a plugin declared, run on the menu's shapes and click; dimmed rather than left out
        /// while it can't act, with `dims`.
        case command(CanvasCommand, dims: Bool)
        case submenu([MenuEntry<Value>])
        /// Entries made when the menu opens; only for the canvas's (`MenuItems`).
        case dynamic(@MainActor (MenuSubject) -> [MenuEntry<MenuSubject>])
    }

    /// The command the item runs, if it runs one.
    var command: CanvasCommand? {
        if case .command(let command, _) = content { return command }
        return nil
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
    public static func buildExpression(_ items: MenuItems<Value>) -> [MenuEntry<Value>] { [items.entry] }
    public static func buildBlock(_ parts: [MenuEntry<Value>]...) -> [MenuEntry<Value>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [MenuEntry<Value>]?) -> [MenuEntry<Value>] { part ?? [] }
    public static func buildEither(first part: [MenuEntry<Value>]) -> [MenuEntry<Value>] { part }
    public static func buildEither(second part: [MenuEntry<Value>]) -> [MenuEntry<Value>] { part }
    public static func buildArray(_ parts: [[MenuEntry<Value>]]) -> [MenuEntry<Value>] { parts.flatMap { $0 } }
}
