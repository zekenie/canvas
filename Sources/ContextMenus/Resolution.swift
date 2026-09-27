import AppKit
import Canvas
import Selection

/// Per editor (so per window): each kind's items, gathered once (the registry is frozen), and what
/// a secondary click opens.
@MainActor
final class ContextMenuState {
    private unowned let editor: CanvasEditor
    private var candidates: [ShapeKind: [ErasedEntry]] = [:]

    init(editor: CanvasEditor) { self.editor = editor }

    /// A secondary click: the context menu for what it's on, as the select tool sees it. That's the
    /// selection, on a selected shape or on empty space inside a multi-selection's box; otherwise
    /// the selectable shape there, alone (the select tool's hit rule, so unselectable shapes are
    /// seen through). With a menu to show, editing ends and a shape that wasn't selected becomes
    /// the selection, as in Keynote and tldraw. Without one (empty canvas, or nothing that
    /// applies), nothing changes. A Control-click counts only in the select tool: other tools read
    /// ⌃ as a modifier (the arrow tool's binds nothing), so it's a press there.
    func menu(for pointer: Pointer) -> NSMenu? {
        if pointer.isControlClick, editor.currentToolID != .select { return nil }
        let hit = editor.selectableShape(at: pointer.world)
        let ids: [ShapeID]
        var selects: ShapeID?
        if let hit, !editor.isSelected(hit) {
            ids = [hit]
            selects = hit
        } else if hit != nil || editor.isInSelectionBox(pointer.world) {
            ids = editor.selectedShapeIDs
        } else {
            return nil
        }
        var entries = entries(for: ids)
        guard !entries.isEmpty else { return nil }
        let revision = editor.revision
        editor.endEditing()
        if let selects { editor.selection = selects }
        // Ending editing may have saved the editing view: resolve against what it saved.
        if editor.revision != revision { entries = self.entries(for: ids) }
        return entries.isEmpty ? nil : ContextMenuItems.menu(entries)
    }

    /// What the menu holds for these shapes: the items that apply to every one of them.
    func entries(for ids: [ShapeID]) -> [ResolvedEntry] {
        let records = ids.compactMap { editor.document[$0] }
        return ContextMenuItems.resolve(records.map { ($0, ContextMenuItems.shown(candidates(for: $0.kind), for: $0)) }, in: editor)
    }

    /// The kind's own entries, then every shape's that apply to it, each in plugin and builder order.
    private func candidates(for kind: ShapeKind) -> [ErasedEntry] {
        if let known = candidates[kind] { return known }
        guard let definition = editor.registry.definition(for: kind) else { return [] }
        let found = editor.registry.contributions(to: ShapeContextMenus.self, for: kind)
            .filter { $0.appliesTo(definition) }.flatMap(\.entries)
        candidates[kind] = found
        return found
    }
}

extension ContextMenuState: EditorService {}

/// One item of a menu as it will show, for the shapes it's for.
@MainActor
struct ResolvedEntry {
    let title: String
    let group: MenuGroupID
    let content: Content

    enum Content {
        case item(isEnabled: Bool, state: NSControl.StateValue?, perform: @MainActor () -> Void)
        case submenu([ResolvedEntry])
    }
}

@MainActor
enum ContextMenuItems {
    /// What shows for one shape at one level: the first entry with each key (a kind's own before
    /// every shape's), then only those whose `when` holds.
    static func shown(_ entries: [ErasedEntry], for record: AnyShapeRecord) -> [ErasedEntry] {
        var seen = Set<EntryKey>()
        return entries.filter { seen.insert($0.key).inserted }.filter { $0.isShown(record) }
    }

