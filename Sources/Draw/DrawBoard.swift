import Canvas
import CoreGraphics
import DrawScript
import Foundation
import FuzzyMatching
import Topology

// Which board a script draws on: worked out from what it names, never said. A title names a shape
// wherever it is in the file (the board shown's first), and so does an id (`#7C1E…`, for a shape with no title: the board
// it is on), `in "X"` puts a shape on the board X holds
// (a subboard's), or in X, on the board X is on, where X holds shapes on its own board (a frame), and
// a script that names nothing on the file draws on the board shown. The shapes a `group` or `ungroup`
// names claim their boards as a placement's targets do. A run draws on one board, as one
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
public struct FileNames {
    /// A shape of a board, with the board.
    typealias Place = (id: ShapeID, board: BoardID)

    /// Each name's shapes, with their boards, the board shown's first.
    var places: [String: [Place]] { tables.places }
    /// Each name once, in the order `places` lists them: what "did you mean" picks from.
    var titles: [String] { tables.titles }
    /// Each board's named shapes, in document order: what `BoardNames` is made from.
    private var byBoard: [BoardID: [(name: String, id: ShapeID)]] { tables.byBoard }
    let editor: CanvasEditor
    let naming: DrawNaming

    /// The names, read from every board the app can show the first time something asks for one (a title, a path, a list of
    /// what is called alike) and shared by every copy: a run that names shapes by their ids alone (a program's, `canvas apply`'s,
    /// a run a board) reads none, where reading them is a pass over the whole file.
    private let read = Read()

    private final class Read {
        var tables: Tables?
    }

    private struct Tables {
        var places: [String: [Place]] = [:]
        var titles: [String] = []
        var byBoard: [BoardID: [(name: String, id: ShapeID)]] = [:]
    }

    public init(_ editor: CanvasEditor, naming: DrawNaming) {
        self.editor = editor
        self.naming = naming
    }

