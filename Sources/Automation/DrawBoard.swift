import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Topology

// Which board a script draws on: worked out from what it names, never said. A title names a shape
// wherever it is in the file (the board shown's first), `in "X"` puts a shape on the board X holds
// (a subboard's), or in X, on the board X is on, where X holds shapes on its own board (a frame), and
// a script that names nothing on the file draws on the board shown. A run draws on one board, as one
// transaction and one undo step: a script that names shapes on two is refused. Only boards the app
// can show count (`editor.canShow`).
//
// One thing an edge may do that nothing else does: join shapes on two boards, through a stand-in for
// the end on the other (`DrawStandIns.swift`), which only some shapes can have. An end that one can be
// made for claims its board softly: it doesn't make the run draw there, since the run may draw on the
// other end's board and put the stand-in there. The run draws on the first hard claim's board; with
// none, on the board of the first such edge's start; and each such edge then needs one end on it.
//
// Two kinds of edge are read otherwise. An edge that's drawn through a stand-in already (an arrow
// between the end on one board and a stand-in for exactly the other: `Drawing.edgeMatches`) claims
// the board the arrow is on, hard, and its other end claims nothing, so a run again, or a
// `delete edge`, goes where the stand-in is and finds the edge, rather than making a second stand-in
// for it on the other board. And an edge to a shape the script draws, which is on the board the run
// draws on, whichever it is, claims nothing for that end; the end the file has claims its board as an
// end of an edge between boards does, softly where a stand-in can be made for it (so with nothing
// else to decide, the run goes there and the edge is drawn straight), else hard.

/// The file's shapes by name, every board the app can show, as the run starts.
@MainActor
struct FileNames {
    /// A shape of a board, with the board.
    typealias Place = (id: ShapeID, board: BoardID)

    /// Each name's shapes, with their boards, the board shown's first.
    private(set) var places: [String: [Place]] = [:]
    /// Each name once, in the order `places` lists them: what "did you mean" picks from.
    private(set) var titles: [String] = []
    /// Each board's named shapes, in document order: what `BoardNames` is made from.
    private var byBoard: [BoardID: [(name: String, id: ShapeID)]] = [:]
    private let editor: CanvasEditor
    private let naming: DrawNaming