    /// The entries every shape shows, in the first shape's order. An item is enabled if it is for
    /// any shape, and runs on those; it's checked if every shape checks it, and mixed if some do
    /// (where some kinds' items have no check, theirs count as unchecked). A submenu holds what its
    /// items resolve to, and is left out if that's nothing.
    static func resolve(_ shapes: [(record: AnyShapeRecord, entries: [ErasedEntry])], in editor: CanvasEditor) -> [ResolvedEntry] {
        guard let first = shapes.first else { return [] }
        return first.entries.compactMap { entry in
            let matches = shapes.compactMap { shape in shape.entries.first { $0.key == entry.key }.map { (shape.record, $0) } }
            guard matches.count == shapes.count else { return nil }
            switch entry.content {
            case .item:
                return item(entry, matches, in: editor)
            case .submenu:
                var levels: [(record: AnyShapeRecord, entries: [ErasedEntry])] = []
                for (record, match) in matches {
                    guard case .submenu(let entries) = match.content else { return nil }
                    levels.append((record, shown(entries, for: record)))
                }
                let items = resolve(levels, in: editor)
                return items.isEmpty ? nil : ResolvedEntry(title: entry.title, group: entry.key.group, content: .submenu(items))
            }
        }
    }

    private static func item(_ entry: ErasedEntry, _ matches: [(AnyShapeRecord, ErasedEntry)], in editor: CanvasEditor) -> ResolvedEntry? {
        var enabled: [(id: ShapeID, action: ErasedEntry.Action, from: ErasedEntry)] = []
        var checks: [Bool?] = []
        for (record, match) in matches {
            guard case .item(let isEnabled, let isChecked, let action) = match.content else { return nil }
            if isEnabled(record) { enabled.append((record.id, action, match)) }
            checks.append(isChecked.map { $0(record) })
        }
        let state: NSControl.StateValue? = checks.allSatisfy { $0 == nil } ? nil
            : checks.allSatisfy { $0 == true } ? .on : checks.contains(true) ? .mixed : .off
        return ResolvedEntry(title: entry.title, group: entry.key.group, content: .item(isEnabled: !enabled.isEmpty, state: state) {
            perform(enabled, in: editor)
        })
    }

    /// Every edit in one transaction, then each contribution's `perform` once, with its shapes.
    private static func perform(_ targets: [(id: ShapeID, action: ErasedEntry.Action, from: ErasedEntry)], in editor: CanvasEditor) {
        let edits = targets.compactMap { target -> (ShapeID, @MainActor (ShapeID, inout Transaction) -> Void)? in
            guard case .edit(let edit) = target.action else { return nil }
            return (target.id, edit)
        }
        if !edits.isEmpty {
            editor.transact { transaction in
                for (id, edit) in edits { edit(id, &transaction) }
            }
        }
        var runs: [(from: ErasedEntry, ids: [ShapeID], perform: @MainActor ([ShapeID], CanvasEditor) -> Void)] = []
        for target in targets {
            guard case .perform(let perform) = target.action else { continue }
            if let index = runs.firstIndex(where: { $0.from === target.from }) {
                runs[index].ids.append(target.id)
            } else {
                runs.append((target.from, [target.id], perform))
            }
        }
        for run in runs { run.perform(run.ids, editor) }
    }

    /// Groups sorted by `order`, then first appearance, with a separator between them.
    static func menu(_ entries: [ResolvedEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var groups: [MenuGroupID] = []
        for entry in entries where !groups.contains(entry.group) { groups.append(entry.group) }
        let sorted = groups.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map(\.element)
        for (index, group) in sorted.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in entries where entry.group == group {
                switch entry.content {
                case .item(let isEnabled, let state, let perform):
                    let action = MenuAction(perform)
                    let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.fire), keyEquivalent: "")
                    item.target = action
                    item.representedObject = action          // the item holds its target weakly
                    item.isEnabled = isEnabled
                    if let state { item.state = state }
                    menu.addItem(item)
                case .submenu(let children):
                    let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    item.submenu = self.menu(children)
                    menu.addItem(item)
                }
            }
        }
        return menu
    }
}

/// What a menu item runs: its target, kept alive as its `representedObject`. The item stays a
/// plain NSMenuItem, since AppKit may copy one through initializers a subclass wouldn't inherit.
final class MenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    /// AppKit sends menu actions on the main thread.
    @MainActor @objc func fire() { run() }
}
