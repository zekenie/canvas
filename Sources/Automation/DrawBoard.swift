import Canvas
import CanvasRPC
import DrawScript

// Which board a script draws on: worked out from what it names, never said. A title names a shape
// wherever it is in the file (the board shown's first), `in "X"` puts a shape on the board X holds
// (a subboard's), or in X, on the board X is on, where X holds shapes on its own board (a frame), and
// a script that names nothing on the file draws on the board shown. A run draws on one board, as one
// transaction and one undo step: a script that names shapes on two is refused. Only boards the app
// can show count (`editor.canShow`).

/// The file's shapes by name, every board the app can show, as the run starts.
@MainActor
struct FileNames {
    /// Each name's shapes, with their boards, the board shown's first.
    private(set) var places: [String: [(id: ShapeID, board: BoardID)]] = [:]
    /// Each board's named shapes, in document order: what `BoardNames` is made from.
    private var byBoard: [BoardID: [(name: String, id: ShapeID)]] = [:]
    private let editor: CanvasEditor

    init(_ editor: CanvasEditor, naming: DrawNaming) {
        self.editor = editor
        let file = editor.file, registry = editor.registry
        // The board shown, then the rest in file order: each owner's board right after the board
        // it's on, so a message lists boards alike every time.
        var ordered: [BoardID] = [], pending: [BoardID] = [.root], seen: Set<BoardID> = []
        while let board = pending.popLast() {
            guard seen.insert(board).inserted else { continue }
            ordered.append(board)
            pending.append(contentsOf: file[board].shapes.reversed().compactMap { file.children[$0.id] != nil ? BoardID(owner: $0.id) : nil })
        }
        let boards = [editor.board] + ordered.filter { $0 != editor.board && editor.canShow($0) }
        for board in boards {
            var named: [(name: String, id: ShapeID)] = []
            for record in file[board].shapes where !record.isOpaque {
                guard let name = naming.name(record, registry) else { continue }
                places[name, default: []].append((record.id, board))
                named.append((name, record.id))
            }
            byBoard[board] = named
        }
    }

    /// A board, as a message names it: by the shape that holds it (without names, by its kind).
    static func named(_ board: BoardID, in editor: CanvasEditor, naming: DrawNaming?) -> String {
        guard let owner = board.owner, let record = editor.file.record(owner) else { return "the root board" }
        return naming?.name(record, editor.registry).map { "\(quoted($0))'s board" } ?? "\(indefinite(record.kind))'s board"
    }

    /// The boards a name is on, each once, the board shown's first.
    func boards(of name: String) -> [BoardID] {
        var seen: [BoardID] = []
        for place in places[name] ?? [] where !seen.contains(place.board) { seen.append(place.board) }
        return seen
    }

    /// A board's named shapes, in document order.
    func entries(on board: BoardID) -> [(name: String, id: ShapeID)] { byBoard[board] ?? [] }

    /// What a title names as a shape that holds others (`in "X"`, `canvas show "X"`).
    enum Container {
        /// The one shape called that which holds a board (a subboard): its board.
        case board(BoardID)
        /// The one shape called that which holds shapes on its own board (`ShapeContaining`: a
        /// frame): it, and that board.
        case shape(ShapeID, on: BoardID)
        /// No shape is called that.
        case none
        /// Shapes are called that, and none holds others: the first.
        case holdsNone(AnyShapeRecord)
        /// Several that hold others are called that, none or several on the board shown.
        case ambiguous([BoardID])

        /// The board what's in it is on.
        var board: BoardID? {
            switch self {
            case .board(let board), .shape(_, on: let board): board
            case .none, .holdsNone, .ambiguous: nil
            }
        }
    }

    /// The shape called `title` that holds others, among those that do (a note called the same is
    /// passed over): one that holds a board, or, unless `boards` alone, a container on its board;
    /// of several, the one on the board shown.
    func container(called title: String, boards: Bool = false) -> Container {
        let all = places[title] ?? [], registry = editor.registry
        let holders = all.filter { place in
            editor.file.record(place.id).map { registry.boardOwningKinds.contains($0.kind) || !boards && registry.isContainer($0) } ?? false
        }
        guard !holders.isEmpty else {
            return all.first.flatMap { editor.file.record($0.id) }.map(Container.holdsNone) ?? .none
        }
        let here = holders.filter { $0.board == editor.board }
        guard let holder = holders.count == 1 ? holders[0] : here.count == 1 ? here[0] : nil else { return .ambiguous(holders.map(\.board)) }
        if let record = editor.file.record(holder.id), registry.boardOwningKinds.contains(record.kind) { return .board(BoardID(owner: holder.id)) }
        return .shape(holder.id, on: holder.board)
    }
}

