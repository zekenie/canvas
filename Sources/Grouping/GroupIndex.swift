import Canvas
import Selection

/// Per editor: the groups on the board shown (`BoardGroups`), kept as commits change the paths
/// shapes hold, and given to Selection as what's selected as one (`SelectionGroupSource`). A commit
/// that writes no shape's path (a drag, typing) costs a comparison a shape it names.
@MainActor
final class GroupIndex {
    private unowned let editor: CanvasEditor
    /// The paths the board's shapes hold, as stored, for those that hold one.
    private var stored: [ShapeID: [String]] = [:]
    private(set) var groups = BoardGroups([])
    /// The boards shown lately, for going back to them without looking through their shapes again.
    private var kept = BoardStash<[ShapeID: [String]]>()
    #if DEBUG
    /// How many times a whole board has been looked through for the paths its shapes hold (debug builds).
    private(set) var boardsScanned = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        read(editor.document)
    }

    /// Every path the board's shapes hold, and the groups they make.
    private func read(_ document: CanvasDocument) {
        #if DEBUG
        boardsScanned += 1
        #endif
        stored = [:]
        for record in document.shapes {
            if let path = record[GroupsProperty.self], !path.isEmpty { stored[record.id] = path }
        }
        regroup()
    }

    /// The groups the stored paths make, back to front.
    private func regroup() {
        let document = editor.document
        let order = stored.keys.compactMap { id in document.index(of: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }
        groups = BoardGroups(order.map { (id: $0.0, path: stored[$0.0] ?? []) })
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
        for id in changes.removed where stored.removeValue(forKey: id) != nil { changed = true }
        for id in changes.edited {
            let path = editor.document[id]?[GroupsProperty.self] ?? []
            guard path != stored[id] ?? [] else { continue }
            stored[id] = path.isEmpty ? nil : path
            changed = true
        }
        guard changed || (changes.reordered && !stored.isEmpty) else { return }
        let before = groups.paths
        regroup()
        if changed || groups.paths != before { editor.selectionGroupsDidChange() }
    }

    /// The board left's paths are kept for when it's shown again.
    func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new else { return }
        kept.keep(stored, for: old, in: editor)
    }

    /// Another board is shown: its groups, as they were kept if the board hasn't changed since it was
    /// left, else looked for.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        guard let paths = kept.take(for: change.to, in: editor) else { return read(editor.document) }
        stored = paths
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
