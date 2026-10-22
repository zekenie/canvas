import AppKit
import Canvas
import CoreGraphics
import Keyboard
import Selection

/// Context menus, as a plugin: a right-click (or Control-click) on a shape opens the items that
/// apply to it, contributed by its kind, by horizontals it opts into, by other plugins for its kind,
/// and by any plugin for the kinds a scope reaches (`registrar.forShapes(holding:)`). Nothing
/// applies, and the click does nothing. The core only
/// passes the click along (`registrar.menuForSecondaryClick`); it never learns what's in a menu.
extension PluginID {
    public static let contextMenus: PluginID = "context-menus"
}

// MARK: The extension point

/// Context menu items: what each kind's shapes offer, and what the shapes of the kinds a scope
/// reaches offer (`registrar.forShapes(holding:)`, `forShapes(adopting:)`, `forEveryShape`: an item
/// for every kind with no scope is refused). Keyed by item: each item (and each submenu, and each item
/// in one) claims its target, group and id, so two plugins adding one item to a kind, or two scopes
/// that reach one kind, are `RegistryError.conflict` at startup. A kind's own item replaces a scope's
/// with the same group and id.
public enum ShapeContextMenus {}

extension ShapeContextMenus: KeyedExtensionPoint {
    public typealias Contribution = ContextMenuContribution
    public static var owner: PluginID { .contextMenus }
    public static var scope: PointScope { .scoped }

    public static func uniqueKeys(of contribution: ContextMenuContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.entries.flatMap { $0.paths(under: []) }.map { MenuItemKey(target: target, path: $0) }
    }

    /// Groups placed beside each other in a circle have no order.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try MenuGroupID.checkOrders(in: registry, point: "\(Self.self)")
    }

    /// Its items name their groups, each with its order if it says one: "ShapeContextMenus in
    /// BoardsMenuGroup before ShapeMenuGroup → subboard".
    public static func summary(of contribution: ContextMenuContribution, for target: ShapeTarget) -> String {
        "\(Self.self)" + MenuGroupID.reported(contribution.entries.map(\.key.group)) + (target == .any ? "" : " → \(target)")
    }
}

extension MenuGroupID {
    /// " in A, B before C": the groups named, once each in the order named, as the report says them.
    static func reported(_ groups: [MenuGroupID]) -> String {
        var named: [MenuGroupID] = []
        for group in groups where !named.contains(group) { named.append(group) }
        return named.isEmpty ? "" : " in " + named.map(\.reported).joined(separator: ", ")
    }

    /// Refuses groups placed beside each other in a circle, among those any item, in a submenu too,
    /// names (a group only an item made as the menu opens names is ordered as it's met). Both points
    /// run it, since either may name a group the other doesn't.
    @MainActor static func checkOrders(in registry: Registry, point: String) throws(RegistryError) {
        let shapes = registry.contributions(to: ShapeContextMenus.self).flatMap { $0.value.entries.flatMap { $0.paths(under: []) } }
        let canvas = registry.contributions(to: CanvasContextMenu.self).flatMap { $0.value.entries.flatMap { $0.paths(under: []) } }
        let actions = MenuGroupID(ActionsMenuGroup.self)
        if let held = (shapes + canvas).first(where: { $0.contains { $0.group == actions } }) {
            throw .invalid(point: point, reason: "\(held.map(\.id).joined(separator: " ▸ ")) is in ActionsMenuGroup, which holds no item: "
                           + "it's a place to be put beside, after every group right after a kind's own")
        }
        if let cycle = OrderRule.cycle(from: (shapes + canvas).flatMap { $0.map(\.group.anchor) }) {
            throw .invalid(point: point, reason: "menu groups placed beside each other in a circle: \(cycle)")
        }
    }
}

/// Where an item is: which shapes, and its group and id at each level ("box Arrange ▸ Send to Back").
struct MenuItemKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    let path: [EntryKey]
    var description: String { "\(target) \(path.map(\.id).joined(separator: " ▸ "))" }
}

/// An item's identity among its siblings: the same item on two kinds shares one.
struct EntryKey: Hashable {
    let group: MenuGroupID
    let id: String
}

/// What `ShapeContextMenus` stores: one plugin's items for one target, erased. Only the sugar below
/// makes one.
@MainActor
public struct ContextMenuContribution {
    let entries: [ErasedEntry]
}

/// An item or submenu over any record: hidden for a record it can't read. A class, so the items one
/// contribution gives several shapes can tell they're the same (a `perform` then runs once).
@MainActor
final class ErasedEntry {
    let title: String?
    let key: EntryKey
    let isShown: @MainActor (AnyShapeRecord) -> Bool
    let content: Content
    let stepName: String?