extension Drawing {
    /// The board a script draws on, or why it can't draw on one: the board each statement's titles
    /// put it on agree, else the board shown. With it, the file's names, when the script names
    /// shapes.
    static func board(for script: Script, in editor: CanvasEditor) throws(AutomationError) -> (BoardID, FileNames?) {
        let shown = editor.board
        guard let naming = editor.registry.drawNaming else {
            // `in` names a shape by its title: with nothing to name shapes, it can't be honored.
            let contained = script.statements.filter(\.isContained).map { statement in
                AutomationError(statement, .noNames, "in names a shape by its title, and nothing here gives shapes names",
                                hint: "leave in out: without a plugin that names shapes, a script draws on the board the window shows")
            }
            if !contained.isEmpty { throw collected(contained) }
            return (shown, nil)
        }
        guard script.mentionsTitles || script.statements.contains(where: \.isContained) else { return (shown, nil) }
        let names = FileNames(editor, naming: naming)
        func named(_ board: BoardID) -> String { FileNames.named(board, in: editor, naming: naming) }
        let drawn = Set(script.statements.compactMap { statement -> String? in
            guard case .shape(let shape) = statement.body else { return nil }
            return shape.title.flatMap(naming.fold)
        })

        // Each board a statement puts the run on, with the statement and why; and the titles on
        // several boards, none of them the board shown, which the rest may settle.
        var claims: [(board: BoardID, statement: Statement, why: String)] = []
        var unsettled: [(title: String, boards: [BoardID], statement: Statement)] = []
        var errors: [AutomationError] = []
        func claim(_ written: String, _ statement: Statement) {
            guard let title = naming.fold(written) else { return }
            let boards = names.boards(of: title)
            guard let first = boards.first else { return }
            if first == shown || boards.count == 1 {
                claims.append((first, statement, quoted(title)))
            } else {
                unsettled.append((title, boards, statement))
            }
        }
        for statement in script.statements {
            switch statement.body {
            case .shape(let shape):
                if let written = shape.container {
                    do throws(AutomationError) {
                        let board = try container(written, statement, names: names, drawn: drawn, naming: naming, editor: editor)
                        claims.append((board, statement, "in \(quoted(naming.fold(written) ?? written))"))
                    } catch {
                        errors.append(error)
                    }
                    // Its titles are that board's.
                    continue
                }
                if let title = shape.title { claim(title, statement) }
                for clause in shape.clauses {
                    for target in clause.targets { if case .title(let title) = target.box { claim(title, statement) } }
                }
            case .edge(let edge):
                claim(edge.from, statement)
                claim(edge.to, statement)
            case .delete(.shape(let title)):
                claim(title, statement)
            case .delete(.edges(let from, let to, _)):
                claim(from, statement)
                claim(to, statement)
            }
        }
        let board = claims.first?.board
        // A title on several boards is the one on the board the rest of the script draws on.
        for title in unsettled where board.map({ !title.boards.contains($0) }) ?? true {
            errors.append(AutomationError(title.statement, .ambiguousTitle,
                                          "\(quoted(title.title)) is on \(title.boards.count) boards: \(listed(title.boards.map(named)))",
                                          hint: "say which with in \"…\", naming the shape that holds the board it's on"))
        }
        guard errors.isEmpty else { throw collected(errors) }
        guard let first = claims.first else { return (shown, names) }
        if let other = claims.first(where: { $0.board != first.board }) {
            throw AutomationError(other.statement, .severalBoards,
                                  "this script draws on \(named(first.board)) (\(first.why), line \(first.statement.line)) and on \(named(other.board)) (\(other.why))",
                                  hint: "a run draws on one board: split the script into a run for each")
        }
        return (first.board, names)
    }

    /// The board `in "X"` puts a shape on: the one X holds (a subboard's), or the one X is on, for
    /// a container there (a frame), which the shape goes in.
    private static func container(_ written: String, _ statement: Statement, names: FileNames, drawn: Set<String>, naming: DrawNaming,
                                  editor: CanvasEditor) throws(AutomationError) -> BoardID {
        guard let title = naming.fold(written) else {
            throw AutomationError(statement, .syntax, "a title can't be blank", hint: "in names the shape that holds it")
        }
        let found = names.container(called: title)
        switch found {
        case .board, .shape:
            return found.board!
        case .none:
            if drawn.contains(title) {
                throw AutomationError(statement, .unsupported, "\(quoted(title)) is drawn by this script, and a shape goes in one already on the board",
                                      hint: "draw \(quoted(title)) first, then run the shapes in it as a script of their own")
            }
            throw AutomationError(statement, .unknownTitle, "there's no shape called \(quoted(title)) to be in",
                                  hint: "in names a shape that holds others (a subboard, or a frame), by its title")
        case .holdsNone(let record):
            throw AutomationError(statement, .cannotContain, "\(quoted(title)) is \(indefinite(record.kind)), which holds no shapes",
                                  hint: "in names a shape that holds others (a subboard, or a frame); to put it over \(quoted(title)), write inside \(quoted(title)) top-left, or on \(quoted(title))")
        case .ambiguous(let boards):
            throw AutomationError(statement, .ambiguousTitle,
                                  "\(boards.count) shapes that hold others are called \(quoted(title)), on \(listed(boards.reduce(into: [BoardID]()) { if !$0.contains($1) { $0.append($1) } }.map { FileNames.named($0, in: editor, naming: naming) }))",
                                  hint: "titles name shapes, so the one it's in needs its own: ask the user to rename one")
        }
    }
}

extension Statement {
    /// Whether it says what holds its shape (`in "X"`).
    var isContained: Bool {
        if case .shape(let shape) = body { shape.container != nil } else { false }
    }
}
