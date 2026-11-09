import Canvas
import Draw
import Titles

// The file's enums and tables by name: what a column's type that names an enum, a key's `→` that names a table and an API's
// path that names a table's are found by. Shared by the kit's parts.

/// The file's enums and tables by name, for a column's type that names an enum and a key's `→` that names a table: the lists kept
/// until the file changes (`editor.revision`), so a keystroke on a board of thousands of shapes reads a list, and the enums by name
/// followed commit by commit too (what a table at rest reads its types by, a frame at a time). Nearest first: one in the shape's own
/// container (a table's database, `billing` beside `shop` on one board), then out from it, then on its board, then any other.
@MainActor
final class KitNames {
    unowned let editor: CanvasEditor
    private var revision = -1
    private var keptEnums: [(id: ShapeID, name: String, board: BoardID)] = []
    private var keptTables: [(id: ShapeID, name: String, board: BoardID)] = []
    /// Every named enum of the file by its name, and each one's name and board: nil until asked, then followed by each commit (only the
    /// shapes and boards it names), so a table drawn at rest finds the enum its words name without reading the file.
    private var enumIndex: (byName: [String: Set<ShapeID>], entries: [ShapeID: (name: String, board: BoardID)])?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    private func read() {
        guard revision != editor.revision else { return }
        revision = editor.revision
        let file = editor.file, registry = editor.registry, shown = editor.board
        let boards = [shown] + file.everyBoard.filter { $0 != shown }.sorted { ($0.owner?.description ?? "") < ($1.owner?.description ?? "") }
        keptEnums = []
        keptTables = []
        for board in boards {
            for record in file[board].shapes where record.kind == DatabaseEnum.kind || record.kind == DatabaseTable.kind {
                guard let name = registry.title(of: record) else { continue }
                if record.kind == DatabaseEnum.kind { keptEnums.append((record.id, name, board)) } else { keptTables.append((record.id, name, board)) }
            }
        }
    }

    /// Every enum of the file that has a name, the board shown's first, then the root's, then the others'.
    var enums: [(id: ShapeID, name: String, board: BoardID)] {
        read()
        return keptEnums
    }

    /// Every table of the file that has a name, the board shown's first, then the root's, then the others': what an API's path
    /// segment offers.
    var tables: [(id: ShapeID, name: String, board: BoardID)] {
        read()
        return keptTables
    }

    /// The enum called `name` nearest `shape` (`nearest`): what a column's type binds to as it's typed, and at rest where the words
    /// were written before the enum was made (or it was made again since).
    func enumNamed(_ name: String, near shape: ShapeID) -> ShapeID? {
        guard !name.isEmpty, let named = index().byName[name], !named.isEmpty else { return nil }
        return nearest(Array(named), to: shape)
    }

    /// An enum's name now, if it's still one of the file's.
    func name(of id: ShapeID) -> String? {
        index().entries[id]?.name
    }

    /// Of `candidates`, the one nearest `shape`: the one in the innermost of `shape`'s containers that holds any of them (its table's
    /// database first), else one on its board, else one on the board shown, each tie by id, so it's the same wherever it's asked.
    func nearest(_ candidates: [ShapeID], to shape: ShapeID) -> ShapeID? {
        guard candidates.count > 1 else { return candidates.first }
        let file = editor.file, kinds = editor.registry.containingKinds
        let board = file.board(containing: shape)
        let chain = board.map { file[$0].containers(of: shape, containingKinds: kinds) } ?? []
        func rank(_ id: ShapeID) -> Int {
            guard let board, file.board(containing: id) == board else { return file.board(containing: id) == editor.board ? chain.count + 1 : chain.count + 2 }
            let theirs = file[board].containers(of: id, containingKinds: kinds)
            return chain.firstIndex(where: theirs.contains) ?? chain.count
        }
        return candidates.map { (id: $0, rank: rank($0)) }.min { ($0.rank, $0.id.description) < ($1.rank, $1.id.description) }?.id
    }

    /// The table called `name` nearest `shape` (`nearest`) on its board, else on another board a pill can stand for as it is
    /// (`FarVerdicts`: a public one, not a private one, which typing never makes public), as an enum's name is found; what a key's `→`
    /// names. The first in the board order of two alike on other boards, a reachable one over one that is not. Nil where none can be
    /// reached, so a key to it stays plain words and the row commits.
    func tableNamed(_ name: String, besides shape: ShapeID) -> ShapeID? {
        read()
        let board = editor.file.board(containing: shape)
        // As `canvas draw` finds a table by its title: with its whitespace folded.
        let folded = TitleProperty.folded(name) ?? name
        let named = keptTables.filter { $0.name == folded }
        let here = named.filter { $0.board == board }.map(\.id)
        if let nearest = nearest(here, to: shape) { return nearest }
        guard !named.isEmpty else { return nil }
        let verdicts = FarVerdicts(editor)
        return named.first { found in
            switch verdicts.verdict(of: found.id) {
            case .here, .reads: true
            case .fulfils, .cannot: false
            }
        }?.id
    }

    // MARK: The enums by name

    private func index() -> (byName: [String: Set<ShapeID>], entries: [ShapeID: (name: String, board: BoardID)]) {
        if let enumIndex { return enumIndex }
        var built: (byName: [String: Set<ShapeID>], entries: [ShapeID: (name: String, board: BoardID)]) = ([:], [:])
        for board in editor.file.everyBoard { Self.learn(board: board, from: editor, into: &built) }
        enumIndex = built
        return built
    }

    private static func learn(board: BoardID, from editor: CanvasEditor, into index: inout (byName: [String: Set<ShapeID>], entries: [ShapeID: (name: String, board: BoardID)])) {
        for record in editor.file[board].shapes where record.kind == DatabaseEnum.kind { learn(record, on: board, from: editor, into: &index) }
    }

    private static func learn(_ record: AnyShapeRecord, on board: BoardID, from editor: CanvasEditor,
                              into index: inout (byName: [String: Set<ShapeID>], entries: [ShapeID: (name: String, board: BoardID)])) {
        forget(record.id, in: &index)
        guard record.kind == DatabaseEnum.kind, let name = editor.registry.title(of: record) else { return }
        index.entries[record.id] = (name, board)
        index.byName[name, default: []].insert(record.id)
    }

    private static func forget(_ id: ShapeID, in index: inout (byName: [String: Set<ShapeID>], entries: [ShapeID: (name: String, board: BoardID)])) {
        guard let old = index.entries.removeValue(forKey: id) else { return }
        index.byName[old.name]?.remove(id)
        if index.byName[old.name]?.isEmpty == true { index.byName[old.name] = nil }
    }
}

extension KitNames: EditorService {
    /// A commit: the shapes it added, changed (a rename) or removed, on its board and elsewhere in the file, read again; only once
    /// the index has been asked for.
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard var index = enumIndex else { return }
        if changes.replacedDocument {
            enumIndex = nil
            return
        }
        guard !changes.onlyMoves else { return }
        let file = editor.file
        for id in changes.added.union(changes.removed).union(changes.elsewhere).union(changes.changed.subtracting(changes.moved)) {
            if let record = editor.shape(inFile: id), let board = file.board(containing: id) {
                Self.learn(record, on: board, from: editor, into: &index)
            } else {
                Self.forget(id, in: &index)
            }
        }
        enumIndex = index
    }

    /// Another file read in: nothing kept is its.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if change.isFileReplaced { enumIndex = nil }
    }
}