    enum Content {
        case item(isEnabled: @MainActor (AnyShapeRecord) -> Bool, isChecked: (@MainActor (AnyShapeRecord) -> Bool)?, action: Action)
        /// A command a plugin declared, asked of the menu's shapes as a whole.
        case command(CanvasCommand, dims: Bool)
        case submenu([ErasedEntry])
    }

    /// The command the item runs, if it runs one.
    var command: CanvasCommand? {
        if case .command(let command, _) = content { return command }
        return nil
    }

    enum Action {
        case edit(@MainActor (ShapeID, inout Transaction) -> Void)
        case perform(@MainActor ([ShapeID], CanvasEditor) -> Void)
    }

    /// `read` gets the entry's value from a record; `write` runs an edit on one shape's live value,
    /// in a transaction.
    init<Value>(_ entry: MenuEntry<Value>, read: @escaping @MainActor (AnyShapeRecord) -> Value?,
                write: @escaping @MainActor (ShapeID, inout Transaction, (inout Value) -> Void) -> Void) {
        title = entry.title
        stepName = entry.stepName
        key = EntryKey(group: entry.group, id: entry.id)
        let shown = entry.isShown
        isShown = { read($0).map(shown) ?? false }
        switch entry.content {
        case .item(let isEnabled, let isChecked, let action):
            var checked: (@MainActor (AnyShapeRecord) -> Bool)?
            if let isChecked { checked = { read($0).map(isChecked) ?? false } }
            let erased: Action = switch action {
            case .edit(let edit): .edit { id, transaction in write(id, &transaction, edit) }
            case .perform(let perform): .perform(perform)
            }
            content = .item(isEnabled: { read($0).map(isEnabled) ?? false }, isChecked: checked, action: erased)
        case .command(let command, let dims):
            content = .command(command, dims: dims)
        case .submenu(let entries):
            content = .submenu(entries.map { ErasedEntry($0, read: read, write: write) })
        case .dynamic:
            // Only items for the canvas are made when the menu opens (`MenuItems` over a `MenuSubject`),
            // and a shape's items are never over one: nothing to show.
            content = .submenu([])
        }
    }

    /// Its key, and its items' under it, each as the path from the top.
    func paths(under parent: [EntryKey]) -> [[EntryKey]] {
        let path = parent + [key]
        guard case .submenu(let entries) = content else { return [path] }
        return [path] + entries.flatMap { $0.paths(under: path) }
    }

    /// What it's called in this editor's menu: its own title, else its command's.
    func title(in editor: CanvasEditor) -> String { ContextMenuItems.title(title, command: command, id: key.id, in: editor) }

    /// Whether the editor can have it at all: one that names a command shows only while a plugin claims it.
    func isClaimed(in editor: CanvasEditor) -> Bool { command.map(editor.registry.claims) ?? true }
}

extension ContextMenuContribution {
    /// A kind's items, typed as its props.
    init<P: ShapeProps>(_: P.Type, _ entries: [MenuEntry<P>]) {
        self.entries = entries.map {
            ErasedEntry($0, read: { $0.typed(as: P.self)?.props }, write: { id, transaction, edit in
                transaction.update(id, as: P.self) { edit(&$0.props) }
            })
        }
    }

    /// An added property's items, over its value, on the shapes that have one.
    init<P: ShapeProperty>(property _: P.Type, _ entries: [MenuEntry<P.Value>]) {
        self.entries = entries.map {
            ErasedEntry($0, read: { $0[P.self] }, write: { id, transaction, edit in
                transaction.update(id) { record in
                    guard var value = record[P.self] else { return }
                    edit(&value)
                    record[P.self] = value
                }
            })
        }
    }

    /// Items over the record, for the kinds a scope reaches.
    init(everyShape entries: [MenuEntry<AnyShapeRecord>]) {
        self.entries = entries.map {
            ErasedEntry($0, read: { $0 }, write: { id, transaction, edit in transaction.update(id) { edit(&$0) } })
        }
    }
}

// MARK: Sugar (what verticals and horizontals write)

extension ShapeRegistrar {
    /// This kind's items in its context menu, in one call (one contribution, one report line):
    ///
    ///     sub.contextMenu {
    ///         MenuItem(command: .openSelection, title: "Open", in: BoardsMenuGroup.self)
    ///     }
    ///
    /// A horizontal's opt-in sugar calls this too, so opting into its feature brings its items.
    public mutating func contextMenu(@MenuBuilder<Definition.Props> _ items: () -> [MenuEntry<Definition.Props>]) {
        contribute(ContextMenuContribution(Definition.Props.self, items()), to: ShapeContextMenus.self)
    }