    private var tables: Tables {
        if let tables = read.tables { return tables }
        #if DEBUG
        DrawPlugin.fileNamesRead += 1
        #endif
        var tables = Tables()
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
                if tables.places[name] == nil { tables.titles.append(name) }
                tables.places[name, default: []].append((record.id, board))
                named.append((name, record.id))
            }
            tables.byBoard[board] = named
        }
        read.tables = tables
        return tables
    }

    /// A board, as a message names it: by the shape that holds it (without names, by its kind).
    public static func named(_ board: BoardID, in editor: CanvasEditor, naming: DrawNaming?) -> String {
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
        /// Shapes called alike are where it looks, so it names none of them: the message, and the shapes
        /// it lists (the hint is `pathHint(for:)`).
        case ambiguous(String, [Place])
    }

    /// What to say to a person whose title two shapes share: a title names a shape alone only while it is
    /// the one called that where it is looked for, and the others are named by their paths (the containers
    /// they are in, then their titles), or by an id.
    func pathHint(for places: [Place]) -> String {
        guard let path = places.lazy.compactMap({ self.path(of: $0.id) }).first else {
            return "write the #id of the one you mean, which a query's row gives"
        }
        return "write the path of the one you mean, as \(path.written), or its #id, which a query's row gives"
    }

    /// What to say of a title a text names: a text names a shape by its title alone.
    static let textHint = "a text names a shape by its title alone, so mention one whose title is its own here"

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
                shownAs shown: String? = nil, named said: String? = nil) -> Beyond {
        let said = said ?? quoted(title)
        let window = editor.board
        let onWindow = admitted(places.filter { $0.board == window })
        if onWindow.count > 1 { return .ambiguous(several(onWindow, said, on: shown ?? called(window)), onWindow) }
        if let found = onWindow.first { return .shape(found) }
        let rest = admitted(places.filter { $0.board != window })
        var boards: [BoardID] = []
        for place in rest where !boards.contains(place.board) { boards.append(place.board) }
        guard let board = boards.first else { return .none }
        guard boards.count == 1 else { return .ambiguous("\(said) is on \(boards.count) boards: \(listed(boards.map(called)))", rest) }
        return rest.count == 1 ? .shape(rest[0]) : .ambiguous(several(rest, said, on: called(board)), rest)
    }

    /// Several shapes on one board are called one title: each with its kind and its path, or, in no container, where it is.
    func several(_ places: [Place], _ said: String, on board: String) -> String {
        "\(board) has \(places.count) shapes called \(said): \(listing(places))"
    }

    /// A shape as a list of candidates names it: its kind and its path (the containers it is in, then its title), or, in no
    /// container, where it is (`at 400,300`, kept apart: a list says it of the shapes whose paths read alike).
    func candidate(_ place: Place) -> (said: String, at: String?)? {
        editor.file.record(place.id).map { record in
            let at = "at \(point((editor.frame(inFile: place.id) ?? record.box).map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero))"
            guard let path = path(of: place.id) else { return ("\(indefinite(record.kind)) \(at)", nil) }
            return ("\(indefinite(record.kind)) \(path.written)", at)
        }
    }

    /// The candidates a name could mean, as a message lists them. Two that read alike (the same path: a shape twice in one place)
    /// say where each is too.
    func listing(_ places: [Place]) -> String {
        Self.listing(places.compactMap(candidate))
    }

    static func listing(_ entries: [(said: String, at: String?)]) -> String {
        let counts = Dictionary(grouping: entries, by: \.said).mapValues(\.count)
        return listed(entries.map { entry in
            counts[entry.said, default: 0] > 1 ? [entry.said, entry.at].compactMap { $0 }.joined(separator: " ") : entry.said
        })
    }

    func called(_ board: BoardID) -> String { Self.named(board, in: editor, naming: naming) }

    /// What a title names as a shape that holds others (`in "X"`, `canvas show "X"`).
    public enum Container {
        /// The one shape called that which holds a board (a subboard): its board.
        case board(BoardID)
        /// The one shape called that which holds shapes on its own board (`ShapeContaining`: a
        /// frame): it, and that board.
        case shape(ShapeID, on: BoardID)
        /// No shape is called that.
        case none
        /// Shapes are called that, and none holds others: the first.
        case holdsNone(AnyShapeRecord)
        /// Several that hold others are called that, none or several on the board shown: their boards, and the list a
        /// message gives of them (each with its kind and its path), and what to say to do about it.
        case ambiguous([BoardID], listing: String, hint: String)

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
    public func container(called title: String, boards: Bool = false) -> Container {
        container(among: places[title] ?? [], boards: boards)
    }

    /// The same among the shapes a title or a path names (`all`).
    func container(among all: [Place], boards: Bool = false) -> Container {
        let registry = editor.registry
        let holders = all.filter { place in
            editor.file.record(place.id).map { registry.boardOwningKinds.contains($0.kind) || !boards && registry.isContainer($0) } ?? false
        }
        guard !holders.isEmpty else {
            return all.first.flatMap { editor.file.record($0.id) }.map(Container.holdsNone) ?? .none
        }
        let here = holders.filter { $0.board == editor.board }
        guard let holder = holders.count == 1 ? holders[0] : here.count == 1 ? here[0] : nil else {
            return .ambiguous(holders.map(\.board), listing: listing(holders), hint: pathHint(for: holders))
        }
        if let record = editor.file.record(holder.id), registry.boardOwningKinds.contains(record.kind) { return .board(BoardID(owner: holder.id)) }
        return .shape(holder.id, on: holder.board)
    }

    /// What a title names as a shape of any kind, for what looks at shapes rather than drawing them
    /// (`canvas capture --shape`).
    public enum Found {
        /// The one shape called that, and the board it's on.
        case shape(ShapeID, on: BoardID)
        /// No shape is called that: the titles most like it, best first.
        case none(like: [String])
        /// The board looked on has none called that, and this board has.
        case elsewhere(BoardID)
        /// Several are called that where it looks: what's wrong, and what to do about it.
        case ambiguous(message: String, hint: String)
    }

    /// The shape called `title` (folded, as the plugin that names shapes folds a title): on `board`
    /// alone when one is given, else wherever it is in the file, found as a script's title is
    /// (`beyond`: the board shown's first, else the only other board that has one).
    public func shape(called title: String, on board: BoardID? = nil) -> Found {
        let all = places[title] ?? []
        guard let board else {
            switch beyond(title, among: all) {
            case .shape(let place): return .shape(place.id, on: place.board)
            case .none: return .none(like: Suggestions.closest(to: title, among: titles))
            case .ambiguous(let message, let places): return .ambiguous(message: message, hint: pathHint(for: places))
            }
        }
        let here = all.filter { $0.board == board }
        if here.count > 1 { return .ambiguous(message: several(here, quoted(title), on: called(board)), hint: pathHint(for: here)) }
        if let found = here.first { return .shape(found.id, on: board) }
        if let other = all.first { return .elsewhere(other.board) }
        return .none(like: Suggestions.closest(to: title, among: entries(on: board).map(\.name)))
    }
}

