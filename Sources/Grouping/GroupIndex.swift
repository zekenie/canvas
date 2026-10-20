import Canvas
import Selection

/// Per editor: the groups on the board shown (`BoardGroups`), kept as commits change the paths
/// shapes hold, and given to Selection as what's selected as one (`SelectionGroupSource`). A commit
/// that writes no shape's path (a drag, typing) costs a comparison a shape it names, of the path the
/// shape holds with the one it held before (`ChangeSet.before`).
@MainActor
final class GroupIndex {
    private unowned let editor: CanvasEditor
    /// The board's shapes that hold a path: what its groups are made from, read from their records.
    private var holders: Set<ShapeID> = []
    private(set) var groups = BoardGroups([])
    /// The boards shown lately, for going back to them without looking through their shapes again.
    private var kept = BoardStash<Set<ShapeID>>()
    #if DEBUG
    /// How many times a whole board has been looked through for the paths its shapes hold (debug builds).
    private(set) var boardsScanned = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        read(editor.document)
    }

    /// The board's shapes that hold a path, and the groups they make.
    private func read(_ document: CanvasDocument) {
        #if DEBUG
        boardsScanned += 1
        #endif
        holders = Set(document.shapes.lazy.filter { !($0[GroupsProperty.self] ?? []).isEmpty }.map(\.id))
        regroup()
    }

    /// The groups the holders' paths make, back to front: each read at its place in the stack, found once.
    private func regroup() {
        let document = editor.document
        let order = holders.compactMap { id in document.index(of: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }
        groups = BoardGroups(order.map { (id: $0.0, path: document.shapes[$0.1][GroupsProperty.self] ?? []) })
    }
}

extension GroupIndex: EditorService {
    /// Follows the paths the commit wrote (a shape that only moved holds the path it did), and the
    /// stack, which orders a group's shapes; then tells Selection, if the groups changed.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        if changes.replacedDocument {
            read(editor.document)
            return editor.selectionGroupsDidChange()
        }
        // A drag's commits only move shapes, which hold the paths they did.
        if changes.added.isEmpty, changes.removed.isEmpty, changes.changed.count == changes.moved.count, !changes.reordered { return }
        var changed = false
        for id in changes.removed where holders.remove(id) != nil { changed = true }
        for id in changes.edited {
            let path = editor.document[id]?[GroupsProperty.self] ?? []
            // One that came onto the board is new to its groups, whatever it held where it was.
            let held = changes.added.contains(id) ? [] : changes.before(id)?[GroupsProperty.self] ?? []
            guard path != held else { continue }
            if path.isEmpty { holders.remove(id) } else { holders.insert(id) }
            changed = true
        }
        guard changed || (changes.reordered && !holders.isEmpty) else { return }
        let before = groups.paths
        regroup()
        if changed || groups.paths != before { editor.selectionGroupsDidChange() }
    }

    /// The board left's holders are kept for when it's shown again.
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new else { return }
        kept.keep(holders, for: old, in: editor)
    }

    /// Another board is shown: its groups, from the holders kept if the board hasn't changed since it was
    /// left, else looked for.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard let taken = kept.take(for: change.to, in: editor) else { return read(editor.document) }
        holders = taken
        regroup()
    }
}

extension GroupIndex: SelectionGroupSource {
    func groups(of id: ShapeID) -> [AnyHashable] { groups.path(of: id).map(AnyHashable.init) }

    func shapes(in group: AnyHashable) -> [ShapeID] { (group.base as? String).flatMap { groups.shapes[$0] } ?? [] }
}

#if DEBUG
extension CanvasEditor {
    /// How many times Grouping has looked through a whole board for the groups its shapes are in
    /// (debug builds only), so tests can hold going back to a board to taking back what was kept.
    public var boardsScannedForGroups: Int { service(GroupIndex.self)?.boardsScanned ?? 0 }
}
#endif
