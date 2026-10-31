import Canvas
import CoreGraphics
import Geometry
import Observation

/// Walking shapes: a client lists rows (a shape on a board, each with some stops to go to), and the walk
/// holds a place among them and goes from stop to stop, wrapping, one Back step for the whole walk. Find's
/// stepping through its hits was the first (`FindState` is its client); a walk through a file's issues is
/// the next. The walk knows no kind and no reason a shape is listed: what a stop is, and what is drawn
/// at it, are the client's.

/// A row of a walk: one shape on one board, and how many stops it has (Find's hits in a shape; an
/// issue's one, or none once it is ignored or holds).
public struct WalkRow: Hashable {
    /// What names the row across a change of rows (Find's: the shape).
    public let key: AnyHashable
    public let shape: ShapeID
    public let board: BoardID
    /// How many stops the row has. A row with none stays in the walk and is reached (`pick`, `move`),
    /// but a step passes it.
    public let stops: Int
    /// The row's place in the walk's order, which rows keep when others come and go and which only
    /// grows down the rows: where a row that is gone is found again (the first row at or after its rank).
    public let rank: Int

    public init(key: AnyHashable, shape: ShapeID, board: BoardID, stops: Int, rank: Int) {
        self.key = key
        self.shape = shape
        self.board = board
        self.stops = stops
        self.rank = rank
    }
}

/// A stop among the rows: a row's place, and which of its stops (from 0).
public struct WalkPosition: Hashable, Sendable {
    public let row: Int
    public let ordinal: Int

    public init(row: Int, ordinal: Int) {
        self.row = row
        self.ordinal = ordinal
    }
}

/// What the walk keeps of its place across a change of rows (`ShapeWalk.kept`, `rowsDidChange(keeping:)`).
public struct WalkKept: Hashable {
    public let key: AnyHashable
    public let ordinal: Int
    public let rank: Int

    public init(key: AnyHashable, ordinal: Int, rank: Int) {
        self.key = key
        self.ordinal = ordinal
        self.rank = rank
    }
}

/// A run of rows on one board, in order (`ShapeWalk.boardRuns()`).
public struct WalkBoardRun: Hashable, Sendable {
    public let board: BoardID
    public let rows: Range<Int>

    public init(board: BoardID, rows: Range<Int>) {
        self.board = board
        self.rows = rows
    }
}

/// What a walk does on arriving at a stop.
public enum WalkArrival: Sendable {
    /// Shows the stop's board and brings the stop into view if it isn't: the selection stays (showing
    /// another board empties it, as every switch does). Find's.
    case shows
    /// Goes to the stop's shape (`editor.goTo`): selects it if it can be, shows its board, and brings it
    /// into view unless it is readably in view, then brings the stop's focus rect into view.
    case selects
}

/// Where `begin(at:)` goes first.
public enum WalkEntry: Sendable {
    /// The first (or last) row with a stop.
    case first, last
    /// The first stop after the selection going on (or before it, going back), wrapping: after the last
    /// of the shapes selected, in the walk's order, where several are (a placement selects them all).
    case afterSelection(forward: Bool)
    /// The first stop of the shape's first row with one.
    case shape(ShapeID)
}

/// The rows of a walk, as the client keeps them: the walk asks for the one it needs (a pull, so a client
/// with a hundred thousand rows copies none). The client says when they change (`rowsDidChange`).
@MainActor
public protocol ShapeWalkSource: AnyObject {
    /// How many rows there are, in the walk's order.
    var walkRowCount: Int { get }
    /// The row at a place, below `walkRowCount`.
    func walkRow(at index: Int) -> WalkRow
    /// The place of the row a key names, if there is one.
    func walkPlace(ofKey key: AnyHashable) -> Int?
    /// How many stops the rows before this place have: a stop's number is that and its ordinal, plus one.
    func walkStops(before index: Int) -> Int
    /// Where the stop is, in world units, on the board the walk has just shown, if it is a part of its
    /// shape: what has to be in view (Find's hit). Nil: the shape's bounds.
    func walkFocus(of position: WalkPosition) -> CGRect?
    /// The place of the row to go on from, for a walk that begins after the selection (`WalkEntry`):
    /// going forward the last row holding a shape that is selected, going back the first. For a
    /// selection that holds no row, a client that can order shapes answers with the last row before it in
    /// the walk's order going forward, the first row after it going back (the default knows no order, and
    /// answers nil). Nil: no place, which begins at the first row going forward and the last going back.
    func walkPlace(of selection: [ShapeID], forward: Bool) -> Int?
    /// The walk went to a stop (and shows it now): what a client redraws or forgets.
    func walkDidMove()
}

