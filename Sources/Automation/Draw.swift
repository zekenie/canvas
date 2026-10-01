import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Geometry

// `canvas draw`: a script in DrawScript's language, applied to the board in one transaction, or
// not at all. It's read (`Script(parsing:)`), resolved against the board as the run starts (kinds,
// titles through DrawNames, attributes through each kind's schema, placements' targets), placed
// (DrawScript's `LayoutProblem`, against the shapes that stay put), and then applied in one
// `editor.transact`: deletes, then shapes, then edges (through DrawEdges), and the result read
// back from the transaction's document. A dry run runs the same transaction and throws its result
// out of it, so nothing commits, and on the same board the two say the same (but for what a
// person's typing, which only a real run ends, adds to the shape they're typing in).

// MARK: Params and result

struct DrawParams: SchemaDefined {
    static let properties = Properties<DrawParams>(title: "draw") {
        Property("script", \.script).required().keywords(["x-stdin": true, "x-value-name": "script"])
            .description("What to draw: one statement a line (a shape, an edge, a delete or a style), in quotes for the shell.")
        Property("dryRun", \.dryRun).description("Work everything out and say what would happen, changing nothing.")
        Property("reveal", \.reveal).description("Then ease the view to what was drawn.")
    }
    var script = ""
    var dryRun = false
    var reveal = false
}

/// What a draw did, a row per thing it made, changed, left as it was or deleted, in script order;
/// what it drew anyway but should say (issues, pushes, near misses); and, on a dry run, that
/// nothing changed.
struct DrawResult: Encodable, Sendable {
    var changes: [DrawChange]
    var warnings: [DrawWarning]
    var dryRun: Bool?
    /// The board it drew on (the board shown, unless what the script names is on another).
    var on: DrawBoard?
}

/// A board a run drew on: `root`, or the id of the shape that holds it, as `boards`' `shows`; that
/// shape's title; and whether the window shows it.
struct DrawBoard: Encodable, Sendable {
    var board: String
    var title: String?
    var shown: Bool

    @MainActor
    init(_ board: BoardID, in editor: CanvasEditor) {
        self.board = board.description
        title = board.owner.flatMap { editor.file.record($0) }.flatMap { record in editor.registry.drawNaming?.name(record, editor.registry) }
        shown = board == editor.board
    }
}

/// One shape or edge a statement is about, as the board has it now.
struct DrawChange: Sendable {
    enum Did: String, Encodable, Sendable {
        case created, moved, updated, renamed, unchanged, deleted, connected, reconnected
    }

    var line: Int
    var did: Did
    var kind: String
    /// What it's called now (a deleted shape: what it was called).
    var title: String?
    /// What it was called, if the statement renamed it.
    var was: String?
    /// Where it is: [[x, y], [width, height]], world units.
    var at: CGRect?
    /// Whether any of it is in the window's view (nil when the board isn't in a window).
    var inView: Bool?
    /// What it was pushed past to keep clear of it, by title (or `<kind> at x,y`).
    var pushedPast: [String]?
    /// An edge's ends, by title.
    var from: String?
    var to: String?
    /// An edge's attributes as it has them now (those DrawEdges declares), by key.
    var attributes: [String: JSON] = [:]
}

extension DrawChange: Encodable {
    /// A row's own members, which an edge's attributes (written beside them) can't be named
    /// (`DrawEdges.check`).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case line, did, kind, title, was, at, inView, pushedPast, from, to
    }

    private struct AttributeKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(line, forKey: .line)
        try container.encode(did, forKey: .did)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(was, forKey: .was)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(inView, forKey: .inView)
        try container.encodeIfPresent(pushedPast, forKey: .pushedPast)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
        guard !attributes.isEmpty else { return }
        var more = encoder.container(keyedBy: AttributeKey.self)
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) { try more.encode(value, forKey: AttributeKey(stringValue: key)) }
    }
}

/// Something a draw did that it should say, though it did it: an issue on a shape it drew (its
/// severity `error` or `warning`), a push, a near miss. `line` is the statement's; none for what's
/// about the whole run.
struct DrawWarning: Encodable, Sendable {
    var line: Int?
    var message: String
    var severity: Severity
    /// The property it's about, if one.
    var attribute: String?

    enum Severity: String, Encodable, Sendable { case error, warning }

    init(line: Int?, _ message: String, severity: Severity = .warning, attribute: String? = nil) {
        self.line = line
        self.message = message
        self.severity = severity
        self.attribute = attribute
    }
}

/// How a run that changes nothing leaves the transaction: its result, thrown out of the body so
/// nothing commits.
private struct DryRun: Error {
    let result: DrawResult
}

@MainActor
enum DrawStyle {
    /// `--reveal`: the view eases to fit what was drawn, this far in from the edges of the part of
    /// the view the host leaves clear (`unobscuredViewport`: below the path's pill), no closer than
    /// 100%.
    static let revealInset: CGFloat = 100
    static let revealMaxZoom: CGFloat = 1
    static let revealDuration: Duration = .milliseconds(320)
    /// The undo step a run makes: Edit › Undo Draw takes back the whole run.
    static let stepName = "Draw"
}

// MARK: Running it

