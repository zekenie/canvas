import AppKit
import Canvas
import Selection

/// Per editor (so per window): each kind's items, gathered once for the kits the file has on (the registry
/// is frozen; an off kit's plugins give none), and what a secondary click opens.
@MainActor
final class ContextMenuState {
    private unowned let editor: CanvasEditor
    private var candidates: [ShapeKind: [ErasedEntry]] = [:]
    /// The kits on in the file when `candidates` were gathered: gathered again when those change.
    private var candidatesKits: Set<KitID> = []

    init(editor: CanvasEditor) {
        self.editor = editor
        candidatesKits = editor.kits
    }

    /// The items for the canvas (`CanvasContextMenu`), in plugin order, each with the shapes it's for:
    /// every menu (`.any`), or a scope's; none of a plugin whose kit is off in the file.
    private var canvasItems: [Contributed<CanvasMenuContribution>] { editor.contributions(to: CanvasContextMenu.self) }

    /// A secondary click: the context menu for what it's on, as the select tool sees it. That's the
    /// selection, on a selected shape or on empty space inside a multi-selection's box; otherwise
    /// the selectable shape there, alone, or the group it's in, whole, as a click would select it
    /// (the select tool's hit rule: unselectable shapes are seen through, and what's drawn for a
    /// shape outside it is the shape; `editor.selectionUnit(of:)`); otherwise the canvas, whose
    /// menu is only its own items. With a menu to show, editing ends and what wasn't selected
    /// becomes the selection, as in Keynote and tldraw. Without one (nothing applies), nothing
    /// changes. A Control-click counts only in the select tool: other tools get it as a press with
    /// ⌃ held.
    func menu(for pointer: Pointer) -> NSMenu? {
        if pointer.isControlClick, editor.currentToolID != .select { return nil }
        let hit = editor.selectableShape(at: pointer.world)
        let ids: [ShapeID]
        var selects: [ShapeID]?
        if let hit, case let unit = editor.selectionUnit(of: hit), !editor.areSelected(unit) {
            ids = unit
            selects = unit
        } else if hit != nil || editor.isInSelectionBounds(pointer.world) {
            ids = editor.selectedShapeIDs
        } else {
            ids = []
        }
        var entries = entries(for: ids, at: pointer.world)
        guard !entries.isEmpty else { return nil }
        let revision = editor.revision
        editor.endEditing()
        if let selects { editor.selectedShapeIDs = selects }
        // Ending editing may have saved the editing view: resolve against what it saved.
        if editor.revision != revision { entries = self.entries(for: ids, at: pointer.world) }
        return entries.isEmpty ? nil : ContextMenuItems.menu(entries)
    }

    /// The selection's menu (a menu bar's Shape menu): the items a right-click on the selected shapes
    /// opens, made now, with no point, less the items that run a command in `commands` (the ones a menu
    /// bar item runs, whose rules aren't asked; a submenu left with nothing goes), and a command's item
    /// dimmed while the command can't run now (its moment: the selection is the menu's, which the
    /// right-click's isn't until its menu is made). An item chosen ends editing first, as the right-click
    /// does. Nil with nothing selected, or nothing left.
    func menuForSelection(omitting commands: Set<CanvasCommand>) -> NSMenu? {
        let ids = editor.selectedShapeIDs
        guard !ids.isEmpty else { return nil }
        let entries = entries(for: ids, at: nil, omitting: commands).map { $0.forSelection(in: editor) }
        return entries.isEmpty ? nil : ContextMenuItems.menu(entries)
    }

    /// What the menu asked for at `point` (world units; none for the selection's menu) holds for these
    /// shapes: the items that apply to every one of them, then the canvas's items (a scope's only where
    /// it reaches every shape's kind), less any whose place a shape's own item takes (shown or not, as
    /// a kind's own item takes a scope's), and less the items that run a command in `omitting`.
    func entries(for ids: [ShapeID], at point: CGPoint?, omitting: Set<CanvasCommand> = []) -> [ResolvedEntry] {
        let records = ids.compactMap { editor.document[$0] }
        let subject = MenuSubject(editor: editor, shapes: records.map(\.id), point: point)
        let own = ContextMenuItems.resolve(records.map { ($0, ContextMenuItems.shown(candidates(for: $0.kind), for: $0, in: editor)) },
                                           for: subject, omitting: omitting)
        let kinds = Set(records.map(\.kind))
        let taken = Set(kinds.flatMap { candidates(for: $0).map(\.key) })
        let canvas = ContextMenuItems.resolve(canvasEntries(for: kinds), for: subject, omitting: omitting)
        return own + canvas.filter { !taken.contains($0.key) }
    }

