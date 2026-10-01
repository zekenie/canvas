import Canvas
import CanvasRPC
import DrawScript

// `canvas show`: moves the window to another board of its file, as opening a subboard does (or the
// path's root crumb, for `--root`). Drawing never needs it: a script draws where what it names is.
// Showing a board is no edit, and no undo step; the board left is a step of Go › Back.

struct ShowParams: SchemaDefined {
    static let properties = Properties<ShowParams>(title: "show") {
        Property("shape", \.shape).keywords(["x-value-name": "name"])
            .description("The shape whose board to show (a subboard), by its title.")
        Property("root", \.root).description("Show the board at the top of the file.")
    }
    var shape: String?
    var root = false
}

/// Where the window is now: `root` or the id of the shape that holds the board, as `boards` says,
/// and the boards from the root down to it.
struct ShowResult: Encodable, Sendable {
    struct Shown: Encodable, Sendable {
        var shows: String
        var showsPath: [String]
    }

    var board: Shown
    /// The title of the shape that holds it; none for the root.
    var title: String?
}

@MainActor
func show(_ params: ShowParams, in context: AutomationContext) throws(AutomationError) -> ShowResult {
    let editor = try context.board()
    let canvas = RPC.commandName
    let target: BoardID
    switch (params.shape, params.root) {
    case (nil, true):
        target = .root
    case (let written?, false):
        guard let naming = editor.registry.drawNaming else {
            throw AutomationError("nothing here gives shapes names, so none can be found by its title", reason: ScriptError.Reason.noNames.rawValue,
                                  hint: "\(canvas) show --root shows the top board")
        }
        guard let title = naming.fold(written) else {
            throw AutomationError("a title can't be blank", reason: "invalid_params", invalidParams: true)
        }
        switch FileNames(editor, naming: naming).container(called: title) {
        case .found(let board):
            target = board
        case .none:
            throw AutomationError("there's no shape called \(quoted(title))", reason: ScriptError.Reason.unknownTitle.rawValue,
                                  hint: "\(canvas) query 'subboard' lists the subboards, every board's")
        case .holdsNone(let record):
            throw AutomationError("\(quoted(title)) is \(indefinite(record.kind)), which holds no board", reason: ScriptError.Reason.cannotContain.rawValue,
                                  hint: "name a subboard; \(canvas) query 'subboard' lists them")
        case .ambiguous(let boards):
            throw AutomationError("\(boards.count) shapes that hold boards are called \(quoted(title))", reason: ScriptError.Reason.ambiguousTitle.rawValue,
                                  hint: "titles name shapes, so each needs its own: ask the user to rename one")
        }
    default:
        throw AutomationError("\(canvas) show takes a title, or --root", reason: "invalid_params",
                              hint: "\(canvas) show \"<title>\" or \(canvas) show --root", invalidParams: true)
    }
    // A press moves to another board under the person's pointer: wait for it, as a draw does.
    guard editor.session == nil, !editor.undoHistory.isPressHeld, editor.showBoard(target) else {
        throw AutomationError("someone is pressing on this board", reason: ScriptError.Reason.busy.rawValue, hint: "try again in a moment")
    }
    return ShowResult(board: ShowResult.Shown(shows: editor.board.description, showsPath: editor.boardPath.map(\.description)),
                      title: editor.board.owner.flatMap { editor.file.record($0) }.flatMap { editor.registry.drawNaming?.name($0, editor.registry) })
}
