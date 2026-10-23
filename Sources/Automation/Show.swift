import Canvas
import CanvasRPC
import Draw
import DrawScript

// `canvas show`: moves the window to another board of its file, as opening a subboard does (or the
// path's root crumb, for `--root`). Drawing never needs it: a script draws where what it names is.
// Showing a board is no edit, and no undo step; the board left is a step of Go › Back.

struct ShowParams: SchemaDefined {
    static let properties = Properties<ShowParams>(title: "show") {
        Property("shape", \.shape).keywords(["x-value-name": "name"])
            .description("The shape whose board to show (a subboard): its title, or a name as a script writes it: a path, \"Plans\" > \"Sprint\", or an id, #<id>.")
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
        // A name as a script writes it (a quoted title, an id, a path), else a bare title.
        let names = FileNames(editor, naming: naming)
        var name = ShapeName.title(written), said = ""
        if ShapeName.isScriptSpelling(written) {
            do throws(ScriptError) {
                name = try ShapeName(parsing: written)
            } catch {
                throw AutomationError(error.message, reason: error.reason == .syntax ? "invalid_params" : error.reason.rawValue, hint: error.hint,
                                      invalidParams: error.reason == .syntax)
            }
        }
        switch name {
        case .title(let text):
            guard let title = naming.fold(text) else {
                throw AutomationError("a title can't be blank", reason: "invalid_params", invalidParams: true)
            }
            said = quoted(title)
        case .id:
            said = name.written
        case .path(let path):
            said = names.folded(path)?.written ?? path.written
        }
        // Only what holds a board: a frame holds what's in it on the board it's on, so it holds none.
        switch names.container(named: name, boards: true, board: editor.board) {
        case .board(let board)?, .shape(_, on: let board)?:          // (never a frame, with boards alone)
            target = board
        case nil, .none?:
            throw AutomationError("there's no shape \(name.id == nil ? "called" : "with the id") \(name.id == nil ? said : name.written)", reason: name.id == nil ? ScriptError.Reason.unknownTitle.rawValue : ScriptError.Reason.unknownID.rawValue,
                                  hint: "\(canvas) query 'subboard' lists the subboards, every board's")
        case .holdsNone(let record)?:
            throw AutomationError("\(said) is \(indefinite(record.kind)), which holds no board", reason: ScriptError.Reason.cannotContain.rawValue,
                                  hint: "name a subboard; \(canvas) query 'subboard' lists them")
        case .ambiguous(let boards, let listing, let hint)?:
            throw AutomationError("\(boards.count) shapes that hold boards are called \(said): \(listing)", reason: ScriptError.Reason.ambiguousTitle.rawValue,
                                  hint: hint)
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