    /// Items over an added property's value, on this kind's shapes that have one: what a
    /// horizontal's opt-in sugar contributes for the property it opts the kind into.
    public mutating func contextMenu<P: ShapeProperty>(of _: P.Type, @MenuBuilder<P.Value> _ items: () -> [MenuEntry<P.Value>]) {
        contribute(ContextMenuContribution(property: P.self, items()), to: ShapeContextMenus.self)
    }
}

extension PluginRegistrar {
    /// Items for a kind another plugin registers. Typed as the kind's own.
    public mutating func contextMenu<P: ShapeProps>(_: P.Type, @MenuBuilder<P> _ items: () -> [MenuEntry<P>]) {
        contribute(ContextMenuContribution(P.self, items()), to: ShapeContextMenus.self, for: .kind(P.kind))
    }

    /// Items over an added property's value, on the shapes of every kind that holds it, whatever its
    /// kind: the report says "every shape holding <key>".
    public mutating func contextMenu<P: ShapeProperty>(of _: P.Type, @MenuBuilder<P.Value> _ items: () -> [MenuEntry<P.Value>]) {
        contribute(ContextMenuContribution(property: P.self, items()), to: ShapeContextMenus.self, for: .holding(P.key))
    }
}

extension ScopedRegistrar {
    /// Items over the record, on the shapes of the kinds the scope reaches; `when` picks shapes
    /// (`{ $0.box != nil }` for those with a frame). They come after a kind's own in their group.
    public mutating func contextMenu(@MenuBuilder<AnyShapeRecord> _ items: () -> [MenuEntry<AnyShapeRecord>]) {
        contribute(ContextMenuContribution(everyShape: items()), to: ShapeContextMenus.self)
    }

    /// Items for the canvas (`registrar.contextMenuForCanvas`), over the menu's `MenuSubject`, shown
    /// only in a menu whose every shape is of a kind the scope reaches, so never on empty canvas: a
    /// feature's items for a selection, which run its commands or are made when the menu opens.
    ///
    ///     registrar.forShapes(holding: LockedProperty.self) { lock in
    ///         lock.contextMenuForCanvas {
    ///             MenuItem(command: .lock, in: StateMenuGroup.self)
    ///             MenuItem(command: .unlock, in: StateMenuGroup.self)
    ///         }
    ///     }
    public mutating func contextMenuForCanvas(@MenuBuilder<MenuSubject> _ items: () -> [MenuEntry<MenuSubject>]) {
        contribute(CanvasMenuContribution(entries: items()), to: CanvasContextMenu.self)
    }
}

// MARK: Items for the canvas

/// Items that aren't any one shape's (Cut, Copy and Paste; Delete and Select All, this plugin's
/// own). They're in every context menu: on shapes, after the shapes' own items in their groups'
/// order, and on empty canvas, where they're the menu. Those a scope gives
/// (`forShapes(holding:) { $0.contextMenuForCanvas { … } }`) are only in a menu whose every shape
/// the scope reaches. Keyed by group and id, as a shape's are: two plugins adding one item are a
/// `conflict`, and a shape's own item with the same group and id takes its place, shown or not.
public enum CanvasContextMenu {}

extension CanvasContextMenu: KeyedExtensionPoint {
    public typealias Contribution = CanvasMenuContribution
    public static var owner: PluginID { .contextMenus }

    public static func uniqueKeys(of contribution: CanvasMenuContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.entries.flatMap { $0.paths(under: []) }.map { MenuItemKey(target: target, path: $0) }
    }

    /// Groups placed beside each other in a circle have no order.
    public static func check(_ registry: Registry) throws(RegistryError) {
        try MenuGroupID.checkOrders(in: registry, point: "\(Self.self)")
    }

    /// Its items name their groups, each with its order if it says one: "CanvasContextMenu in
    /// StateMenuGroup before SelectionMenuGroup → every shape holding locked".
    public static func summary(of contribution: CanvasMenuContribution, for target: ShapeTarget) -> String {
        "\(Self.self)" + MenuGroupID.reported(contribution.entries.map(\.group)) + (target == .any ? "" : " → \(target)")
    }
}

/// What a context menu is for, as its items for the canvas see it, asked once per menu: what its
/// commands act on (the core's `CommandSubject`). Its `shapes` are the selection, on a selected shape;
/// the shape right-clicked, which becomes the selection, on one that wasn't; none on empty canvas. Its
/// `point` is where the menu was asked for, in world units, the click: an item that puts something
/// down puts it there (Paste lands centered on it), and gets it as the command's subject or through
/// `MenuItem`'s `edit` form, which is handed the subject. Nil in the selection's menu (a menu bar's
/// Shape menu), which no click asks for: an item that goes by where the click was leaves itself out.
public typealias MenuSubject = CommandSubject

/// What `CanvasContextMenu` stores: one plugin's items for the canvas. Only the sugar makes one.
@MainActor
public struct CanvasMenuContribution {
    let entries: [MenuEntry<MenuSubject>]
}