    init(_ editor: CanvasEditor, naming: DrawNaming) {
        #if DEBUG
        AutomationPlugin.fileNamesRead += 1
        #endif
        self.editor = editor
        self.naming = naming
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
                if places[name] == nil { titles.append(name) }
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

    /// What `beyond` found.
    enum Beyond {
        /// Nothing is called that.
        case none
        /// The shape that is.
        case shape(Place)
        /// Shapes called alike are where it looks, so it names none of them: the message, whose hint
        /// is `oneEach`.
        case ambiguous(String)
    }

    /// What to say to a person whose titles two shapes share.
    static let oneEach = "titles name shapes here, so each needs its own: ask the user to rename one"

    /// What a title names beyond the board a run draws on: one of `places`, which are the title's on
    /// the boards its caller doesn't leave out. The shape on the board the window shows, if that has
    /// one, else the one on the only other board that has one, as a title names a shape anywhere in
    /// the file; two or more on that board, or on several boards where the window's has none, are
    /// ambiguous. `admitted` says which of a board's places the caller takes (an edge's end takes
    /// every shape, a text's name those it may mention). It's asked of the window's board's places
    /// first, and of the rest only if that has none, so what a caller learns of the places it
    /// refuses, it learns in that order. `shown` is what a message calls the window's board where
    /// that isn't how it names the others.
    func beyond(_ title: String, among places: [Place], admitting admitted: ([Place]) -> [Place] = { $0 },
                shownAs shown: String? = nil) -> Beyond {
        let window = editor.board
        let onWindow = admitted(places.filter { $0.board == window })
        if onWindow.count > 1 { return .ambiguous(several(onWindow, title, on: shown ?? called(window))) }
        if let found = onWindow.first { return .shape(found) }
        let rest = admitted(places.filter { $0.board != window })
        var boards: [BoardID] = []
        for place in rest where !boards.contains(place.board) { boards.append(place.board) }
        guard let board = boards.first else { return .none }
        guard boards.count == 1 else { return .ambiguous("\(quoted(title)) is on \(boards.count) boards: \(listed(boards.map(called)))") }
        return rest.count == 1 ? .shape(rest[0]) : .ambiguous(several(rest, title, on: called(board)))
    }

    /// Several shapes on one board are called one title: each with its kind and where it is.
    private func several(_ places: [Place], _ title: String, on board: String) -> String {
        let each = places.compactMap { place in
            editor.file.record(place.id).map { record in
                "\(indefinite(record.kind)) at \(point(record.box.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero))"
            }
        }
        return "\(board) has \(places.count) shapes called \(quoted(title)): \(listed(each))"
    }

    private func called(_ board: BoardID) -> String { Self.named(board, in: editor, naming: naming) }

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

/// What a script's statements say about the board it draws on, as `Drawing.board(for:in:)` reads
/// them: the boards they put the run on, the titles on several boards that the rest may settle, and
/// the edges between boards.
@MainActor
private struct BoardClaims {
    /// A board a statement puts the run on, with the statement and why (and, for an end of an edge
    /// between boards that no stand-in could stand for, its title, which the hint asks the user about).
    typealias Claim = (board: BoardID, statement: Statement, why: String, crossing: String?)
    /// An end of an edge: its title, the board it's on, and the shape (nil if two on that board are
    /// called that).
    typealias End = (title: String, board: BoardID, record: AnyShapeRecord?)

    private let editor: CanvasEditor
    private let names: FileNames
    private let naming: DrawNaming
    /// The titles, folded, of the shapes the script draws or restates.
    private let drawn: Set<String>
    /// What stands in for what: only a script that joins shapes asks.
    let standIns: StandIns?
    /// The kinds a stand-in can be made as, in plugin order.
    private let makers: [ShapeKind]
    /// What draws edges and the kind it draws: how a board's arrows are found. Nil: nothing does.
    private let edges: (edging: DrawEdging, kind: ShapeKind)?

    /// Each board a statement puts the run on, in statement order: the first decides.
    private(set) var claims: [Claim] = []
    /// The titles on several boards, none of them the board shown, which the rest may settle.
    private(set) var unsettled: [(title: String, boards: [BoardID], statement: Statement)] = []
    /// The edges between boards, each of which needs one end on the board the run draws on.
    private(set) var crossings: [(statement: Statement, from: (title: String, board: BoardID), to: (title: String, board: BoardID))] = []
    /// The boards the run may draw on that nothing claims hard, in statement order: for an edge
    /// between boards whose two ends stand-ins could stand for, the start's; for an edge to a shape
    /// the script draws, that of the end the file has, where one could.
    private(set) var softStarts: [(board: BoardID, statement: Statement, why: String)] = []
    /// A board's arrows, read the first time an edge between boards looks for itself on it.
    private var connectionsByBoard: [BoardID: [BoardConnection]] = [:]

    init(editor: CanvasEditor, names: FileNames, naming: DrawNaming, drawn: Set<String>, joinsShapes: Bool) {
        let registry = editor.registry
        self.editor = editor
        self.names = names
        self.naming = naming
        self.drawn = drawn
        standIns = joinsShapes ? registry.standIns : nil
        makers = standIns?.makers ?? []
        edges = joinsShapes ? registry.drawEdging.flatMap { edging in edging.kind(registry).map { (edging, $0) } } : nil
    }

    /// The run is on this board, for a reason a message gives (`in "X"`).
    mutating func claim(_ board: BoardID, _ statement: Statement, why: String) {
        claims.append((board, statement, why, nil))
    }

    /// The run is on the board the shape a title names is on, if a board has one.
    mutating func claim(_ written: String, _ statement: Statement) {
        guard let title = naming.fold(written) else { return }
        let boards = names.boards(of: title)
        guard let first = boards.first else { return }
        if first == editor.board || boards.count == 1 {
            claims.append((first, statement, quoted(title), nil))
        } else {
            unsettled.append((title, boards, statement))
        }
    }

    /// An edge joins its ends, and its ends are on one board, as a statement's titles say; or on two,
    /// and one of them can be stood for; or one is a shape the script draws, which is on the board the
    /// run draws on, and the other is the file's.
    mutating func claimEdge(_ fromWritten: String, _ toWritten: String, via: Bool, bothHeads: Bool, _ statement: Statement) {
        guard let from = naming.fold(fromWritten), let to = naming.fold(toWritten) else {
            claim(fromWritten, statement)
            claim(toWritten, statement)
            return
        }
        switch (settled(from), settled(to)) {
        case let (start?, end?) where start.board != end.board:
            claimCrossing((from, start.board, start.record), (to, end.board, end.record), via: via, bothHeads: bothHeads, statement)
        case let (nil, end?) where isDrawnOnly(from):
            claimEdgeToDrawn((to, end.board, end.record), isStart: false, via: via, statement)
        case let (start?, nil) where isDrawnOnly(to):
            claimEdgeToDrawn((from, start.board, start.record), isStart: true, via: via, statement)
        default:
            claim(fromWritten, statement)
            claim(toWritten, statement)
        }
    }

    /// The board a title names a shape on, with the shape (nil if two on it are called that), when
    /// it's one the run's board can be told from: the shown board's, or the only one.
    private func settled(_ title: String) -> (board: BoardID, record: AnyShapeRecord?)? {
        let boards = names.boards(of: title)
        guard let first = boards.first, first == editor.board || boards.count == 1 else { return nil }
        let there = (names.places[title] ?? []).filter { $0.board == first }
        return (first, there.count == 1 ? editor.file.record(there[0].id) : nil)
    }

    /// Whether the script draws a shape with this title and no board has one: it goes on the board
    /// the run draws on, whichever that is.
    private func isDrawnOnly(_ title: String) -> Bool {
        drawn.contains(title) && names.boards(of: title).isEmpty
    }

    /// Whether some kind can be made to stand for the shape.
    private func canBeStoodFor(_ record: AnyShapeRecord?) -> Bool {
        guard let standIns, let record else { return false }
        return makers.contains { standIns.admits($0, record) }
    }

    /// An edge between shapes on two boards. Drawn already through a stand-in (beside one end, for the
    /// other), it's where that is: the run draws there, and the other end claims nothing, since the
    /// edge is found as it's drawn, whether or not the shape stood for can be stood for still. Else
    /// each end claims its board softly where a stand-in can be made for it, and hard where none can;
    /// `via:` puts a stand-in for the end beside the start, so the start is never stood for.
    private mutating func claimCrossing(_ start: End, _ end: End, via: Bool, bothHeads: Bool, _ statement: Statement) {
        if let there = drawnThrough(start, end, bothHeads: bothHeads) {
            claims.append((there.board, statement, quoted(there.near), nil))
            return
        }
        let softStart = !via && canBeStoodFor(start.record), softEnd = canBeStoodFor(end.record)
        crossings.append((statement, (start.title, start.board), (end.title, end.board)))
        if softStart && softEnd { softStarts.append((start.board, statement, quoted(start.title))) }
        if !softStart { claims.append((start.board, statement, quoted(start.title), via ? nil : start.title)) }
        if !softEnd { claims.append((end.board, statement, quoted(end.title), end.title)) }
    }

    /// An edge between a shape the script draws and one the file has. The script's goes on the board
    /// the run draws on, so it claims nothing; where the run isn't on the other's board, a stand-in goes
    /// beside it if one can be made for the other, so that end claims its board softly (with nothing
    /// else to say the run is there, and the edge is straight), else hard, as an end of an edge
    /// between boards does.
    private mutating func claimEdgeToDrawn(_ end: End, isStart: Bool, via: Bool, _ statement: Statement) {
        // `via:` puts a stand-in for the end beside the start: the start is never stood for.
        let stoodFor = !(isStart && via)
        if stoodFor && canBeStoodFor(end.record) {
            softStarts.append((end.board, statement, quoted(end.title)))
        } else {
            claims.append((end.board, statement, quoted(end.title), stoodFor ? end.title : nil))
        }
    }

    /// The board an edge between `start` and `end` is drawn on through a stand-in beside one of them,
    /// the start's first, with the title of the end it's beside: where an arrow joins that end to a
    /// stand-in whose record stands for exactly the other (`Drawing.edgeMatches`, which a run draws on
    /// one board by too). Each board's arrows are read once, and only for an edge between boards.
    private mutating func drawnThrough(_ start: End, _ end: End, bothHeads: Bool) -> (board: BoardID, near: String)? {
        guard let standIns, let from = start.record?.id, let to = end.record?.id else { return nil }
        for near in [start, end] {
            let found = Drawing.edgeMatches(from: from, to: to, bothHeads: bothHeads, among: connections(on: near.board),
                                            in: editor.contents(of: near.board), standIns: standIns)
            if found.contains(where: { $0.standIn != nil }) { return (near.board, near.title) }
        }
        return nil
    }

    private mutating func connections(on board: BoardID) -> [BoardConnection] {
        if let known = connectionsByBoard[board] { return known }
        #if DEBUG
        AutomationPlugin.boardConnectionsRead += 1
        #endif
        let read = edges.map { Drawing.connections(in: editor.contents(of: board), kind: $0.kind, edging: $0.edging, registry: editor.registry) } ?? []
        connectionsByBoard[board] = read
        return read
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

        var book = BoardClaims(editor: editor, names: names, naming: naming, drawn: drawn, joinsShapes: script.statements.contains(where: \.joinsShapes))
        var errors: [AutomationError] = []
        for statement in script.statements {
            switch statement.body {
            case .shape(let shape):
                if let written = shape.container {
                    do throws(AutomationError) {
                        let board = try container(written, statement, names: names, drawn: drawn, naming: naming, editor: editor)
                        book.claim(board, statement, why: "in \(quoted(naming.fold(written) ?? written))")
                    } catch {
                        errors.append(error)
                    }
                    // Its titles are that board's.
                    continue
                }
                if let title = shape.title { book.claim(title, statement) }
                for clause in shape.clauses {
                    for target in clause.targets { if case .title(let title) = target.box { book.claim(title, statement) } }
                }
            case .edge(let edge):
                book.claimEdge(edge.from, edge.to, via: edge.via != nil, bothHeads: edge.bothHeads, statement)
            case .delete(.shape(let title)):
                book.claim(title, statement)
            case .delete(.edges(let from, let to, let eitherWay)):
                book.claimEdge(from, to, via: false, bothHeads: eitherWay, statement)
            }
        }
        let anchor: (board: BoardID, statement: Statement, why: String)? = book.claims.first.map { ($0.board, $0.statement, $0.why) } ?? book.softStarts.first
        // A title on several boards is the one on the board the rest of the script draws on.
        for title in book.unsettled where anchor.map({ !title.boards.contains($0.board) }) ?? true {
            errors.append(AutomationError(title.statement, .ambiguousTitle,
                                          "\(quoted(title.title)) is on \(title.boards.count) boards: \(listed(title.boards.map(named)))",
                                          hint: "say which with in \"…\", naming the shape that holds the board it's on"))
        }
        guard errors.isEmpty else { throw collected(errors) }
        guard let anchor else { return (shown, names) }
        if let other = book.claims.first(where: { $0.board != anchor.board }) {
            // An end of an edge between boards, which a stand-in would join if it could stand for it.
            let wanted = [book.claims.first, other].compactMap { $0?.crossing }
            throw AutomationError(other.statement, .severalBoards,
                                  "this script draws on \(named(anchor.board)) (\(anchor.why), line \(anchor.statement.line)) and on \(named(other.board)) (\(other.why))",
                                  hint: Self.standInHint(for: wanted, book.standIns) ?? "a run draws on one board: split the script into a run for each")
        }
        // Each edge between boards needs one end on the board the run draws on, and a stand-in for the other.
        if let crossing = book.crossings.first(where: { $0.from.board != anchor.board && $0.to.board != anchor.board }) {
            throw AutomationError(crossing.statement, .severalBoards,
                                  "this script draws on \(named(anchor.board)) (\(anchor.why), line \(anchor.statement.line)) and on \(named(crossing.from.board)) (\(quoted(crossing.from.title)))",
                                  hint: "a run draws on one board, and an edge between boards needs one end on it: split the script into a run for each")
        }
        return (anchor.board, names)
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

    /// Whether it's a delete (`delete "X"` or `delete edge`).
    var isDelete: Bool {
        if case .delete = body { true } else { false }
    }

    /// Whether it joins shapes (an edge, or a `delete edge`), which is when what stands in for what
    /// matters to the board's claims (to `Drawing`, a delete's too).
    var joinsShapes: Bool {
        switch body {
        case .edge, .delete(.edges): true
        case .shape, .delete(.shape): false
        }
    }
}