extension ShapeWalkSource {
    public func walkFocus(of position: WalkPosition) -> CGRect? { nil }
    public func walkDidMove() {}

    public func walkPlace(of selection: [ShapeID], forward: Bool) -> Int? {
        guard !selection.isEmpty else { return nil }
        let selected = Set(selection)
        let count = walkRowCount
        for i in 0..<count {
            let index = forward ? count - 1 - i : i
            if selected.contains(walkRow(at: index).shape) { return index }
        }
        return nil
    }
}

/// A walk through shapes (`init(editor:arrival:)`): the place (`current`, `number` among all the stops),
/// and the moves that change it, each counted (`stepCount`), each guarded the same way: nothing mid-gesture,
/// and nothing while shapes wait to be placed (a move would drop them, or put them down in the wrong
/// place). `step(forward:)` goes stop by stop, wrapping, passing rows with none; `move(by:)`,
/// `moveBoard(by:)` and `pick(row:)` reach any row.
///
/// Every move is made from the start taken as the walk began (`begin`, `editor.navigationStart`), so the
/// whole walk, however many boards it goes through, is one step back, however long and whatever the person
/// did between. Moves never transact. The walk lasts until `end()` or `finish()`; `current` stays through
/// `end()`, which the client clears (`land(at: nil)`) when it wants to.
@MainActor
@Observable
public final class ShapeWalk {
    @ObservationIgnored private unowned let editor: CanvasEditor
    @ObservationIgnored public weak var source: ShapeWalkSource?
    @ObservationIgnored private let arrival: WalkArrival
    /// Where the walk began: Back after it returns there.
    @ObservationIgnored private var start: NavigationStart?

    /// The stop the walk is at.
    public private(set) var current: WalkPosition?
    /// +1 each move to a stop (step, move, pick, begin): what VoiceOver announces by, so a stop the
    /// client lands on itself (`land(at:)`) is not talked over.
    public private(set) var stepCount = 0
    /// Whether a walk has begun and not ended.
    public private(set) var isRunning = false

    public init(editor: CanvasEditor, arrival: WalkArrival) {
        self.editor = editor
        self.arrival = arrival
    }

    // MARK: Reading

    /// The current stop's number among all, from 1.
    public var number: Int? {
        guard let source, let current, current.row >= 0, current.row < source.walkRowCount else { return nil }
        return source.walkStops(before: current.row) + current.ordinal + 1
    }

    /// The current row, if there is one.
    public var currentRow: WalkRow? {
        guard let source, let current, current.row >= 0, current.row < source.walkRowCount else { return nil }
        return source.walkRow(at: current.row)
    }

    /// The runs of rows on one board, in order: a board's rows follow one another in the walk's order.
    /// Worked out in one pass over the rows each time.
    public func boardRuns() -> [WalkBoardRun] {
        guard let source else { return [] }
        var runs: [WalkBoardRun] = []
        var from = 0
        var board: BoardID?
        for i in 0..<source.walkRowCount {
            let here = source.walkRow(at: i).board
            if here != board {
                if let board { runs.append(WalkBoardRun(board: board, rows: from..<i)) }
                board = here
                from = i
            }
        }
        if let board { runs.append(WalkBoardRun(board: board, rows: from..<source.walkRowCount)) }
        return runs
    }

    /// What `rowsDidChange(keeping:)` needs from the rows as they are before they change: the current
    /// stop's row, which of its stops, and its rank. Nil with no current stop.
    public var kept: WalkKept? {
        guard let row = currentRow, let current else { return nil }
        return WalkKept(key: row.key, ordinal: current.ordinal, rank: row.rank)
    }

    // MARK: Beginning and ending

