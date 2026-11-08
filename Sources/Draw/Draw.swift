import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Foundation
import Geometry
import Queries

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

/// The draw engine's plugin: it owns the nine points the plugins that own a concern fill with this
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
        // Where Insert puts a shape down: placed as a script's shape is (Placing).
        registrar.insertionSpot { editor, size, beside in Surroundings.insertionSpot(of: size, beside: beside, in: editor) }
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
        case created, moved, updated, renamed, unchanged, deleted, connected, reconnected, grouped, ungrouped
    }

    var line: Int
    var did: Did
    /// The kind of the shape or edge the statement is about; none for a `group` or `ungroup`, which is about several shapes.
    var kind: String?
    /// What it's called now (a deleted shape: what it was called).
    var title: String?
    /// The shapes a `group` or `ungroup` names, in the order written: each by its title, or, for a shape with none, the id as written.
    var shapes: [String]?
    /// Its id, the one a query's row gives and a script names a shape with no title by (`#<id>`): for a shape the file has, and
    /// for one a real run made; a dry run's `created` row has none, since the shape it would make has no id yet. A deleted
    /// shape's row says it only when the statement named the shape by its id.
    var id: String?
    /// What it was called, if the statement renamed it.
    var was: String?
    /// Where it is: [[x, y], [width, height]], world units.
    var at: CGRect?
    /// Whether any of it is in the window's view (nil when the board isn't in a window).
    var inView: Bool?
    /// What it was pushed past to keep clear of it, by title (or `<kind> at x,y`).
    var pushedPast: [String]?
    /// An edge's ends, by title, or, for a shape with none, by the id the statement wrote.
    var from: String?
    var to: String?
    /// The id of each end the statement named by id.
    var fromID: String?
    var toID: String?
    /// The kind of stand-in an edge's arrow goes through, when it does: it runs into (or out of) one
    /// that stands for the end it's written to, whichever way it came to.
    var via: String?
    /// The arrow runs to a stand-in that was there, or another edge of the run made (`share:`), and, for
    /// `share: "A"`, the title of the shape it is beside.
    var shared: Bool?
    var sharedWith: String?
    /// What its values still need and what is wrong with them, when its types say anything of them
    /// (`DrawReports`).
    var problems: [ShapeProblem]?
    /// An edge's attributes as it has them now (those DrawEdges declares), by key.
    var attributes: [String: JSONValue] = [:]
    /// What a plugin's report adds to the row (`DrawReports`' declared members), by key.
    var members: [String: JSONValue] = [:]
    /// An edge's arrow, and the stand-in it runs into in place of an end, if one: never said, since a script can't name
    /// either; what a program's run keeps of its edges (`DrawDocument`).
    var arrow: ShapeID?
    var standIn: ShapeID?
}

extension DrawChange: Encodable {
    /// A row's own members, which an edge's attributes (written beside them) and a report's members can't be named
    /// (`DrawEdges.check`, `DrawReports.check`).
    enum CodingKeys: String, CodingKey, CaseIterable {
        case line, did, kind, title, shapes, id, was, at, inView, pushedPast, from, to, fromId, toId, via, shared, sharedWith, problems
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
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(shapes, forKey: .shapes)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(was, forKey: .was)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(inView, forKey: .inView)
        try container.encodeIfPresent(pushedPast, forKey: .pushedPast)
        try container.encodeIfPresent(from, forKey: .from)
        try container.encodeIfPresent(to, forKey: .to)
        try container.encodeIfPresent(fromID, forKey: .fromId)
        try container.encodeIfPresent(toID, forKey: .toId)
        try container.encodeIfPresent(via, forKey: .via)
        try container.encodeIfPresent(shared, forKey: .shared)
        try container.encodeIfPresent(sharedWith, forKey: .sharedWith)
        try container.encodeIfPresent(problems, forKey: .problems)
        guard !attributes.isEmpty || !members.isEmpty else { return }
        var more = encoder.container(keyedBy: AttributeKey.self)
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) { try more.encode(value, forKey: AttributeKey(stringValue: key)) }
        for (key, value) in members.sorted(by: { $0.key < $1.key }) { try more.encode(value, forKey: AttributeKey(stringValue: key)) }
    }
}

/// Something a draw did that it should say, though it did it: an issue on a shape it drew (its
/// severity `error` or `warning`; `incomplete` for what a shape the run did not write still needs), a push, a
/// near miss. `line` is the statement's; none for what's about the whole run.
struct DrawWarning: Encodable, Sendable {
    var line: Int?
    var message: String
    var severity: Severity
    /// The property it's about, if one.
    var attribute: String?
    /// It counts the shapes past those said that a run brought issues to (`Drawing.brought`): never said by a document's run, whose
    /// phases bring what a later one mends.
    var countsMore = false
    /// The shape whose issue it says (a row's own, or one a run brought to a shape it did not write): a document's run says the
    /// issues of the drawing's own shapes once, as its last phase leaves them, so it leaves out what a phase said of them mid-way.
    var about: ShapeID?

