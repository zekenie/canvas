import AppKit
import Canvas
import Selection

/// Per editor (so per window): each kind's items, gathered once (the registry is frozen), and what
/// a secondary click opens.
@MainActor
final class ContextMenuState {
    private unowned let editor: CanvasEditor
    private var candidates: [ShapeKind: [ErasedEntry]] = [:]
    /// The items for the canvas (`CanvasContextMenu`), in plugin and builder order.
    private let canvasEntries: [MenuEntry<MenuSubject>]

    init(editor: CanvasEditor) {
        self.editor = editor
        canvasEntries = editor.registry.contributions(to: CanvasContextMenu.self).flatMap(\.value.entries)
    }

    /// A secondary click: the context menu for what it's on, as the select tool sees it. That's the
    /// selection, on a selected shape or on empty space inside a multi-selection's box; otherwise
    /// the selectable shape there, alone (the select tool's hit rule: unselectable shapes are seen
    /// through, and what's drawn for a shape outside it is the shape); otherwise the canvas, whose
    /// menu is only its own items. With a menu to show, editing ends and a shape that wasn't
    /// selected becomes the selection, as in Keynote and tldraw. Without one (nothing applies),
    /// nothing changes. A Control-click counts only in the select tool: other tools get it as a
    /// press with ⌃ held.
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
            ids = []
        }
        var entries = entries(for: ids, at: pointer.world)
        guard !entries.isEmpty else { return nil }
        let revision = editor.revision
        editor.endEditing()
        if let selects { editor.selection = selects }
        // Ending editing may have saved the editing view: resolve against what it saved.
        if editor.revision != revision { entries = self.entries(for: ids, at: pointer.world) }
        return entries.isEmpty ? nil : ContextMenuItems.menu(entries)
    }

    /// What the menu asked for at `point` (world units) holds for these shapes: the items that
    /// apply to every one of them, then the canvas's items, less any whose place a shape's own item
    /// takes (shown or not, as a kind's own item takes an every-shape one's).
    func entries(for ids: [ShapeID], at point: CGPoint) -> [ResolvedEntry] {
        let records = ids.compactMap { editor.document[$0] }
        let own = ContextMenuItems.resolve(records.map { ($0, ContextMenuItems.shown(candidates(for: $0.kind), for: $0)) }, in: editor)
        let taken = Set(Set(records.map(\.kind)).flatMap { candidates(for: $0).map(\.key) })
        let canvas = ContextMenuItems.resolve(canvasEntries, for: MenuSubject(shapes: records.map(\.id), point: point, editor: editor))
        return own + canvas.filter { !taken.contains($0.key) }
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

extension ContextMenuState: EditorService {
    /// Nothing kept per shape, so nothing to follow to another board.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

/// One item of a menu as it will show, for the shapes it's for.
@MainActor
struct ResolvedEntry {
    let title: String
    let key: EntryKey
    let content: Content
    var group: MenuGroupID { key.group }

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
                return items.isEmpty ? nil : ResolvedEntry(title: entry.title, key: entry.key, content: .submenu(items))
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
        // Whatever the item does, over every shape, is one undo step, named by the item.
        return ResolvedEntry(title: entry.title, key: entry.key, content: .item(isEnabled: !enabled.isEmpty, state: state) {
            editor.undoHistory.group(entry.title) { perform(enabled, in: editor) }
        })
    }

    /// The canvas's items for a menu's subject, each asked once: those shown, in order, and
    /// submenus with something in them.
    static func resolve(_ entries: [MenuEntry<MenuSubject>], for subject: MenuSubject) -> [ResolvedEntry] {
        entries.compactMap { entry in
            guard entry.isShown(subject) else { return nil }
            let key = EntryKey(group: entry.group, id: entry.id)
            switch entry.content {
            case .item(let isEnabled, let isChecked, let action):
                let run: @MainActor () -> Void = switch action {
                case .perform(let perform): { perform(subject.shapes, subject.editor) }
                case .edit(let edit): {                       // a subject has nothing to edit: run as asked
                    var subject = subject
                    edit(&subject)
                }
                }
                let title = entry.title, editor = subject.editor
                let step: @MainActor () -> Void = { editor.undoHistory.group(title, run) }
                let state: NSControl.StateValue? = isChecked.map { $0(subject) ? .on : .off }
                return ResolvedEntry(title: entry.title, key: key, content: .item(isEnabled: isEnabled(subject), state: state, perform: step))
            case .submenu(let entries):
                let items = resolve(entries, for: subject)
                return items.isEmpty ? nil : ResolvedEntry(title: entry.title, key: key, content: .submenu(items))
            }
        }
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