    /// Begins a walk: takes where the editor is, for its one step back, and, with an entry, goes to it
    /// (false: there was nowhere to go, or a move is refused). A walk begun again starts anew.
    @discardableResult
    public func begin(at entry: WalkEntry? = nil) -> Bool {
        isRunning = true
        start = editor.navigationStart
        guard let entry, canMove, let position = entryPosition(entry) else { return false }
        move(to: position)
        return true
    }

    /// Ends the walk: the next moves are made from where they find the editor. The selection, the camera
    /// and `current` stay.
    public func end() {
        isRunning = false
        start = nil
    }

    /// Ends the walk and selects the current stop's shape (`goTo`) as part of the one step back to where
    /// it began, even when the stepping showed another board. `closing` runs between the two, after the
    /// walk has ended and before the editor moves, for a client that is closing with it. False, and nothing
    /// ended or run, when there is no current stop or a move is refused.
    @discardableResult
    public func finish(closing: () -> Void = {}) -> Bool {
        guard canMove, let shape = currentRow?.shape else { return false }
        let began = start
        end()
        closing()
        let select = { [editor] in editor.goTo([shape]) }
        if let began { editor.navigate(from: began, select) } else { select() }
        return true
    }

    // MARK: Moving

    /// The next stop, or the one before, wrapping; with none current, the first or the last. Passes rows
    /// with no stops. Nothing when no row has one.
    public func step(forward: Bool) {
        guard canMove, let position = following(current, forward: forward) else { return }
        move(to: position)
    }

    /// The row `rows` on (negative: before), wrapping, its first stop current, whether it has stops or
    /// not. With nothing current, the first row going down, the last going up.
    public func move(by rows: Int) {
        guard canMove, let source else { return }
        let count = source.walkRowCount
        guard count > 0 else { return }
        let target: Int
        if let current, current.row >= 0, current.row < count {
            target = ((current.row + rows) % count + count) % count
        } else {
            target = rows >= 0 ? 0 : count - 1
        }
        move(to: WalkPosition(row: target, ordinal: 0))
    }

    /// The first row of the board `boards` on (negative: before), wrapping, as `move(by:)` goes to a row.
    /// With nothing current, the first board going down, the last going up.
    public func moveBoard(by boards: Int) {
        guard canMove else { return }
        let runs = boardRuns()
        guard !runs.isEmpty else { return }
        let target: Int
        if let current, let here = runs.firstIndex(where: { $0.rows.contains(current.row) }) {
            target = ((here + boards) % runs.count + runs.count) % runs.count
        } else {
            target = boards >= 0 ? 0 : runs.count - 1
        }
        move(to: WalkPosition(row: runs[target].rows.lowerBound, ordinal: 0))
    }

    /// A row picked (a click on it): its first stop current, whether it has stops or not.
    public func pick(row: Int) {
        guard canMove, let source, row >= 0, row < source.walkRowCount else { return }
        move(to: WalkPosition(row: row, ordinal: 0))
    }

    /// Makes a stop current, not a step (`stepCount` stays): where a client's own landing puts the walk
    /// (Find's typing lands on a hit, and the stepping goes on from it). Nil: no stop is current. With
    /// `arriving`, goes there too, as a step does (no guard: a landing is the client's own, as Find's typing
    /// always was, and drops nothing).
    public func land(at position: WalkPosition?, arriving: Bool = false) {
        current = position
        guard arriving, let position else { return }
        arrive(at: position)
        source?.walkDidMove()
    }

    /// Makes the stop after (before) the current one current as a landing, not a move: `stepCount` stays and nothing is
    /// refused while shapes wait to be placed, so a client whose own landing is a step from a stop (Find's ⇧⌘G, opening on
    /// the hit before the first) lands it whole. It goes there only if that keeps the board shown, since showing another
    /// would let the waiting shapes go; a stop on another board is current and not shown, as Find's typing leaves one. Nothing
    /// mid-gesture, or with no stop to go to.
    public func land(stepping forward: Bool) {
        guard editor.session == nil, let source, let position = following(current, forward: forward) else { return }
        land(at: position, arriving: source.walkRow(at: position.row).board == editor.board)
    }

    // MARK: Upkeep