    enum Severity: String, Encodable, Sendable { case error, warning, incomplete }

    /// What a warning says: `countsMore` and `about` are the engine's own.
    enum CodingKeys: String, CodingKey { case line, message, severity, attribute }

    init(line: Int?, _ message: String, severity: Severity = .warning, attribute: String? = nil) {
        self.line = line
        self.message = message
        self.severity = severity
        self.attribute = attribute
    }

    /// An issue of the shape called `name`, at the level it has; `about` the shape.
    init(line: Int?, _ name: String, issue: DrawIssue, about: ShapeID? = nil) {
        let severity: Severity = switch issue.level {
        case .warning: .warning
        case .error: .error
        case .incomplete: .incomplete
        }
        self.init(line: line, "\(name): \(issue.message)", severity: severity, attribute: issue.field)
        self.about = about
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
    try draw(script: text, dryRun: dryRun, reveal: shouldReveal, program: program, options: DrawOptions(), in: editor)
}

/// As `draw`, and, with `drawing`, the run joins that drawing (`canvas draw --drawing NAME`): every shape its statements name,
/// and every arrow it draws, is kept in the drawing's record with what it now is, keyed by its id, in the run's own step, so a
/// later query says what changed since. Refused, `no_drawings`, where nothing keeps drawings.
@MainActor
public func draw(script text: String, dryRun: Bool, reveal shouldReveal: Bool, program: String, drawing: String?,
                 in editor: CanvasEditor) throws(DrawError) -> DrawResult {
    var options = DrawOptions()
    if let drawing {
        guard editor.registry.drawRecording != nil else {
            throw DrawError("nothing here keeps drawings, so a run can't join one", reason: "no_drawings", hint: "leave --drawing out")
        }
        guard !drawing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DrawError("a drawing's name can't be blank", reason: ScriptError.Reason.invalidValue.rawValue, hint: "--drawing <name>")
        }
        options.drawing = drawing
    }
    return try draw(script: text, dryRun: dryRun, reveal: shouldReveal, program: program, options: options, in: editor)
}

/// What a program's run asks of the engine besides its script, none of which a script an agent types can say (a document's
/// runs, `DrawDocument`): the shapes it may make with ids it picked (a shape statement named `#<id>` by one of `reserved`
/// that the file hasn't makes a shape with that id), where each shape (or the stand-in of an edge) goes exactly, by its
/// statement's line (`places`: its room's top-left, never solved, pushed or pushing), the keys a value may name a shape by
/// (`keys`: in `is:` and in a mention, a key names the shape it's given for before a title is looked for), the board the run
/// draws on when nothing it names says one (`board`), and that titles are only what it calls shapes (`program`: `title:`
/// gives a shape it makes its title, and any shape a title another beside it has).
struct DrawOptions {
    var reserved: Set<ShapeID> = []
    var places: [Int: CGPoint] = [:]
    var keys: [String: ShapeID] = [:]
    var board: BoardID?
    var program = false
    /// The drawing a real run joins (`draw --drawing`): what it names is kept in the drawing's record, in its step.
    var drawing: String?
    /// How a title finds its shape: a script's `.refusing` (none or several is an error), a put's `.nearest` (`put`).
    var naming = Naming.refusing
    /// Whether the run is an agent's change (what acts on a person's edits leaves it be): a script's, not a put's.
    var byAgent = true
    /// The undo step the run makes (`DrawStyle.stepName`, "Draw"), as its caller names it.
    var step = "Draw"
    /// Edges a put's statement implies besides what its values' writers say (`DrawPut.edges`), by the statement's line, each
    /// to a far shape named by a key (`keys`): drawn as a writer's implied edges are.
    var implied: [Int: [DrawImpliedEdge]] = [:]

    enum Naming {
        /// A title that names none, or several, is refused (`ambiguous_title`): a script, which an agent types.
        case refusing
        /// A title that names several finds the first of them, in the order the board lists them (a text's too, as a column's
        /// type names an enum); `put` finds the nearest itself (`PutFinding`) and names it by its id, so this is only the fallback
        /// for a name it left a title. An edge a value implies that can't be drawn is left out, never refused.
        case nearest
    }
}

