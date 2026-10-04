import Canvas
import CoreGraphics

/// Context menus, as a plugin: a right-click (or Control-click) on a shape opens the items that
/// apply to it, contributed by its kind, by horizontals it opts into, by other plugins for its kind,
/// and by any plugin for every shape. Nothing applies, and the click does nothing. The core only
/// passes the click along (`registrar.menuForSecondaryClick`); it never learns what's in a menu.
extension PluginID {
    public static let contextMenus: PluginID = "context-menus"
}

// MARK: The extension point

/// Context menu items: what each kind's shapes offer, and what every shape does (`.any`). Keyed by
/// item: each item (and each submenu, and each item in one) claims its target, group and id, so two
/// plugins adding one item to a kind, or to every shape, are `RegistryError.conflict` at startup. A
/// kind's own item replaces an every-shape one with the same group and id.
public enum ShapeContextMenus {}

extension ShapeContextMenus: KeyedExtensionPoint {
    public typealias Contribution = ContextMenuContribution
    public static var owner: PluginID { .contextMenus }

    public static func uniqueKeys(of contribution: ContextMenuContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.entries.flatMap { $0.paths(under: []) }.map { MenuItemKey(target: target, path: $0) }
    }
}

/// Where an item is: which shapes, and its group and id at each level ("* Arrange ▸ Send to Back").
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
    /// Which kinds, by their definition: every shape's items may leave some out.
    var appliesTo: @MainActor (any ShapeDefinition) -> Bool = { _ in true }
}

/// An item or submenu over any record: hidden for a record it can't read. A class, so the items one
/// contribution gives several shapes can tell they're the same (a `perform` then runs once).
@MainActor
final class ErasedEntry {
    let title: String
    let key: EntryKey
    let isShown: @MainActor (AnyShapeRecord) -> Bool
    let content: Content

    enum Content {
        case item(isEnabled: @MainActor (AnyShapeRecord) -> Bool, isChecked: (@MainActor (AnyShapeRecord) -> Bool)?, action: Action)
        case submenu([ErasedEntry])
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
        case .submenu(let entries):
            content = .submenu(entries.map { ErasedEntry($0, read: read, write: write) })
        }
    }

    /// Its key, and its items' under it, each as the path from the top.
    func paths(under parent: [EntryKey]) -> [[EntryKey]] {
        let path = parent + [key]
        guard case .submenu(let entries) = content else { return [path] }
        return [path] + entries.flatMap { $0.paths(under: path) }
    }
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

    /// Every shape's items, over the record.
    init(everyShape entries: [MenuEntry<AnyShapeRecord>], where appliesTo: @escaping @MainActor (any ShapeDefinition) -> Bool) {
        self.entries = entries.map {
            ErasedEntry($0, read: { $0 }, write: { id, transaction, edit in transaction.update(id) { edit(&$0) } })
        }
        self.appliesTo = appliesTo
    }
}

// MARK: Sugar (what verticals and horizontals write)

extension ShapeRegistrar {
    /// This kind's items in its context menu, in one call (one contribution, one report line):
    ///
    ///     sub.contextMenu {
    ///         MenuItem("Open", in: BoardsMenuGroup.self) { ids, editor in
    ///             if let first = ids.first { editor.open(first) }
    ///         }
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

    /// Items over an added property's value, on every shape that has one, whatever its kind.
    public mutating func contextMenu<P: ShapeProperty>(of _: P.Type, @MenuBuilder<P.Value> _ items: () -> [MenuEntry<P.Value>]) {
        contribute(ContextMenuContribution(property: P.self, items()), to: ShapeContextMenus.self, for: .any)
    }