/// What a script's statements say about the board it draws on, as `Drawing.board(for:in:)` reads
/// them: the boards they put the run on, the titles on several boards that the rest may settle, and
/// the edges between boards.
@MainActor
private struct BoardClaims {
    /// A board a statement puts the run on, with the statement and why (and, for an end of an edge
    /// between boards that no stand-in could stand for, its name, which the hint asks the user about).
    typealias Claim = (board: BoardID, statement: Statement, why: String, crossing: String?)
    /// An end of an edge: the name a message calls it (its title in quotes, or an id as written), the board it's on, and the
    /// shape (nil if two on that board are called that).
    typealias End = (said: String, board: BoardID, record: AnyShapeRecord?)
    /// What an edge's end names, folded: a title, or an id.
    private enum EndKey {
        case title(String)
        case id(ShapeID, written: String)
        /// A path, folded, whose first part is not `board` (that is the board the run draws on, whichever it is).
        case path(ShapePath)
    }

    private let editor: CanvasEditor
    private let names: FileNames
    private let naming: DrawNaming
    /// The titles, folded, of the shapes the script draws or restates, and the paths, folded, of those it names by one.
    private let drawn: Set<String>
    private let drawnPaths: Set<ShapePath>
    /// What stands in for what: only a script that joins shapes asks.
    let standIns: StandIns?
    /// The kinds a stand-in can be made as, in plugin order.
    private let makers: [ShapeKind]
    /// What draws edges and the kind it draws: how a board's arrows are found. Nil: nothing does.
    private let edges: (edging: DrawEdging, kind: ShapeKind)?

    /// Each board a statement puts the run on, in statement order: the first decides.
    private(set) var claims: [Claim] = []
    /// The titles and paths (as a message names them) on several boards, none of them the board shown, which the rest may settle.
    private(set) var unsettled: [(said: String, boards: [BoardID], statement: Statement)] = []
    /// The edges between boards, each of which needs one end on the board the run draws on.
    private(set) var crossings: [(statement: Statement, from: (said: String, board: BoardID), to: (said: String, board: BoardID))] = []
    /// The boards the run may draw on that nothing claims hard, in statement order: for an edge
    /// between boards whose two ends stand-ins could stand for, the start's; for an edge to a shape
    /// the script draws, that of the end the file has, where one could.
    private(set) var softStarts: [(board: BoardID, statement: Statement, why: String)] = []
    /// A board's arrows, read the first time an edge between boards looks for itself on it.
    private var connectionsByBoard: [BoardID: [BoardConnection]] = [:]

    init(editor: CanvasEditor, names: FileNames, naming: DrawNaming, drawn: Set<String>, drawnPaths: Set<ShapePath>, joinsShapes: Bool) {
        let registry = editor.registry
        self.editor = editor
        self.names = names
        self.naming = naming
        self.drawn = drawn
        self.drawnPaths = drawnPaths
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
        claim(names.boards(of: title), said: quoted(title), statement)
    }