@MainActor
func draw(script text: String, dryRun: Bool, reveal shouldReveal: Bool, program: String, options: DrawOptions,
          in editor: CanvasEditor) throws(DrawError) -> DrawResult {
    let script: Script
    do throws(ScriptErrors) {
        script = try Script(parsing: text)
    } catch {
        throw collected(error.errors.map { DrawError($0) })
    }
    return try draw(parsed: script, dryRun: dryRun, reveal: shouldReveal, program: program, options: options, in: editor)
}

/// As `draw`, of a script already read: a program's values, never text (`put`).
@MainActor
func draw(parsed script: Script, dryRun: Bool, reveal shouldReveal: Bool, program: String, options: DrawOptions,
          in editor: CanvasEditor) throws(DrawError) -> DrawResult {
    var (board, names) = try Drawing.board(for: script, in: editor, pinned: options.board)
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
        var drawing = try Drawing(script, editor: editor, on: reading, fileNames: names, options: options, program: program)
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
            (board, names) = try Drawing.board(for: script, in: editor, pinned: options.board)
            drawing = try worked()
        }
    }
    var result = try apply(drawing, to: editor, reveals: shouldReveal, dryRun: dryRun, joining: options.drawing)
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
private func apply(_ drawing: Drawing, to editor: CanvasEditor, reveals: Bool, dryRun: Bool, joining name: String? = nil) throws(DrawError) -> DrawResult {
    do {
        let result = try editor.transact(on: drawing.target.board, drawing.options.step) { transaction in
            // An agent's change, not the person's: what acts on a person's edits leaves it be.
            transaction.byAgent = drawing.options.byAgent
            let result = try drawing.apply(to: &transaction, reveals: reveals)
            if !dryRun, let name, let records = editor.registry.drawRecording {
                join(name, result, on: drawing.target.board, records: records, file: editor.file, registry: editor.registry, in: &transaction)
            }
            if dryRun {
                // A shape the run would make has no id yet: a dry run's row would say one that never was.
                let rows = result.changes.map { row -> DrawChange in
                    var row = row
                    if row.did == .created { row.id = nil }
                    return row
                }
                throw DryRun(result: DrawResult(changes: rows, warnings: result.warnings, dryRun: true))
            }
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
    /// Whether it says a name a text writes (a title in a script's value) found no shape, or several, or one the
    /// value can't be: what `canvas measure` makes a warning, since it measures without the shape.
    var fromNameLookup = false
    /// The name it was looked up by, when it is from the name lookup (`lookedFor`).
    var lookedForName: String?

    public init(_ message: String, reason: String, hint: String? = nil, line: Int? = nil, statement: String? = nil, errors: [DrawError] = []) {
        self.message = message
        self.reason = reason
        self.hint = hint
        self.line = line
        self.statement = statement
        self.errors = errors
    }

    public var description: String { message }

    /// This error with another hint, and everything else of it (where the name was looked up, for one).
    public func with(hint: String?) -> DrawError {
        var changed = DrawError(message, reason: reason, hint: hint, line: line, statement: statement, errors: errors)
        changed.fromNameLookup = fromNameLookup
        changed.lookedForName = lookedForName
        return changed
    }
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
    // One problem is itself, with what it knows of the name it looked up.
    if kept.count == 1 { return kept[0] }
    let first = kept[0]
    return DrawError(first.message, reason: first.reason, hint: first.hint, line: first.line, statement: first.statement, errors: kept)
}

/// A run's shapes kept in the drawing it joins (`draw --drawing`): each row's shape the run leaves on the board, and each arrow
/// and pill it draws, with what it now is, keyed by its id where the drawing hasn't a key for it; a shape a statement deleted by
/// its id is taken off the record.
@MainActor
private func join(_ name: String, _ result: DrawResult, on board: BoardID, records: DrawRecording, file: CanvasFile, registry: Registry,
                  in transaction: inout Transaction) {
    var record = records.read(name, file) ?? DrawingRecord(board: board.description)
    func keep(_ id: ShapeID) {
        guard let now = transaction.document[id], let state = DrawnState.of(now, on: board, registry: registry) else { return }
        record.shapes[id.description] = DrawingRecord.Shape(key: record.shapes[id.description]?.key ?? RecordKey.joined(id), wrote: state)
    }
    for row in result.changes {
        if row.did == .deleted {
            if let text = row.id { record.shapes[text] = nil }
            continue
        }
        if let arrow = row.arrow { keep(arrow) }
        if let pill = row.standIn { keep(pill) }
        if let text = row.id, let uuid = UUID(uuidString: text) { keep(ShapeID(uuid)) }
    }
    records.write(name, record, &transaction)
}
