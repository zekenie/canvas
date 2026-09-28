import Canvas
import Observation

/// A board on the path to the one shown, as the path shows it: what it's called and its symbol.
public struct BoardCrumb: Equatable, Identifiable, Sendable {
    public let board: BoardID
    public let title: String
    public let systemImage: String?
    public var id: BoardID { board }

    public init(board: BoardID, title: String, systemImage: String? = nil) {
        self.board = board
        self.title = title
        self.systemImage = systemImage
    }
}

/// The path from the root to the board shown, as crumbs, kept for `BoardPath`: made again when
/// another board is shown, or when a board above this one changes (only there are the owners on
/// the path, whose titles name the crumbs), so a commit on the board shown, a drag's every event,
/// costs a look at each board above's revision and redraws nothing.
@MainActor
@Observable
public final class BoardCrumbs {
    /// The boards below the root, root first, the board shown last: empty on the root. The root's
    /// crumb is the host's to name (`BoardPath`'s `rootName`).
    public private(set) var crumbs: [BoardCrumb] = []

    @ObservationIgnored private unowned let editor: CanvasEditor
    /// The revision of each board above the one shown when the crumbs were made, root first.
    @ObservationIgnored private var above: [Int] = []
    #if DEBUG
    /// How many times `BoardPath` has drawn its crumbs (debug builds only), so tests can hold it to
    /// redrawing only when the path changes.
    @ObservationIgnored public var pathRedrawn = 0
    /// How many times the crumbs have been made (debug builds only), so tests can hold a commit on
    /// the board shown to making none.
    @ObservationIgnored public private(set) var remade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        remake()
    }

    /// The most crumbs shown before the middle folds into "…": root, parent and the board shown stay.
    public static let mostShown = 4

    /// `crumbs` with the root's first, as the path lays them out: every one, while there are no more
    /// than `mostShown`; else the root, "…" (`folded`: the ones between, root side first), the parent
    /// and the board shown.
    public func layout(rootName: String) -> (leading: [BoardCrumb], folded: [BoardCrumb], trailing: [BoardCrumb]) {
        let all = [BoardCrumb(board: .root, title: rootName)] + crumbs
        guard all.count > Self.mostShown else { return (all, [], []) }
        return ([all[0]], Array(all[1..<(all.count - 2)]), Array(all.suffix(2)))
    }

    private func remake() {
        #if DEBUG
        remade += 1
        #endif
        let path = editor.boardPath
        let file = editor.file
        above = path.dropLast().map { file.revision(of: $0) }
        let made = path.dropFirst().map { BoardCrumb(board: $0, title: editor.name(of: $0, root: ""), systemImage: editor.symbol(of: $0)) }
        if made != crumbs { crumbs = made }
    }
}

extension BoardCrumbs: EditorService {
    /// The owners on the path are on the boards above this one, so the crumbs change only if one of
    /// those did (a file put in place, or a write to another board).
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        let path = editor.boardPath
        let file = editor.file
        guard path.count - 1 == above.count, zip(path, above).allSatisfy({ file.revision(of: $0) == $1 }) else { return remake() }
    }

    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { remake() }
}

extension CanvasEditor {
    /// The path to the board shown, as crumbs (`BoardsPlugin`); nil without it.
    public var boardCrumbs: BoardCrumbs? { service(BoardCrumbs.self) }
}
