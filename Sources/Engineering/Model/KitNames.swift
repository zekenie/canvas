import Canvas
import Draw
import Titles

// The file's enums and tables by name: what a column's type that names an enum, a key's `→` that names a table and an API's
// path that names a table's are found by. Shared by the kit's parts.

/// The file's enums and tables by name, for a column's type that names an enum and a key's `→` that names a table: kept until the
/// file changes (`editor.revision`), so a keystroke on a board of thousands of shapes reads a list. Nearest first: one on the shape's
/// board, then any other.
@MainActor
final class KitNames {
    unowned let editor: CanvasEditor
    private var revision = -1
    private var keptEnums: [(id: ShapeID, name: String, board: BoardID)] = []
    private var keptTables: [(id: ShapeID, name: String, board: BoardID)] = []

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

    /// The enum called `name` nearest `shape`: on its board, else anywhere in the file.
    func enumNamed(_ name: String, near shape: ShapeID) -> ShapeID? {
        let board = editor.file.board(containing: shape)
        let named = enums.filter { $0.name == name }
        return (named.first { $0.board == board } ?? named.first)?.id
    }

    /// An enum's name now, if it's still one of the file's.
    func name(of id: ShapeID) -> String? {
        enums.first { $0.id == id }?.name
    }

    /// The table called `name` nearest `shape`: on its board, else on another board a pill can stand for as it is (`FarVerdicts`: a
    /// public one, not a private one, which typing never makes public), as an enum's name is found; what a key's `→` names. The first
    /// in the board order of two alike on other boards, a reachable one over one that is not. Nil where none can be reached, so a
    /// key to it stays plain words and the row commits.
    func tableNamed(_ name: String, besides shape: ShapeID) -> ShapeID? {
        read()
        let board = editor.file.board(containing: shape)
        // As `canvas draw` finds a table by its title: with its whitespace folded.
        let folded = TitleProperty.folded(name) ?? name
        let named = keptTables.filter { $0.name == folded }
        if let here = named.first(where: { $0.board == board }) { return here.id }
        guard !named.isEmpty else { return nil }
        let verdicts = FarVerdicts(editor)
        return named.first { found in
            switch verdicts.verdict(of: found.id) {
            case .here, .reads: true
            case .fulfils, .cannot: false
            }
        }?.id
    }
}

extension KitNames: EditorService {}

