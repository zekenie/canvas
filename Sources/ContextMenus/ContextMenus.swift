import Canvas

/// Context menus, as a plugin: a right-click (or Control-click) on a shape opens the items that
/// apply to it, contributed by its kind, by horizontals it opts into, by bridges, and by any plugin
/// for every shape. Nothing applies, and the click does nothing. The core only passes the click
/// along (`registrar.menuForSecondaryClick`); it never learns what's in a menu.
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

/// Where an item is: which shapes, and its group and id at each level ("task-card Status ▸ Done").
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

    /// Every shape's items, over the record.
    init(everyShape entries: [MenuEntry<AnyShapeRecord>], where appliesTo: @escaping @MainActor (any ShapeDefinition) -> Bool) {
        self.entries = entries.map {
            ErasedEntry($0, read: { $0 }, write: { id, transaction, edit in transaction.update(id) { edit(&$0) } })
        }
        self.appliesTo = appliesTo
    }
}

// MARK: Sugar (what verticals, horizontals and bridges write)

extension ShapeRegistrar {
    /// This kind's items in its context menu, in one call (one contribution, one report line):
    ///
    ///     task.contextMenu {
    ///         Submenu("Status") {
    ///             for status in TaskStatus.allCases {
    ///                 MenuItem(status.label, isChecked: { $0.status == status }) { $0.status = status }
    ///             }
    ///         }
    ///     }
    ///
    /// A horizontal's opt-in sugar calls this too, so opting into its feature brings its items.
    public mutating func contextMenu(@MenuBuilder<Definition.Props> _ items: () -> [MenuEntry<Definition.Props>]) {
        contribute(ContextMenuContribution(Definition.Props.self, items()), to: ShapeContextMenus.self)
    }
}

extension PluginRegistrar {
    /// Items for a kind another plugin registers (bridges). Typed as the kind's own.
    public mutating func contextMenu<P: ShapeProps>(_: P.Type, @MenuBuilder<P> _ items: () -> [MenuEntry<P>]) {
        contribute(ContextMenuContribution(P.self, items()), to: ShapeContextMenus.self, for: .kind(P.kind))
    }

    /// Items for every shape, over the record. `where` picks kinds by their definition, and so by
    /// capability (`where: { !($0 is any PaintOrderAnchored) }`); `when` picks shapes
    /// (`{ $0.box != nil }` for those with a frame). They come after a kind's own in their group.
    public mutating func contextMenuForEveryShape(where appliesTo: @escaping @MainActor (any ShapeDefinition) -> Bool = { _ in true },
                                                  @MenuBuilder<AnyShapeRecord> _ items: () -> [MenuEntry<AnyShapeRecord>]) {
        contribute(ContextMenuContribution(everyShape: items(), where: appliesTo), to: ShapeContextMenus.self, for: .any)
    }
}

// MARK: The plugin

/// Claims the secondary click. Contributes no items of its own: with nothing else installed, a
/// right-click does nothing.
public struct ContextMenusPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .contextMenus }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ContextMenuState(editor: $0) }
        registrar.menuForSecondaryClick { editor, pointer in editor.service(ContextMenuState.self)?.menu(for: pointer) }
    }
}