extension PluginRegistrar {
    /// Items for the canvas, in every context menu (see `CanvasContextMenu`), over the menu's
    /// `MenuSubject`. They take either of `MenuItem`'s forms: `perform`, which gets the subject's
    /// shapes and the editor; or `edit`, which is handed the subject itself, once, in no
    /// transaction, for an item that needs more of it than its shapes (where the menu was opened,
    /// `point`). The subject can't be changed (its members are constants): either form changes the
    /// document only through `editor.transact`.
    ///
    ///     registrar.contextMenuForCanvas {
    ///         MenuItem("Flag", when: { !$0.shapes.isEmpty }) { ids, editor in editor.flag(ids) }
    ///         MenuItem(command: .paste, in: ClipboardMenuGroup.self)      // a command: shown while it can act
    ///     }
    public mutating func contextMenuForCanvas(@MenuBuilder<MenuSubject> _ items: () -> [MenuEntry<MenuSubject>]) {
        contribute(CanvasMenuContribution(entries: items()), to: CanvasContextMenu.self)
    }
}

// MARK: The plugin

/// What a shape is made from its menu, after every kind's own groups and right before Delete:
/// locked (Locking's Lock and Unlock), a type (Types' Is a ▸). Together, with no line between them.
public enum StateMenuGroup {}
extension StateMenuGroup: MenuGroup {
    public static var order: Order<Self> { .before(SelectionMenuGroup.self) }
}

/// Selection's commands, last in every menu, after Lock, as Keynote has Delete: Delete on the
/// menu's shapes, and Select All on empty canvas.
public enum SelectionMenuGroup {}
extension SelectionMenuGroup: MenuGroup {
    public static var order: Order<Self> { .last }
}

/// Claims the secondary click and the selection's menu (a menu bar's Shape menu: the same items over
/// the selection, less the commands the menu bar runs), and adds two items that are Selection's
/// commands, since a menu is for the selection: Delete, in every shape's menu, runs `.delete` on the
/// menu's shapes (the selection: a right-click on a shape that isn't selected selects it before the
/// item runs), as the Delete key does, so a locked one shakes; and Select All, on empty canvas while
/// the board has shapes, runs `.selectAll`. Whether they show is asked of the menu's subject (the
/// commands' rules, with the menu's shapes), never of `canPerform`, which reads the selection as it
/// was before the click. So with Selection installed, a right-click shows no menu only on an empty
/// board with nothing else to offer there.
public struct ContextMenusPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .contextMenus }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ContextMenuState(editor: $0) }
        registrar.menuForSecondaryClick { editor, pointer in editor.service(ContextMenuState.self)?.menu(for: pointer) }
        registrar.menuForSelection { editor, commands, popped in
            editor.service(ContextMenuState.self)?.menuForSelection(omitting: popped ? commands.union([.showContextMenu]) : commands)
        }
        // The selection's menu by key (⌃↩, the Menu key) and by VoiceOver's Show Menu: popped under the
        // selection, its first item highlighted, less this item, which would only open itself again.
        registrar.command(.showContextMenu, title: ContextMenusStyle.showContextMenu, shortcuts: [.controlReturn, .menu], runs: .whenIdle,
                          isEnabled: { !$0.shapes.isEmpty }) { subject in
            subject.editor.showContextMenuForSelection()
        }
        registrar.contextMenuForCanvas {
            MenuItem(command: .showContextMenu, in: SelectionMenuGroup.self, when: { $0.point == nil })
            MenuItem(command: .delete, in: SelectionMenuGroup.self)
            MenuItem(command: .selectAll, in: SelectionMenuGroup.self, when: { $0.shapes.isEmpty })
        }
    }
}

extension CanvasCommand {
    /// Shape › Show Context Menu: the selection's menu, opened under the selection.
    public static let showContextMenu: CanvasCommand = "showContextMenu"
}

extension KeyChord {
    /// ⌃↩: the selection's menu (Return alone opens the selection).
    static let controlReturn = KeyChord(KeyChord.return.key, .control)
}

@MainActor
enum ContextMenusStyle {
    static let showContextMenu = "Show Context Menu"
}

extension CanvasEditor {
    /// Opens the selection's menu under the selection, its first item highlighted so Return takes it;
    /// what a key and VoiceOver's Show Menu do. Nothing with nothing selected.
    public func showContextMenuForSelection() {
        guard let bounds = selectionBounds,
              let menu = service(ContextMenuState.self)?.menuForSelection(omitting: [.showContextMenu]) else { return }
        popUpMenu(menu, below: bounds, highlighting: menu.items.first { !$0.isSeparatorItem && $0.isEnabled })
    }
}