    /// The run is on the one board its shapes are on; on several, the title or path they share is one the rest of the script may settle.
    private mutating func claim(_ boards: [BoardID], said: String, _ statement: Statement) {
        guard let first = boards.first else { return }
        if first == editor.board || boards.count == 1 {
            claims.append((first, statement, said, nil))
        } else {
            unsettled.append((said, boards, statement))
        }
    }

    /// The boards a path leads to, the board shown's first: where the shapes it names are, else, for a path that leads to a container
    /// and no further, where that container holds shapes (a new shape goes there).
    private func boards(of path: ShapePath) -> [BoardID] {
        let match = names.match(path, board: editor.board)
        var boards = match.shapes.map(\.board)
        if boards.isEmpty { boards = match.holders.compactMap(\.board) }
        var seen: [BoardID] = []
        for board in boards where !seen.contains(board) { seen.append(board) }
        return seen.contains(editor.board) ? [editor.board] + seen.filter { $0 != editor.board } : seen
    }

    /// The run is on the board the shape a name names is on: a title's, if a board has one, or an id's, if the app can show it.
    mutating func claim(_ name: ShapeName, _ statement: Statement) {
        switch name {
        case .title(let written):
            claim(written, statement)
        case .id(let text):
            guard let uuid = UUID(uuidString: text), let place = names.place(ofID: ShapeID(uuid)) else { return }
            claims.append((place.board, statement, said(.id(ShapeID(uuid), written: name.written)), nil))
        case .path(let written):
            // `board` is the board the run draws on, whichever it is: it claims none.
            guard let path = Drawing.folded(written, naming: naming), path.head != .board else { return }
            claim(boards(of: path), said: path.written, statement)
        }
    }

    /// An edge joins its ends, and its ends are on one board, as a statement's names say; or on two,
    /// and one of them can be stood for; or one is a shape the script draws, which is on the board the
    /// run draws on, and the other is the file's.
    mutating func claimEdge(_ fromWritten: ShapeName, _ toWritten: ShapeName, via: Bool, bothHeads: Bool, _ statement: Statement) {
        guard let from = key(fromWritten), let to = key(toWritten) else {
            claim(fromWritten, statement)
            claim(toWritten, statement)
            return
        }
        switch (settled(from), settled(to)) {
        case let (start?, end?) where start.board != end.board:
            claimCrossing((said(from), start.board, start.record), (said(to), end.board, end.record), via: via, bothHeads: bothHeads, statement)
        case let (nil, end?) where isDrawnOnly(from):
            claimEdgeToDrawn((said(to), end.board, end.record), isStart: false, via: via, statement)
        case let (start?, nil) where isDrawnOnly(to):
            claimEdgeToDrawn((said(from), start.board, start.record), isStart: true, via: via, statement)
        default:
            claim(fromWritten, statement)
            claim(toWritten, statement)
        }
    }

    /// What a name is, folded; nil for a title that is blank, or an id that isn't one.
    private func key(_ name: ShapeName) -> EndKey? {
        switch name {
        case .title(let written): naming.fold(written).map(EndKey.title)
        case .id(let text): UUID(uuidString: text).map { EndKey.id(ShapeID($0), written: name.written) }
        case .path(let path):
            Drawing.folded(path, naming: naming).flatMap { $0.head == .board ? nil : EndKey.path($0) }
        }
    }

    /// How a message calls an end: a title in quotes; an id by the title its shape has, else as written.
    private func said(_ key: EndKey) -> String {
        switch key {
        case .title(let title): return quoted(title)
        case .id(let id, let written):
            guard let record = names.place(ofID: id).flatMap({ editor.file.record($0.id) }),
                  let title = naming.name(record, editor.registry) else { return written }
            return quoted(title)
        case .path(let path): return path.written
        }
    }

