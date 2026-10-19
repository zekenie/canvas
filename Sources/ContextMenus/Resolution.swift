import AppKit
import Canvas
import Keyboard
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
        } else if hit != nil || editor.isInSelectionBox(pointer.world) {
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
    /// bar item runs; a submenu left with nothing goes), and a command's item dimmed as the command is
    /// (`canPerform`, which reads the selection, as the right-click's can't until its menu is made). An
    /// item chosen ends editing first, as the right-click does. Nil with nothing selected, or nothing left.
    func menuForSelection(omitting commands: Set<CanvasCommand>) -> NSMenu? {
        let ids = editor.selectedShapeIDs
        guard !ids.isEmpty else { return nil }
        let entries = entries(for: ids, at: nil).compactMap { $0.forSelection(omitting: commands, in: editor) }
        return entries.isEmpty ? nil : ContextMenuItems.menu(entries)
    }

    /// What the menu asked for at `point` (world units; none for the selection's menu) holds for these
    /// shapes: the items that apply to every one of them, then the canvas's items, less any whose place
    /// a shape's own item takes (shown or not, as a kind's own item takes an every-shape one's).
    func entries(for ids: [ShapeID], at point: CGPoint?) -> [ResolvedEntry] {
        let records = ids.compactMap { editor.document[$0] }
        let own = ContextMenuItems.resolve(records.map { ($0, ContextMenuItems.shown(candidates(for: $0.kind), for: $0, in: editor)) }, in: editor)
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

extension ContextMenuState: EditorService {}

/// One item of a menu as it will show, for the shapes it's for.
@MainActor
struct ResolvedEntry {
    let title: String
    let key: EntryKey
    let content: Content
    /// The command the item runs or stands for, and the first key that runs it, which the item shows.
    var command: CanvasCommand?
    var shortcut: KeyChord?
    var group: MenuGroupID { key.group }

    enum Content {
        case item(isEnabled: Bool, state: NSControl.StateValue?, perform: @MainActor () -> Void)
        case submenu([ResolvedEntry])
    }

    /// For the selection's menu: nothing for an item that runs a command in `commands`; an item that runs
    /// one dimmed while the editor can't perform it; the rest as they are, an item chosen ending editing
    /// first; a submenu with nothing left, nothing.
    func forSelection(omitting commands: Set<CanvasCommand>, in editor: CanvasEditor) -> ResolvedEntry? {
        if let command, commands.contains(command) { return nil }
        switch content {
        case .submenu(let entries):
            let kept = entries.compactMap { $0.forSelection(omitting: commands, in: editor) }
            return kept.isEmpty ? nil : ResolvedEntry(title: title, key: key, content: .submenu(kept))
        case .item(let isEnabled, let state, let perform):
            let content = Content.item(isEnabled: isEnabled && (command.map(editor.canPerform) ?? true), state: state) {
                editor.endEditing()
                perform()
            }
            return ResolvedEntry(title: title, key: key, content: content, command: command, shortcut: shortcut)
        }
    }
}

@MainActor
enum ContextMenuItems {
    /// What shows for one shape at one level: the first entry with each key (a kind's own before
    /// every shape's), then only those whose `when` holds, and whose command, if it names one, a plugin
    /// claims.
    static func shown(_ entries: [ErasedEntry], for record: AnyShapeRecord, in editor: CanvasEditor) -> [ErasedEntry] {
        var seen = Set<EntryKey>()
        return entries.filter { seen.insert($0.key).inserted }.filter { $0.isShown(record) && $0.isClaimed(in: editor) }
    }

    /// An item's title: its own, else its command's (`registry.title(of:)`), else the id it's keyed by.
    static func title(_ title: String?, command: CanvasCommand?, id: String, in editor: CanvasEditor) -> String {
        title ?? command.flatMap { editor.registry.title(of: $0) ?? $0.rawValue } ?? id
    }

    /// The first key that runs the command, if the keyboard's plugin has one for it.
    private static func shortcut(of command: CanvasCommand?, in editor: CanvasEditor) -> KeyChord? {
        command.flatMap { editor.registry.shortcut(forCommand: $0)?.chord }
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
                    levels.append((record, shown(entries, for: record, in: editor)))
                }
                let items = resolve(levels, in: editor)
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
        }, command: entry.command, shortcut: Self.shortcut(of: entry.command, in: editor))
    }

    /// The canvas's items for a menu's subject, each asked once: those shown, in order, and
    /// submenus with something in them. What an entry made when the menu opens (`MenuItems`) gives
    /// stands in its place, asked once, and an entry whose key an earlier one at its level has is left out.
    static func resolve(_ entries: [MenuEntry<MenuSubject>], for subject: MenuSubject) -> [ResolvedEntry] {
        let editor = subject.editor
        return expanded(entries, for: subject).compactMap { entry in
            guard entry.isShown(subject), entry.command.map(editor.registry.claims) ?? true else { return nil }
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
                return ResolvedEntry(title: title, key: key, content: .item(isEnabled: isEnabled(subject), state: state, perform: step),
                                     command: entry.command, shortcut: Self.shortcut(of: entry.command, in: editor))
            case .submenu(let entries):
                let items = resolve(entries, for: subject)
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
                    if let chord = entry.shortcut {                  // shown, not run: the menu bar and the canvas run the key
                        item.keyEquivalent = chord.menuKey
                        item.keyEquivalentModifierMask = chord.menuModifiers
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

/// What a menu item runs: its target, kept alive as its `representedObject`. The item stays a
/// plain NSMenuItem, since AppKit may copy one through initializers a subclass wouldn't inherit.
final class MenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    /// AppKit sends menu actions on the main thread.
    @MainActor @objc func fire() { run() }
}

extension KeyChord {
    /// The key as a menu item's key equivalent: Delete is Backspace's character to a menu.
    var menuKey: String { key == "\u{7f}" ? "\u{8}" : String(key) }

    /// The modifiers as a menu item holds them.
    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}