    /// The client's rows changed. With `keeping` (taken, as `kept`, before they did), the place is found
    /// again: the same row, the same stop kept within what it has now, else the first row at or after
    /// its rank, its first stop; none, with no rows. Without it, only a place past the rows goes. The
    /// editor doesn't move.
    public func rowsDidChange(keeping kept: WalkKept? = nil) {
        guard let source else {
            current = nil
            return
        }
        let count = source.walkRowCount
        guard let kept else {
            if let current, current.row < 0 || current.row >= count { self.current = nil }
            return
        }
        guard count > 0 else {
            current = nil
            return
        }
        if let place = source.walkPlace(ofKey: kept.key) {
            current = WalkPosition(row: place, ordinal: max(0, min(kept.ordinal, source.walkRow(at: place).stops - 1)))
            return
        }
        // The first row with a rank at or after: ranks only grow down the rows.
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if source.walkRow(at: middle).rank >= kept.rank { high = middle } else { low = middle + 1 }
        }
        current = WalkPosition(row: low == count ? 0 : low, ordinal: 0)
    }

    // MARK: Inside

    /// Whether a move may run: nothing under way, and no shapes waiting to be placed.
    private var canMove: Bool { editor.session == nil && !editor.isPlacingLater }

    private func move(to position: WalkPosition) {
        current = position
        stepCount &+= 1
        arrive(at: position)
        source?.walkDidMove()
    }

    /// The stop after (before) one, wrapping, passing rows with none; the first (last) with no stop to go
    /// on from.
    private func following(_ from: WalkPosition?, forward: Bool) -> WalkPosition? {
        guard let source else { return nil }
        let count = source.walkRowCount
        guard count > 0 else { return nil }
        var base = forward ? -1 : count
        if let from, from.row >= 0, from.row < count {
            let stops = source.walkRow(at: from.row).stops
            if forward, from.ordinal + 1 < stops { return WalkPosition(row: from.row, ordinal: from.ordinal + 1) }
            if !forward, from.ordinal > 0, stops > 0 { return WalkPosition(row: from.row, ordinal: min(from.ordinal, stops) - 1) }
            base = from.row
        }
        for i in 1...count {
            let index = forward ? (base + i) % count : ((base - i) % count + count) % count
            let stops = source.walkRow(at: index).stops
            if stops > 0 { return WalkPosition(row: index, ordinal: forward ? 0 : stops - 1) }
        }
        return nil
    }

    private func entryPosition(_ entry: WalkEntry) -> WalkPosition? {
        guard let source else { return nil }
        switch entry {
        case .first:
            return following(nil, forward: true)
        case .last:
            return following(nil, forward: false)
        case .afterSelection(let forward):
            guard let place = source.walkPlace(of: editor.selectedShapeIDs, forward: forward),
                  place >= 0, place < source.walkRowCount else { return following(nil, forward: forward) }
            let stops = source.walkRow(at: place).stops
            return following(WalkPosition(row: place, ordinal: forward ? max(stops - 1, 0) : 0), forward: forward)
        case .shape(let id):
            for i in 0..<source.walkRowCount {
                let row = source.walkRow(at: i)
                if row.shape == id, row.stops > 0 { return WalkPosition(row: i, ordinal: 0) }
            }
            return nil
        }
    }

    /// Goes to the stop as the walk arrives: inside the walk's one step back. A stop whose shape can't be
    /// selected, or whose board can't be shown, is still the current stop.
    private func arrive(at position: WalkPosition) {
        guard let source, position.row >= 0, position.row < source.walkRowCount else { return }
        let row = source.walkRow(at: position.row)
        let move = { [self] in
            switch arrival {
            case .shows:
                if row.board != editor.board {
                    guard editor.showBoard(row.board) else { return }
                }
                let view = editor.unobscuredViewport
                guard !view.isEmpty, let bounds = source.walkFocus(of: position) ?? editor.shapeContext.bounds(of: [row.shape]) else { return }
                if !editor.cameraTarget.toWorld(view).contains(bounds) { editor.reveal([row.shape]) }
            case .selects:
                editor.goTo([row.shape])
                // The focus rect is in the stop's board's units: only asked once the walk is on that board.
                guard editor.board == row.board else { return }
                if let focus = source.walkFocus(of: position) { editor.revealIfOffscreen(rect: focus) }
            }
        }
        if let start { editor.navigate(from: start, move) } else { move() }
    }
}