    /// The items for the canvas a menu over shapes of these kinds holds, in plugin and builder order:
    /// every menu's, and a scope's where it reaches every one of the kinds (so none on empty canvas).
    private func canvasEntries(for kinds: Set<ShapeKind>) -> [MenuEntry<MenuSubject>] {
        let registry = editor.registry
        return canvasItems.filter { item in
            item.target == .any || (!kinds.isEmpty && kinds.allSatisfy { registry.reaches(item.target, $0) })
        }.flatMap(\.value.entries)
    }

    /// The kind's own entries, then those of the scopes that reach it, each in plugin and builder order.
    private func candidates(for kind: ShapeKind) -> [ErasedEntry] {
        if candidatesKits != editor.kits {
            candidates = [:]
            candidatesKits = editor.kits
        }
        if let known = candidates[kind] { return known }
        let found = editor.contributions(to: ShapeContextMenus.self, for: kind).flatMap(\.entries)
        candidates[kind] = found
        return found
    }
}

extension ContextMenuState: EditorService {}

/// One item of a menu as it will show, for the shapes it's for.
@MainActor
struct ResolvedEntry {
    let title: String
    let key: EntryKey
    let content: Content
    /// The command the item runs, and the key that runs it, which the item shows (`registry.menuKey(of:)`).
    var command: CanvasCommand?
    var menuKey: MenuKey?
    var group: MenuGroupID { key.group }

    enum Content {
        case item(isEnabled: Bool, state: NSControl.StateValue?, perform: @MainActor () -> Void)
        case submenu([ResolvedEntry])
    }

    /// For the selection's menu: an item that runs a command dimmed while the command can't run now (its
    /// rule, asked as the item was made, and its moment: a shape being edited dims what runs `.whenIdle`);
    /// the rest as they are, an item chosen ending editing first.
    func forSelection(in editor: CanvasEditor) -> ResolvedEntry {
        switch content {
        case .submenu(let entries):
            return ResolvedEntry(title: title, key: key, content: .submenu(entries.map { $0.forSelection(in: editor) }))
        case .item(let isEnabled, let state, let perform):
            let now = command.flatMap { editor.registry.moment(of: $0) }.map { $0.allows(editor) } ?? true
            let content = Content.item(isEnabled: isEnabled && now, state: state) {
                editor.endEditing()
                perform()
            }
            return ResolvedEntry(title: title, key: key, content: content, command: command, menuKey: menuKey)
        }
    }
}

@MainActor
enum ContextMenuItems {
    /// What shows for one shape at one level: the first entry with each key (a kind's own before a
    /// scope's), then only those whose `when` holds, and whose command, if it names one, a plugin
    /// claims.
    static func shown(_ entries: [ErasedEntry], for record: AnyShapeRecord, in editor: CanvasEditor) -> [ErasedEntry] {
        var seen = Set<EntryKey>()
        return entries.filter { seen.insert($0.key).inserted }.filter {
            $0.isShown(record) && ($0.isShownIn?(record.id, editor) ?? true) && $0.isClaimed(in: editor)
        }
    }

    /// An item's title: its own, else its command's (`registry.title(of:)`), else the id it's keyed by.
    static func title(_ title: String?, command: CanvasCommand?, id: String, in editor: CanvasEditor) -> String {
        title ?? command.flatMap { editor.registry.title(of: $0) ?? $0.rawValue } ?? id
    }

    /// An item that runs a command, for what the menu is for: left out while the command can't act on
    /// the menu's shapes and click (its rule, asked with them: the menu ends editing as it opens and is
    /// never asked mid-press, so the command's moment isn't asked), or shown dimmed with `dims`, and
    /// left out unasked where the menu omits the command; when chosen, it runs the command on them, in
    /// one step named as the command names it (as its key does: a delete that took arrows along says so).
    static func commandItem(_ command: CanvasCommand, dims: Bool, title: String, key: EntryKey, omitting: Set<CanvasCommand>,
                            for subject: MenuSubject) -> ResolvedEntry? {
        guard !omitting.contains(command) else { return nil }
        let editor = subject.editor
        let can = editor.canPerform(command, on: subject.shapes, at: subject.point)
        guard can || dims else { return nil }
        return ResolvedEntry(title: title, key: key, content: .item(isEnabled: can, state: nil) {
            _ = editor.perform(command, on: subject.shapes, at: subject.point)
        }, command: command, menuKey: editor.registry.menuKey(of: command))
    }

