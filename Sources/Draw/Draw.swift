import Canvas
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

// MARK: The plugin

extension PluginID {
    public static let drawEngine: PluginID = "draw-engine"
}

/// The draw engine's plugin: it owns the four points the plugins that own a concern fill with this
/// app's words (DrawPoints.swift), and contributes the engine's mark. A plugin that isn't a language
/// runs the engine through the free functions `draw` (here), `measure` (Measure.swift) and `kinds`
/// (Kinds.swift); the command line's commands over it are Automation's.
public struct DrawPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .drawEngine }

    #if DEBUG
    /// How many times a run has read the names of every board of a file in this process, debug
    /// builds only: a script that names no shape, in its statements or its texts, reads none, and
    /// one that does reads them once.
    @MainActor public internal(set) static var fileNamesRead = 0
    /// How many boards' arrows a run has read to choose the board it draws on, debug builds only: only
    /// an edge between two boards looks (for itself, drawn through a stand-in), each board once a run.
    @MainActor public internal(set) static var boardConnectionsRead = 0
    #endif

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contribute(DrawEngine(), to: DrawEngines.self)
    }
}

/// That this app has the draw engine (`DrawPlugin` is installed): its mark, as the query engine's
/// (`QueryEngine`), which only this module can make.
public struct DrawEngine: Sendable {
    init() {}
}

/// Who runs `canvas draw`'s engine: `DrawPlugin`, once.
public enum DrawEngines {}

extension DrawEngines: KeyedExtensionPoint {
    public typealias Contribution = DrawEngine
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of _: DrawEngine, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawEngine, for _: ShapeTarget) -> String { label }
    static let label = "draw engine"
}

// MARK: Result

/// What a draw did, a row per thing it made, changed, left as it was or deleted, in script order;
/// what it drew anyway but should say (issues, pushes, nudges, near misses); and, on a dry run, that
/// nothing changed.
public struct DrawResult: Encodable, Sendable {
    var changes: [DrawChange]
    var warnings: [DrawWarning]
    var dryRun: Bool?
    /// The board it drew on (the board shown, unless what the script names is on another).
    var on: DrawBoard?
    /// What settling nudged into or out of containers, by how far (world units), for the glide;
    /// never said.
    var nudges: [ShapeID: CGPoint] = [:]

    enum CodingKeys: String, CodingKey {
        case changes, warnings, dryRun, on
    }
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
    /// The kind of stand-in an edge's arrow goes through, when it does: it runs into (or out of) one
    /// that stands for the end it's written to, whichever way it came to.
    var via: String?
    /// The arrow runs to a stand-in that was there, or another edge of the run made (`share:`), and, for
    /// `share: "A"`, the title of the shape it is beside.
    var shared: Bool?
    var sharedWith: String?
    /// An edge's attributes as it has them now (those DrawEdges declares), by key.
    var attributes: [String: JSONValue] = [:]
}