    /// Items for every shape, over the record. `where` picks kinds by their definition, and so by
    /// capability (`where: { !($0 is any PaintOrderAnchored) }`); `when` picks shapes
    /// (`{ $0.box != nil }` for those with a frame). They come after a kind's own in their group.
    public mutating func contextMenuForEveryShape(where appliesTo: @escaping @MainActor (any ShapeDefinition) -> Bool = { _ in true },
                                                  @MenuBuilder<AnyShapeRecord> _ items: () -> [MenuEntry<AnyShapeRecord>]) {
        contribute(ContextMenuContribution(everyShape: items(), where: appliesTo), to: ShapeContextMenus.self, for: .any)
    }
}

// MARK: Items for the canvas

/// Items that aren't any one shape's (Cut, Copy and Paste; Delete and Select All, this plugin's
/// own). They're in every context menu: on shapes, after the shapes' own items in their groups'
/// order, and on empty canvas, where they're the menu. Keyed by group and id, as a shape's are: two plugins adding one item are a
/// `conflict`, and a shape's own item with the same group and id takes its place, shown or not.
public enum CanvasContextMenu {}

extension CanvasContextMenu: KeyedExtensionPoint {
    public typealias Contribution = CanvasMenuContribution
    public static var owner: PluginID { .contextMenus }

    public static func uniqueKeys(of contribution: CanvasMenuContribution, for target: ShapeTarget) -> [AnyHashable] {
        contribution.entries.flatMap { $0.paths(under: []) }.map { MenuItemKey(target: target, path: $0) }
    }
}

/// What a context menu is for, as its items for the canvas see it: asked once per menu.
@MainActor
public struct MenuSubject {
    /// The selection, on a selected shape; the shape right-clicked, which becomes the selection,
    /// on one that wasn't; none on empty canvas.
    public let shapes: [ShapeID]
    /// Where the menu was asked for, in world units: the click. An item that puts something down
    /// puts it there (the menu's Paste lands centered on it). An item gets it through `MenuItem`'s
    /// `edit` form, which is handed the subject.
    public let point: CGPoint
    public let editor: CanvasEditor
}

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
    ///         MenuItem("Copy", when: { !$0.shapes.isEmpty }) { ids, editor in editor.copy(ids) }
    ///         MenuItem("Paste", when: { $0.editor.canPaste }) { subject in subject.editor.paste(centeredAt: subject.point) }
    ///     }
    public mutating func contextMenuForCanvas(@MenuBuilder<MenuSubject> _ items: () -> [MenuEntry<MenuSubject>]) {
        contribute(CanvasMenuContribution(entries: items()), to: CanvasContextMenu.self)
    }
}

// MARK: The plugin

/// Selection's commands, last in every menu, after Lock, as Keynote has Delete: Delete on the
/// menu's shapes, and Select All on empty canvas.
public enum SelectionMenuGroup {}
extension SelectionMenuGroup: MenuGroup {
    public static var order: Int { 400 }
}

/// Claims the secondary click, and adds two items that are Selection's commands, since a menu is
/// for the selection: Delete, in every shape's menu, runs `.delete` on the menu's shapes (the
/// selection: a right-click on a shape that isn't selected selects it before the item runs), as
/// the Delete key does, so a locked one shakes; and Select All, on empty canvas while the board has
/// shapes, runs `.selectAll`. Whether they show is asked of the menu's subject, never of
/// `canPerform`, which reads the selection as it was before the click. So with Selection
/// installed, a right-click shows no menu only on an empty board with nothing else to offer there.
public struct ContextMenusPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .contextMenus }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ContextMenuState(editor: $0) }
        registrar.menuForSecondaryClick { editor, pointer in editor.service(ContextMenuState.self)?.menu(for: pointer) }
        registrar.contextMenuForCanvas {
            MenuItem("Delete", in: SelectionMenuGroup.self, when: { !$0.shapes.isEmpty }) { _, editor in editor.perform(.delete) }
            MenuItem("Select All", in: SelectionMenuGroup.self, when: { $0.shapes.isEmpty && !$0.editor.document.shapes.isEmpty }) { _, editor in
                editor.perform(.selectAll)
            }
        }
    }
}