    /// The entries every shape shows, in the first shape's order. An item is enabled if it is for
    /// any shape, and runs on those; it's checked if every shape checks it, and mixed if some do
    /// (where some kinds' items have no check, theirs count as unchecked). A submenu holds what its
    /// items resolve to, and is left out if that's nothing.
    static func resolve(_ shapes: [(record: AnyShapeRecord, entries: [ErasedEntry])], for subject: MenuSubject,
                        omitting: Set<CanvasCommand> = []) -> [ResolvedEntry] {
        let editor = subject.editor
        guard let first = shapes.first else { return [] }
        return first.entries.compactMap { entry in
            let matches = shapes.compactMap { shape in shape.entries.first { $0.key == entry.key }.map { (shape.record, $0) } }
            guard matches.count == shapes.count else { return nil }
            switch entry.content {
            case .item:
                return item(entry, matches, in: editor)
            case .command(let command, let dims):
                return commandItem(command, dims: dims, title: entry.title(in: editor), key: entry.key, omitting: omitting, for: subject)
            case .submenu:
                var levels: [(record: AnyShapeRecord, entries: [ErasedEntry])] = []
                for (record, match) in matches {
                    guard case .submenu(let entries) = match.content else { return nil }
                    levels.append((record, shown(entries, for: record, in: editor)))
                }
                let items = resolve(levels, for: subject, omitting: omitting)
                return items.isEmpty ? nil : ResolvedEntry(title: entry.title(in: editor), key: entry.key, content: .submenu(items))
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
        let title = entry.title(in: editor)
        return ResolvedEntry(title: title, key: entry.key, content: .item(isEnabled: !enabled.isEmpty, state: state) {
            editor.undoHistory.group(entry.stepName ?? title) { perform(enabled, in: editor) }
        })
    }

    /// The canvas's items for a menu's subject, each asked once: those shown, in order, and
    /// submenus with something in them. What an entry made when the menu opens (`MenuItems`) gives
    /// stands in its place, asked once, and an entry whose key an earlier one at its level has is left out.
    static func resolve(_ entries: [MenuEntry<MenuSubject>], for subject: MenuSubject, omitting: Set<CanvasCommand> = []) -> [ResolvedEntry] {
        let editor = subject.editor
        return expanded(entries, for: subject).compactMap { entry in
            guard entry.isShown(subject), entry.command.map(editor.claims) ?? true else { return nil }
            let key = EntryKey(group: entry.group, id: entry.id)
            let title = Self.title(entry.title, command: entry.command, id: entry.id, in: editor)
            switch entry.content {
            case .item(let isEnabled, let isChecked, let action):
                let run: @MainActor () -> Void = switch action {
                case .perform(let perform): { perform(subject.shapes, subject.editor) }
                case .edit(let edit): {                       // a subject has nothing to edit: run as asked
                    var subject = subject
                    edit(&subject)
                }
                }
                let stepName = entry.stepName ?? title
                let step: @MainActor () -> Void = { editor.undoHistory.group(stepName, run) }
                let state: NSControl.StateValue? = isChecked.map { $0(subject) ? .on : .off }
                return ResolvedEntry(title: title, key: key, content: .item(isEnabled: isEnabled(subject), state: state, perform: step))
            case .command(let command, let dims):
                return commandItem(command, dims: dims, title: title, key: key, omitting: omitting, for: subject)
            case .submenu(let entries):
                let items = resolve(entries, for: subject, omitting: omitting)
                return items.isEmpty ? nil : ResolvedEntry(title: title, key: key, content: .submenu(items))
            case .dynamic:
                return nil
            }
        }
    }

    /// The entries with each `MenuItems` replaced by what it makes (itself expanded), the first of
    /// each key staying.
    private static func expanded(_ entries: [MenuEntry<MenuSubject>], for subject: MenuSubject) -> [MenuEntry<MenuSubject>] {
        var seen = Set<EntryKey>()
        return entries.flatMap { entry -> [MenuEntry<MenuSubject>] in
            guard case .dynamic(let make) = entry.content else { return [entry] }
            return expanded(make(subject), for: subject)
        }.filter { seen.insert(EntryKey(group: $0.group, id: $0.id)).inserted }
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

    /// Groups each where its `order` puts it, counted from where it first appears, with a separator
    /// between them.
    static func menu(_ entries: [ResolvedEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var groups: [MenuGroupID] = []
        for entry in entries where !groups.contains(entry.group) { groups.append(entry.group) }
        let sorted = OrderRule.arranged(groups) { ($0.anchor, $0.order) }
        for (index, group) in sorted.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in entries where entry.group == group {
                switch entry.content {
                case .item(let isEnabled, let state, let perform):
                    let item = NSMenuItem(title: entry.title, run: perform)
                    item.isEnabled = isEnabled
                    if let state { item.state = state }
                    if let key = entry.menuKey {                     // shown, not run: the menu bar and the canvas run the key
                        item.keyEquivalent = key.key
                        item.keyEquivalentModifierMask = key.modifierFlags
                    }
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