extension DrawChange: Encodable {
    /// A row's own members, which an edge's attributes (written beside them) can't be named
    /// (`DrawEdges.check`).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case line, did, kind, title, was, at, inView, pushedPast, from, to, via, shared, sharedWith
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
        try container.encodeIfPresent(via, forKey: .via)
        try container.encodeIfPresent(shared, forKey: .shared)
        try container.encodeIfPresent(sharedWith, forKey: .sharedWith)
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

/// Runs a script on the board `editor` shows (or the one what it names is on). `program` is the name
/// its hints give the command line that runs it: the commands they name are `<program> show` and
/// `<program> kinds`.
@MainActor
public func draw(script text: String, dryRun: Bool, reveal shouldReveal: Bool, program: String, in editor: CanvasEditor) throws(DrawError) -> DrawResult {
    let script: Script
    do throws(ScriptErrors) {
        script = try Script(parsing: text)
    } catch {
        throw collected(error.errors.map { DrawError($0) })
    }
    var (board, names) = try Drawing.board(for: script, in: editor)
    let shown = board == editor.board
    if shown {
        // A drag moves shapes from where they were at its press, and its Escape puts them back: what
        // the script changed would be undone under it.
        guard editor.session == nil else {
            throw DrawError("someone is dragging on this board", reason: ScriptError.Reason.busy.rawValue, hint: "try again in a moment")
        }
        // And whatever commits while a press is held is part of the press's undo step: the run would
        // be taken back with it. (A run on another board is a step of its own, made on that board.)
        guard !editor.undoHistory.isPressHeld else {
            throw DrawError("someone is pressing on this board", reason: ScriptError.Reason.busy.rawValue, hint: "try again in a moment")
        }
    }
    func worked() throws(DrawError) -> Drawing {
        guard let reading = editor.reading(of: board) else {
            throw DrawError("the board went away", reason: ScriptError.Reason.internal.rawValue)
        }
        var drawing = try Drawing(script, editor: editor, on: reading, fileNames: names, program: program)
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
    if !dryRun, shown, let editing = editor.editingShapeID, drawing.changes(editing) {
        _ = try apply(drawing, to: editor, reveals: shouldReveal, dryRun: true)
        let revision = editor.revision
        editor.endEditing(discarding: false)
        if editor.revision != revision {
            // What was typed may have renamed a shape: the titles are read again, and the board with them.
            (board, names) = try Drawing.board(for: script, in: editor)
            drawing = try worked()
        }
    }
    var result = try apply(drawing, to: editor, reveals: shouldReveal, dryRun: dryRun)
    // What was nudged into or out of a container glides there, as one put down by hand does (on
    // the board shown).
    if !dryRun { editor.glide(result.nudges) }
    // Revealed on another board, that board is shown first, as following a link to it would.
    if shouldReveal, !dryRun, editor.session == nil, editor.showBoard(board) { reveal(result, in: editor) }
    result.on = DrawBoard(board, in: editor)
    return result
}

/// Applies a placed script in one transaction on its board, one undo step called Draw (Edit › Undo
/// Draw; on a board not shown, a step made there, whose undo shows it), or, on a dry run, applies
/// it and throws it away: what it did (or would do), or why it can't. What's thrown away, or
/// refused, commits nothing and makes no step, so what there was to redo stays.
@MainActor
private func apply(_ drawing: Drawing, to editor: CanvasEditor, reveals: Bool, dryRun: Bool) throws(DrawError) -> DrawResult {
    do {
        let result = try editor.transact(on: drawing.target.board, DrawStyle.stepName) { transaction in
            // An agent's change, not the person's: what acts on a person's edits leaves it be.
            transaction.byAgent = true
            let result = try drawing.apply(to: &transaction, reveals: reveals)
            if dryRun { throw DryRun(result: DrawResult(changes: result.changes, warnings: result.warnings, dryRun: true)) }
            return result
        }
        guard let result else { throw DrawError("the board went away", reason: ScriptError.Reason.internal.rawValue) }
        return result
    } catch let dryRun as DryRun {
        return dryRun.result
    } catch let error as DrawError {
        throw error
    } catch {
        throw DrawError("the drawing went wrong: \(error)", reason: ScriptError.Reason.internal.rawValue)
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

/// Why a run didn't do what it was asked: said for a person, with a reason an agent can branch on
/// (`unknown_kind`) and a hint, often the command to run instead. A script's errors say where in
/// it: the `line` (from 1) and the `statement` as written there; and a run that finds several
/// problems at once gives the first as itself and every one, the first too, in `errors`. The
/// closures a plugin gives the points throw it too, for what they can't make or write, and the run
/// says on which line.
public struct DrawError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let reason: String
    public let hint: String?
    /// The line of the script it's about, from 1.
    public let line: Int?
    /// That line as it's written (its comment left out, trimmed).
    public let statement: String?
    /// Every problem found, this one first; empty when it's the only one.
    public let errors: [DrawError]

    public init(_ message: String, reason: String, hint: String? = nil, line: Int? = nil, statement: String? = nil, errors: [DrawError] = []) {
        self.message = message
        self.reason = reason
        self.hint = hint
        self.line = line
        self.statement = statement
        self.errors = errors
    }

    public var description: String { message }
}

extension DrawError {
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
func collected(_ errors: [DrawError]) -> DrawError {
    let sorted = errors.enumerated().sorted { ($0.element.line ?? 0, $0.offset) < ($1.element.line ?? 0, $1.offset) }.map(\.element)
    let kept = Array(sorted.prefix(ScriptErrors.limit))
    let first = kept[0]
    return DrawError(first.message, reason: first.reason, hint: first.hint, line: first.line, statement: first.statement,
                     errors: kept.count > 1 ? kept : [])
}