    /// The board a name names a shape on, with the shape (nil if two on it are called that), when
    /// it's one the run's board can be told from: the shown board's, or the only one.
    private func settled(_ key: EndKey) -> (board: BoardID, record: AnyShapeRecord?)? {
        switch key {
        case .title(let title):
            let boards = names.boards(of: title)
            guard let first = boards.first, first == editor.board || boards.count == 1 else { return nil }
            let there = (names.places[title] ?? []).filter { $0.board == first }
            return (first, there.count == 1 ? editor.file.record(there[0].id) : nil)
        case .id(let id, _):
            guard let place = names.place(ofID: id) else { return nil }
            return (place.board, editor.file.record(id))
        case .path(let path):
            let boards = boards(of: path)
            guard let first = boards.first, first == editor.board || boards.count == 1 else { return nil }
            let there = names.match(path, board: editor.board).shapes.filter { $0.board == first }
            return (first, there.count == 1 ? editor.file.record(there[0].id) : nil)
        }
    }

    /// Whether the script draws a shape with this title and no board has one: it goes on the board
    /// the run draws on, whichever that is. An id names a shape the file has.
    private func isDrawnOnly(_ key: EndKey) -> Bool {
        switch key {
        case .title(let title): return drawn.contains(title) && names.boards(of: title).isEmpty
        case .path(let path): return drawnPaths.contains(path) && names.match(path, board: editor.board).shapes.isEmpty
        case .id: return false
        }
    }

    /// Whether some kind can be made to stand for the shape.
    private func canBeStoodFor(_ record: AnyShapeRecord?) -> Bool {
        guard let standIns, let record else { return false }
        return makers.contains { standIns.admits($0, record) }
    }

    /// The name the hint asks the user about, for an end no stand-in can stand for: none for a stand-in itself (a reference
    /// drawn by its query, named by its id), which nothing stands for whatever the user makes it (one hop).
    private func askable(_ end: End) -> String? {
        guard let standIns, let record = end.record, standIns.kinds.contains(record.kind) else { return end.said }
        return nil
    }