@MainActor
func draw(_ params: DrawParams, in context: AutomationContext) throws(AutomationError) -> DrawResult {
    let editor = try context.board()
    let script: Script
    do throws(ScriptErrors) {
        script = try Script(parsing: params.script)
    } catch {
        throw collected(error.errors.map { AutomationError($0) })
    }
    var (board, names) = try Drawing.board(for: script, in: editor)
    let shown = board == editor.board
    if shown {
        // A drag moves shapes from where they were at its press, and its Escape puts them back: what
        // the script changed would be undone under it.
        guard editor.session == nil else {
            throw AutomationError("someone is dragging on this board", reason: ScriptError.Reason.busy.rawValue, hint: "try again in a moment")
        }
        // And whatever commits while a press is held is part of the press's undo step: the run would
        // be taken back with it. (A run on another board is a step of its own, made on that board.)
        guard !editor.undoHistory.isPressHeld else {
            throw AutomationError("someone is pressing on this board", reason: ScriptError.Reason.busy.rawValue, hint: "try again in a moment")
        }
    }
    func worked() throws(AutomationError) -> Drawing {
        guard let reading = editor.reading(of: board) else {
            throw AutomationError("the board went away", reason: ScriptError.Reason.internal.rawValue)
        }
        var drawing = try Drawing(script, editor: editor, on: reading, fileNames: names)
        try drawing.place()
        return drawing
    }
    var drawing = try worked()
    // A shape being edited saves what's typed when editing ends: once the run is sure to change it
    // (it's placed, applies without an error, and changes or deletes that shape), end it, so what's
    // typed lands first, and work the script out again if that changed the board. The run is
    // applied once and thrown away first, since some of what it can fail on (an edge that can't be
    // drawn) is found only as it's applied. A run that fails, or leaves the shape as it is, leaves
    // the typing be, and so does a dry run. The shape edited is on the board shown.
    if !params.dryRun, shown, let editing = editor.editingShapeID, drawing.changes(editing) {
        _ = try apply(drawing, to: editor, reveals: params.reveal, dryRun: true)
        let revision = editor.revision
        editor.endEditing()
        if editor.revision != revision {
            // What was typed may have renamed a shape: the titles are read again, and the board with them.
            (board, names) = try Drawing.board(for: script, in: editor)
            drawing = try worked()
        }
    }
    var result = try apply(drawing, to: editor, reveals: params.reveal, dryRun: params.dryRun)
    // Revealed on another board, that board is shown first, as following a link to it would.
    if params.reveal, !params.dryRun, editor.session == nil, editor.showBoard(board) { reveal(result, in: editor) }
    result.on = DrawBoard(board, in: editor)
    return result
}

/// Applies a placed script in one transaction on its board, one undo step called Draw (Edit › Undo
/// Draw; on a board not shown, a step made there, whose undo shows it), or, on a dry run, applies
/// it and throws it away: what it did (or would do), or why it can't. What's thrown away, or
/// refused, commits nothing and makes no step, so what there was to redo stays.
@MainActor
private func apply(_ drawing: Drawing, to editor: CanvasEditor, reveals: Bool, dryRun: Bool) throws(AutomationError) -> DrawResult {
    do {
        let result = try editor.transact(on: drawing.target.board, DrawStyle.stepName) { transaction in
            // An agent's change, not the person's: what acts on a person's edits leaves it be.
            transaction.byAgent = true
            let result = try drawing.apply(to: &transaction, reveals: reveals)
            if dryRun { throw DryRun(result: DrawResult(changes: result.changes, warnings: result.warnings, dryRun: true)) }
            return result
        }
        guard let result else { throw AutomationError("the board went away", reason: ScriptError.Reason.internal.rawValue) }
        return result
    } catch let dryRun as DryRun {
        return dryRun.result
    } catch let error as AutomationError {
        throw error
    } catch {
        throw AutomationError("the drawing went wrong: \(error)", reason: ScriptError.Reason.internal.rawValue)
    }
}

/// Eases the view to fit what the run made or changed (or, if nothing, what it's about), as the
/// table of contents zooms to a shape: into the part of the view the host leaves clear.
@MainActor
private func reveal(_ result: DrawResult, in editor: CanvasEditor) {
    let clear = editor.unobscuredViewport
    guard !clear.isEmpty else { return }
    let shapes = result.changes.filter { $0.at != nil }
    let changed = shapes.filter { $0.did != .unchanged }
    let bounds = (changed.isEmpty ? shapes : changed).compactMap(\.at).reduce(CGRect.null) { $0.union($1) }
    guard !bounds.isNull, bounds.isFinite else { return }
    editor.animateCamera(to: Camera(fitting: bounds, in: clear, inset: DrawStyle.revealInset, maxZoom: DrawStyle.revealMaxZoom),
                         duration: DrawStyle.revealDuration)
}

// MARK: Errors

extension AutomationError {
    /// A script's error, where it is.
    init(_ error: ScriptError, statement: String? = nil) {
        self.init(error.message, reason: error.reason.rawValue, hint: error.hint, line: error.line, statement: error.statement ?? statement)
    }

    /// An error about one statement.
    init(_ statement: Statement, _ reason: ScriptError.Reason, _ message: String, hint: String? = nil) {
        self.init(message, reason: reason.rawValue, hint: hint, line: statement.line, statement: statement.text)
    }
}

/// Every problem found, in line order, up to `ScriptErrors.limit`: the first as the error, and
/// all of them in `errors` when there's more than one.
func collected(_ errors: [AutomationError]) -> AutomationError {
    let sorted = errors.enumerated().sorted { ($0.element.line ?? 0, $0.offset) < ($1.element.line ?? 0, $1.offset) }.map(\.element)
    let kept = Array(sorted.prefix(ScriptErrors.limit))
    let first = kept[0]
    return AutomationError(first.message, reason: first.reason, hint: first.hint, line: first.line, statement: first.statement,
                           errors: kept.count > 1 ? kept : [])
}