    /// An edge between shapes on two boards. Drawn already through a stand-in (beside one end, for the
    /// other), it's where that is: the run draws there, and the other end claims nothing, since the
    /// edge is found as it's drawn, whether or not the shape stood for can be stood for still. Else
    /// each end claims its board softly where a stand-in can be made for it, and hard where none can;
    /// `via:` puts a stand-in for the end beside the start, so the start is never stood for.
    private mutating func claimCrossing(_ start: End, _ end: End, via: Bool, bothHeads: Bool, _ statement: Statement) {
        if let there = drawnThrough(start, end, bothHeads: bothHeads) {
            claims.append((there.board, statement, there.near, nil))
            return
        }
        let softStart = !via && canBeStoodFor(start.record), softEnd = canBeStoodFor(end.record)
        crossings.append((statement, (start.said, start.board), (end.said, end.board)))
        if softStart && softEnd { softStarts.append((start.board, statement, start.said)) }
        if !softStart { claims.append((start.board, statement, start.said, via ? nil : askable(start))) }
        if !softEnd { claims.append((end.board, statement, end.said, askable(end))) }
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
            softStarts.append((end.board, statement, end.said))
        } else {
            claims.append((end.board, statement, end.said, stoodFor ? askable(end) : nil))
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
            if found.contains(where: { $0.standIn != nil }) { return (near.board, near.said) }
        }
        return nil
    }

    private mutating func connections(on board: BoardID) -> [BoardConnection] {
        if let known = connectionsByBoard[board] { return known }
        #if DEBUG
        DrawPlugin.boardConnectionsRead += 1
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
    static func board(for script: Script, in editor: CanvasEditor, pinned: BoardID? = nil) throws(DrawError) -> (BoardID, FileNames?) {
        // A program's run says which board it draws on when nothing it names does (`DrawOptions.board`).
        let shown = pinned ?? editor.board
        guard let naming = editor.registry.drawNaming else {
            // `in` names a shape by its title: with nothing to name shapes, it can't be honored.
            let contained = script.statements.filter(\.isContained).map { statement in
                DrawError(statement, .noNames, "in names a shape by its title, and nothing here gives shapes names",
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
        let drawnPaths = Set(script.statements.compactMap { statement -> ShapePath? in
            guard case .shape(let shape) = statement.body, let path = shape.name?.path else { return nil }
            return folded(path, naming: naming)
        })

        var book = BoardClaims(editor: editor, names: names, naming: naming, drawn: drawn, drawnPaths: drawnPaths,
                               joinsShapes: script.statements.contains(where: \.joinsShapes))
        var errors: [DrawError] = []
        /// Where a shape goes, or the reference an edge goes through, claims the board it's on: `in`'s, else that of each
        /// shape its placements name (whose titles are then the board `in` names).
        func claimPlace(_ container: ShapeName?, _ clauses: [Clause], _ statement: Statement) {
            if let name = container {
                do throws(DrawError) {
                    let board = try self.container(name, statement, names: names, drawn: drawn, drawnPaths: drawnPaths, naming: naming, editor: editor)
                    book.claim(board, statement, why: "in \(name.title.map { quoted(naming.fold($0) ?? $0) } ?? name.written)")
                } catch {
                    errors.append(error)
                }
                return
            }
            for clause in clauses {
                for target in clause.targets {
                    switch target.box {
                    case .title(let title): book.claim(title, statement)
                    case .id(let text): book.claim(ShapeName.id(text), statement)
                    case .path(let path): book.claim(ShapeName.path(path), statement)
                    case .board, .view, .origin: break
                    }
                }
            }
        }
        for statement in script.statements {
            switch statement.body {
            case .shape(let shape):
                // Its own name is the board `in` names, if it says one.
                if shape.container == nil, let name = shape.name { book.claim(name, statement) }
                claimPlace(shape.container, shape.clauses, statement)
            case .edge(let edge):
                book.claimEdge(edge.from, edge.to, via: edge.via != nil, bothHeads: edge.bothHeads, statement)
                claimPlace(edge.container, edge.clauses, statement)
            case .delete(.shape(let name)):
                book.claim(name, statement)
            case .delete(.edges(let from, let to, let eitherWay, _)):
                book.claimEdge(from, to, via: false, bothHeads: eitherWay, statement)
            case .group(let group), .ungroup(let group):
                // A group is its shapes on one board: each claims the board it is on.
                for name in group.shapes { book.claim(name, statement) }
            }
        }
        let anchor: (board: BoardID, statement: Statement, why: String)? = book.claims.first.map { ($0.board, $0.statement, $0.why) } ?? book.softStarts.first
        // A title on several boards is the one on the board the rest of the script draws on.
        for title in book.unsettled where anchor.map({ !title.boards.contains($0.board) }) ?? true {
            errors.append(DrawError(title.statement, .ambiguousTitle,
                                    "\(title.said) is on \(title.boards.count) boards: \(listed(title.boards.map(named)))",
                                    hint: "say which with in \"…\", naming the shape that holds the board it's on"))
        }
        guard errors.isEmpty else { throw collected(errors) }
        guard let anchor else { return (shown, names) }
        if let other = book.claims.first(where: { $0.board != anchor.board }) {
            // An end of an edge between boards, which a stand-in would join if it could stand for it.
            let wanted = [book.claims.first, other].compactMap { $0?.crossing }
            throw DrawError(other.statement, .severalBoards,
                            "this script draws on \(named(anchor.board)) (\(anchor.why), line \(anchor.statement.line)) and on \(named(other.board)) (\(other.why))",
                            hint: Self.standInHint(for: wanted, book.standIns) ?? "a run draws on one board: split the script into a run for each")
        }
        // Each edge between boards needs one end on the board the run draws on, and a stand-in for the other.
        if let crossing = book.crossings.first(where: { $0.from.board != anchor.board && $0.to.board != anchor.board }) {
            throw DrawError(crossing.statement, .severalBoards,
                            "this script draws on \(named(anchor.board)) (\(anchor.why), line \(anchor.statement.line)) and on \(named(crossing.from.board)) (\(crossing.from.said))",
                            hint: "a run draws on one board, and an edge between boards needs one end on it: split the script into a run for each")
        }
        return (anchor.board, names)
    }

    /// The board `in "X"` puts a shape on: the one X holds (a subboard's), or the one X is on, for
    /// a container there (a frame), which the shape goes in.
    private static func container(_ name: ShapeName, _ statement: Statement, names: FileNames, drawn: Set<String>, drawnPaths: Set<ShapePath>,
                                  naming: DrawNaming, editor: CanvasEditor) throws(DrawError) -> BoardID {
        if case .id(let text) = name {
            guard let uuid = UUID(uuidString: text) else {
                throw DrawError(statement, .notAnID, "\(ShapeName.idMark) takes a shape's id, and \(name.written) isn't one",
                                hint: "an id is 32 hex digits in groups of 8, 4, 4, 4 and 12, as a query's row gives it")
            }
            switch names.container(withID: ShapeID(uuid)) {
            case .board, .shape:
                return names.container(withID: ShapeID(uuid)).board!
            case .none, .ambiguous:
                throw DrawError(statement, .unknownID, "there's no shape with the id \(name.written) to be in",
                                hint: "in names a shape that holds others (a subboard, or a frame): run the query that gave its id again")
            case .holdsNone(let record):
                // An arrow, or a pill for a shape it names, is no shape a script can name at all, as at every site that takes an id.
                if !editor.registry.drawCanName(record) { throw Drawing.unnameable(name.written, record.kind, statement) }
                throw DrawError(statement, .cannotContain, "\(name.written) is \(indefinite(record.kind)), which holds no shapes",
                                hint: "in names a shape that holds others (a subboard, or a frame)")
            }
        }
        let said: String, found: FileNames.Container, wasDrawn: Bool
        switch name {
        case .title(let written):
            guard let title = naming.fold(written) else {
                throw DrawError(statement, .syntax, "a title can't be blank", hint: "in names the shape that holds it")
            }
            (said, found, wasDrawn) = (quoted(title), names.container(called: title), drawn.contains(title))
        case .path(let written):
            guard let path = folded(written, naming: naming) else {
                throw DrawError(statement, .syntax, "a title can't be blank", hint: "in names the shape that holds it")
            }
            // A container this script draws holds nothing yet: a path through one is no path.
            var head = false
            if case .title(let title) = path.head { head = drawn.contains(title) && names.match(path, board: editor.board).shapes.isEmpty }
            (said, found, wasDrawn) = (path.written, names.container(path: path, board: editor.board), head || drawnPaths.contains(path))
        case .id:
            throw DrawError(statement, .internal, "an id was read as a title")
        }
        switch found {
        case .board, .shape:
            return found.board!
        case .none:
            if wasDrawn {
                throw DrawError(statement, .unsupported, "\(said) is drawn by this script, and a shape goes in one already on the board",
                                hint: "draw \(said) first, then run the shapes in it as a script of their own")
            }
            throw DrawError(statement, .unknownTitle, "there's no shape called \(said) to be in",
                            hint: "in names a shape that holds others (a subboard, or a frame), by its title or its path")
        case .holdsNone(let record):
            throw DrawError(statement, .cannotContain, "\(said) is \(indefinite(record.kind)), which holds no shapes",
                            hint: "in names a shape that holds others (a subboard, or a frame); to put it over \(said), write inside \(said) top-left, or on \(said)")
        case .ambiguous(let boards, let listing, let hint):
            throw DrawError(statement, .ambiguousTitle, "\(boards.count) shapes that hold others are called \(said): \(listing)", hint: hint)
        }
    }
}

extension Statement {
    /// Whether it says what holds its shape, or the reference its edge goes through (`in "X"`).
    var isContained: Bool {
        switch body {
        case .shape(let shape): shape.container != nil
        case .edge(let edge): edge.container != nil
        case .delete, .group, .ungroup: false
        }
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
        case .shape, .delete(.shape), .group, .ungroup: false
        }
    }
}
