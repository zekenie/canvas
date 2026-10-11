import AppKit
import Canvas
import TableOfContents

extension PluginID {
    public static let validation: PluginID = "validation"
}

/// Two channels, as ESLint's: an error makes a shape invalid, a warning only flags it.
public enum Severity: Int, Comparable, Sendable {
    case warning, error
    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

public struct ValidationIssue: Hashable, Sendable {
    public var message: String
    public var severity: Severity
    /// Set when the issue is about one field of the shape rather than the whole shape.
    public var field: String?
    public init(_ message: String, severity: Severity, field: String? = nil) {
        self.message = message
        self.severity = severity
        self.field = field
    }
    /// Makes the shape invalid.
    public static func error(_ message: String, field: String? = nil) -> ValidationIssue { ValidationIssue(message, severity: .error, field: field) }
    /// Flags the shape, which stays valid.
    public static func warning(_ message: String, field: String? = nil) -> ValidationIssue { ValidationIssue(message, severity: .warning, field: field) }
}

public struct ValidationResult: Equatable, Sendable {
    public var issues: [ValidationIssue]
    public init(issues: [ValidationIssue]) { self.issues = issues }
    /// Derived, never stored: valid means no error-severity issue.
    public var isValid: Bool { !issues.contains { $0.severity == .error } }
    /// Worked out as it's read, making nothing: the overlay reads it for every shape in view.
    public var worst: Severity? { issues.lazy.map(\.severity).max() }
    /// Worst first (the errors, then the warnings), each severity in the rules' order: how every list
    /// of them reads.
    public var worstFirst: [ValidationIssue] {
        issues.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// A shape's verdict as the engine holds it, without checking (`ValidationEngine.cachedResult(for:)`).
public enum CachedVerdict: Equatable, Sendable {
    /// What the engine found of the shape, which still holds: its issues, nil for none.
    case current(ValidationResult?)
    /// Nothing it can say without checking the shape.
    case unknown
}

/// Rules' only way into the document. The engine notes the shapes a rule looks up, and checks the
/// shape again when one of them changes; for a rule that ignores moves, not when one only moves.
/// What a rule reads of a service (`service(_:)`) is no lookup: its `affected` says what a commit
/// changes there. Add lookups here as rules need them.
@MainActor
public struct ValidationContext {
    /// The shapes rules see: the engine's, the editor's document; `validationIssues(of:in:)`'s,
    /// whatever it's given (a transaction's, mid-way).
    let shapes: ShapeContext
    /// What the installed plugins registered, for a rule over every kind that asks about the
    /// shape's kind or another's (whether it can hold names, whether it can be mentioned). It
    /// never changes, so reading it is no lookup.
    public let registry: Registry
    /// Validation's own rule's: each shape's schema issues, kept from one check to the next.
    let schemaVerdicts: SchemaVerdicts
    let lookups: Lookups
    /// The editor whose shapes are checked, if any.
    let editor: CanvasEditor?

    public func shape(_ id: ShapeID) -> AnyShapeRecord? {
        if lookups.ignoringMoves { lookups.steady.insert(id) } else { lookups.placed.insert(id) }
        return shapes.shape(id)
    }

    /// A service of the editor whose shapes are checked: for a rule over what a plugin keeps across
    /// the file (`TitleValidationPlugin`'s titles), whose `affected` names the shapes each commit
    /// changes that for. Nil where shapes are checked without an editor (`validationIssues(of:in:)`
    /// given none: what `canvas draw` checks before it commits).
    public func service<S: EditorService>(_ type: S.Type) -> S? { editor?.service(type) }
}

/// The shapes a shape's rules looked up while it was checked: by the rules that ignore moves, and
/// by the others (a move of one of these checks the shape again).
@MainActor
final class Lookups {
    /// Whether the rule being run ignores moves: where its lookups go.
    var ignoringMoves = false
    var steady: Set<ShapeID> = []
    var placed: Set<ShapeID> = []
}

public struct ValidationRule {
    let check: @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]
    /// Whether its issues follow from what shapes are and never from where they are: from the
    /// shape's props and added values but its box's origin, and the same of the shapes it looks up.
    /// A commit that only moves shapes (`ChangeSet.moved`: a drag, every event) runs it again for
    /// none of them, neither those it moved nor those whose rule looked one of them up: each keeps
    /// what this rule found. A rule that measures distances, or finds overlaps, must not.
    let ignoresMoves: Bool
    /// For a rule that reads more than the shapes it looks up (a service's state, across the file):
    /// given each commit, the shapes it may change the issues of without changing them, or a shape
    /// they looked up, on any board. The engine hears it as it hears the commit, and checks those on
    /// the board shown again, and those on a board it keeps, once that board is shown. It runs on
    /// every commit, so it costs what the commit changed, never the board.
    let affected: (@MainActor (ChangeSet, CanvasEditor) -> Set<ShapeID>)?
    public init(ignoringMoves: Bool = false, affected: (@MainActor (ChangeSet, CanvasEditor) -> Set<ShapeID>)? = nil,
                _ check: @escaping @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]) {
        self.check = check
        ignoresMoves = ignoringMoves
        self.affected = affected
    }
}

/// Validation's extension point: this plugin declares it, any plugin contributes, the core never
/// sees what it means.
public enum ValidationRules: ExtensionPoint {
    public typealias Contribution = ValidationRule
    public static var owner: PluginID { .validation }
}

extension ShapeRegistrar {
    /// A rule for this kind, with its props typed; `ignoringMoves` for one whose issues follow from
    /// what shapes are, never where, and `affected` for one that reads a service (`ValidationRule`).
    public mutating func validate(ignoringMoves: Bool = false, affected: (@MainActor (ChangeSet, CanvasEditor) -> Set<ShapeID>)? = nil,
                                  _ rule: @escaping @MainActor (ShapeRecord<Definition.Props>, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(ignoringMoves: ignoringMoves, affected: affected) { record, context in
            record.typed(as: Definition.Props.self).map { rule($0, context) } ?? []
        }, to: ValidationRules.self)
    }
}

extension PluginRegistrar {
    /// A rule for a kind another plugin registers.
    public mutating func validate<P: ShapeProps>(_: P.Type, ignoringMoves: Bool = false,
                                                 affected: (@MainActor (ChangeSet, CanvasEditor) -> Set<ShapeID>)? = nil,
                                                 _ rule: @escaping @MainActor (ShapeRecord<P>, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(ignoringMoves: ignoringMoves, affected: affected) { record, context in
            record.typed(as: P.self).map { rule($0, context) } ?? []
        }, to: ValidationRules.self, for: .kind(P.kind))
    }

    /// A rule for every kind.
    public mutating func validateEveryShape(ignoringMoves: Bool = false, affected: (@MainActor (ChangeSet, CanvasEditor) -> Set<ShapeID>)? = nil,
                                            _ rule: @escaping @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(ignoringMoves: ignoringMoves, affected: affected, rule), to: ValidationRules.self, for: .any)
    }
}

/// Every shape's issues: on the first read, every shape's; after that, on the first read after a
/// change, only those of the shapes it touched and of the shapes whose rules looked one of them up.
/// A commit that only moves shapes runs none of the rules that ignore moves again (the schema
/// rule is one): it checks the shapes it moved, and those whose other rules looked one of them up,
/// with those other rules alone, each keeping what the rest found. A rule that reads a service names
/// the shapes each commit changes its issues of (`affected`), which are checked again too. It checks
/// the board shown; what it found on the boards shown last is kept for going back to them, and taken
/// back while those boards are as they were left (`BoardStash`), with the shapes rules named there
/// meanwhile checked again.
@MainActor
public final class ValidationEngine {
    /// The shapes each shape's rules looked up, and the other way around.
    private struct LookupTable {
        private(set) var of: [ShapeID: Set<ShapeID>] = [:]
        private(set) var by: [ShapeID: Set<ShapeID>] = [:]

        mutating func set(_ ids: Set<ShapeID>, for shape: ShapeID) {
            if of[shape] != nil { forget(shape) }
            guard !ids.isEmpty else { return }
            of[shape] = ids
            for other in ids { by[other, default: []].insert(shape) }
        }

        mutating func forget(_ shape: ShapeID) {
            for other in of.removeValue(forKey: shape) ?? [] {
                by[other]?.remove(shape)
                if by[other]?.isEmpty == true { by[other] = nil }
            }
        }
    }

    /// What it knows of a board: what it found, what's left to check, and what the rules looked up.
    private struct Board {
        /// Only shapes with at least one issue.
        var cache: [ShapeID: ValidationResult] = [:]
        /// The shapes to check again with every rule.
        var unchecked: Set<ShapeID> = []
        /// The shapes to check again with only the rules that don't ignore moves.
        var moved: Set<ShapeID> = []
        /// What the rules that ignore moves found of each shape, by the rule's place among its
        /// kind's: only those that found something.
        var steadyIssues: [ShapeID: [Int: [ValidationIssue]]] = [:]
        /// What the rules that ignore moves looked up, and what the others did.
        var steadyLookups = LookupTable()
        var placedLookups = LookupTable()
        /// The shapes rules' `affected` named while the board was kept, not shown.
        var namedAway: Set<ShapeID> = []
    }

    private unowned let editor: CanvasEditor
    /// Each kind's rules, found once: the registry is frozen.
    private var rules: [ShapeKind: [ValidationRule]] = [:]
    /// What it knows of the board shown; nil to check every shape on the next read.
    private var board: Board?
    /// The revision `board` is up to date with. Read before this engine has heard of a commit (by a
    /// service that hears first), it checks every shape.
    private var heardRevision: Int
    /// What the schema rule found of each shape, so one that only moved isn't checked again.
    private let schemaVerdicts = SchemaVerdicts()
    /// The boards shown last, as they were left.
    private var kept = BoardStash<Board>()
    /// Every rule's `affected`, found once: the registry is frozen.
    private lazy var affectedByRules = editor.registry.contributions(to: ValidationRules.self).compactMap(\.value.affected)
    /// What they named on the board shown for the last commit heard, and its revision.
    private var named: (revision: Int, ids: Set<ShapeID>) = (-1, [])
    /// What they named on the board shown while it was kept, as it was taken back.
    private var namedAway: Set<ShapeID> = []
    /// Each outlined shape's ring, as the overlay last drew it.
    let rings = ValidationRings()
    #if DEBUG
    /// How many rings the overlay has grown from shapes' outlines, and how many it keeps, debug
    /// builds: a frame drawn again at the same zoom grows none.
    public var ringsGrown: Int { rings.grown }
    public var ringsKept: Int { rings.count }
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
    }

    /// Only shapes with at least one issue.
    public var results: [ShapeID: ValidationResult] {
        refreshIfNeeded()
        return board?.cache ?? [:]
    }

    public func result(for id: ShapeID) -> ValidationResult? { results[id] }

    /// A shape's issues as the engine last found them, if that still holds, checking nothing: for a
    /// reader that mustn't make the engine read a board (`results` checks what's waiting, and every
    /// shape of a board it hasn't read yet), as a query asking about many shapes does. Current only
    /// for a shape on the board shown, once the engine has heard every commit and read that board,
    /// and while the shape isn't waiting to be checked again (it changed or moved, or a shape its
    /// rules looked up did); unknown otherwise, where only running its rules can say
    /// (`registry.validationIssues(of:in:)`). It never runs a rule.
    public func cachedResult(for id: ShapeID) -> CachedVerdict {
        guard heardRevision == editor.revision, let board, !board.unchecked.contains(id), !board.moved.contains(id),
              editor.withoutObservingDocument({ editor.document[id] != nil }) else { return .unknown }
        return .current(board.cache[id])
    }

    /// The shapes whose rules looked one of `ids` up when they were last checked: those a change to
    /// it may check again, besides itself. For a plugin that keeps what it shows of each shape's
    /// issues and redoes it for what each commit changed (`ValidationContentsPlugin`'s marks).
    public func dependents(of ids: Set<ShapeID>) -> Set<ShapeID> {
        guard let board else { return [] }
        return ids.reduce(into: []) { found, id in
            found.formUnion(board.steadyLookups.by[id] ?? [])
            found.formUnion(board.placedLookups.by[id] ?? [])
        }
    }

    /// The shapes whose issues a commit may change though it doesn't change them, for a plugin that
    /// keeps what it shows of each shape's issues and redoes it for what each commit changed
    /// (`ValidationContentsPlugin`'s marks): those whose rules looked up a shape it changed
    /// (`dependents(of:)`), and those on the board shown that the rules' `affected` named for it,
    /// once the engine has heard it (so asked by a service that hears commits after Validation's).
    /// Given what other boards changed while the board shown wasn't (`elsewhere`: the table of
    /// contents' catch-up on going back to it), those the rules named on it meanwhile too.
    public func affected(by changes: ChangeSet) -> Set<ShapeID> {
        var found = dependents(of: changes.shapeIDs)
        if named.revision == editor.revision { found.formUnion(named.ids) }
        if !changes.elsewhere.isEmpty { found.formUnion(namedAway) }
        return found
    }

    /// The shapes the rules' `affected` name for a commit: those on the board shown, returned, to
    /// check again; those on a board it keeps, checked again once that board is taken back.
    private func name(_ changes: ChangeSet) -> Set<ShapeID> {
        guard !affectedByRules.isEmpty else { return [] }
        var ids: Set<ShapeID> = []
        for affected in affectedByRules { ids.formUnion(affected(changes, editor)) }
        return mark(ids)
    }

    /// Of `ids`, those on the board shown, returned, to check again; the ones on a board it keeps are
    /// filed there, to be checked once that board is taken back.
    private func mark(_ ids: Set<ShapeID>) -> Set<ShapeID> {
        var here: Set<ShapeID> = []
        let document = editor.document, file = editor.file, keptBoards = kept.boards
        for id in ids {
            if document[id] != nil {
                here.insert(id)
            } else if !keptBoards.isEmpty, let board = file.board(containing: id), keptBoards.contains(board) {
                kept.modify(board) { kept in
                    kept.unchecked.insert(id)
                    kept.namedAway.insert(id)
                }
            }
        }
        return here
    }

    /// Checks these shapes again though no commit named them: for a rule that reads something outside
    /// the shape and the shapes it looks up, which changed: a service's state (a field's caret left, a
    /// type was edited). On the board shown, they are unchecked now; on a board it keeps, when that
    /// board is taken back. Redraws, and has the table of contents make their rows again.
    public func recheck(_ ids: Set<ShapeID>) {
        guard !ids.isEmpty else { return }
        let here = mark(ids)
        board?.unchecked.formUnion(here)
        // What `affected(by:)` names for this revision, so a service that hears the commit after
        // this engine still sees them.
        if named.revision == editor.revision { named.ids.formUnion(here) } else { named = (editor.revision, here) }
        guard !here.isEmpty else { return }
        editor.contentsDidChange(for: here)
        editor.setNeedsDisplay()
    }

    private func refreshIfNeeded() {
        let document = editor.document
        if heardRevision != editor.revision {
            board = nil
            heardRevision = editor.revision
        }
        // Lookups in the document, and nothing else: rules see shapes only through `shape(_:)`.
        let shapes = ShapeContext(document: document, registry: editor.registry)
        guard var board else {
            var fresh = Board()
            schemaVerdicts.forgetAll()
            for shape in document.shapes { check(shape, in: shapes, into: &fresh) }
            self.board = fresh
            return
        }
        guard !board.unchecked.isEmpty || !board.moved.isEmpty else { return }
        self.board = nil                                   // so `board` is the only copy, changed in place
        let unchecked = board.unchecked, moved = board.moved.subtracting(board.unchecked)
        board.unchecked = []
        board.moved = []
        for id in unchecked {
            if let shape = document[id] {
                check(shape, in: shapes, into: &board)
            } else {
                board.cache[id] = nil
                board.steadyIssues[id] = nil
                board.steadyLookups.forget(id)
                board.placedLookups.forget(id)
            }
        }
        for id in moved {
            guard let shape = document[id] else { continue }
            check(shape, in: shapes, onlyPlaced: true, into: &board)
        }
        self.board = board
    }

    /// Checks a shape with every rule, or (`onlyPlaced`) with the rules that don't ignore moves,
    /// taking what the others found last.
    private func check(_ shape: AnyShapeRecord, in shapes: ShapeContext, onlyPlaced: Bool = false, into board: inout Board) {
        // Shapes the board keeps aside aren't the app's to judge.
        guard !shape.isOpaque else {
            board.cache[shape.id] = nil
            return
        }
        let lookups = Lookups()
        let context = ValidationContext(shapes: shapes, registry: shapes.registry, schemaVerdicts: schemaVerdicts, lookups: lookups, editor: editor)
        let kept = onlyPlaced ? board.steadyIssues[shape.id] : nil
        var steady: [Int: [ValidationIssue]] = [:]
        var issues: [ValidationIssue] = []
        for (index, rule) in rules(for: shape.kind).enumerated() {
            lookups.ignoringMoves = rule.ignoresMoves
            let found = rule.ignoresMoves && onlyPlaced ? kept?[index] ?? [] : rule.check(shape, context)
            if rule.ignoresMoves, !found.isEmpty { steady[index] = found }
            issues += found
        }
        board.cache[shape.id] = issues.isEmpty ? nil : ValidationResult(issues: issues)
        board.steadyIssues[shape.id] = steady.isEmpty ? nil : steady
        board.placedLookups.set(lookups.placed, for: shape.id)
        if !onlyPlaced { board.steadyLookups.set(lookups.steady, for: shape.id) }
    }

    private func rules(for kind: ShapeKind) -> [ValidationRule] {
        if let found = rules[kind] { return found }
        let found = editor.registry.contributions(to: ValidationRules.self, for: kind)
        rules[kind] = found
        return found
    }
}

extension ValidationEngine: EditorService {
    public func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        // A commit heard out of turn (a service committed while hearing an earlier one, which this
        // engine hasn't heard yet): what the earlier one changed isn't known, so no verdict kept
        // can be trusted to still hold, and a shape this one only moved may have changed in it. The
        // rest catches up when that one is heard.
        let outOfTurn = heardRevision < editor.revision - 1
        if outOfTurn { schemaVerdicts.forgetAll() }
        heardRevision = editor.revision
        schemaVerdicts.documentDidChange(changes)
        let named = name(changes)
        self.named = (editor.revision, named)
        guard board != nil else { return }                 // every shape is unchecked already
        board!.unchecked.formUnion(named)
        for id in changes.shapeIDs {
            if changes.moved.contains(id), !outOfTurn {
                // Only moved: what the rules that ignore moves found of it, and of the shapes whose
                // rules of that sort looked it up, still holds.
                board!.moved.insert(id)
                board!.moved.formUnion(board!.placedLookups.by[id] ?? [])
            } else {
                board!.unchecked.insert(id)
                board!.unchecked.formUnion(board!.steadyLookups.by[id] ?? [])
                board!.unchecked.formUnion(board!.placedLookups.by[id] ?? [])
            }
        }
    }

    /// Keeps what it found on the board left, if it has checked it, for going back to it.
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new, heardRevision == editor.revision, let board else { return }
        kept.keep(board, for: old, in: editor)
    }

    /// Checks the board shown: what it found there, if it's as it was left, and the shapes it hadn't
    /// checked again yet; else every shape, on the next read.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        board = kept.take(for: change.to, in: editor)
        namedAway = board?.namedAway ?? []
        board?.namedAway = []
        heardRevision = editor.revision
    }
}

extension CanvasEditor {
    public var validation: ValidationEngine? { service(ValidationEngine.self) }
}

extension Registry {
    /// A shape's issues as the engine finds them, whether or not it's on a board: every rule for its
    /// kind, in the rules' order (its schema's warnings too), each looking other shapes up in
    /// `shapes`, a transaction's (`transaction.shapes`) for a shape as it's about to be. Empty for a
    /// shape kept aside, which isn't the app's to judge. For what checks shapes it changes without
    /// waiting for a commit (the command line); the engine keeps every shape's on the board.
    /// `editor` lends the rules its services (`ValidationContext.service`), for a shape as the
    /// editor's file has it (a query's, on a board not shown); without it, a rule that reads one
    /// finds nothing.
    public func validationIssues(of record: AnyShapeRecord, in shapes: ShapeContext, editor: CanvasEditor? = nil) -> [ValidationIssue] {
        guard !record.isOpaque else { return [] }
        // Verdicts of its own: the engine's are kept by id, for shapes as the board has them.
        let context = ValidationContext(shapes: shapes, registry: self, schemaVerdicts: SchemaVerdicts(), lookups: Lookups(), editor: editor)
        return contributions(to: ValidationRules.self, for: record.kind).flatMap { $0.check(record, context) }
    }
}

extension Severity {
    /// What the outline is drawn in, for a plugin that shows the severity elsewhere to match (the
    /// dots of `ValidationContentsPlugin`).
    @MainActor public var color: NSColor {
        switch self {
        case .error: ValidationStyle.error
        case .warning: ValidationStyle.warning
        }
    }
}

@MainActor
enum ValidationStyle {
    static let error = NSColor.systemRed
    static let warning = NSColor.systemOrange
    // View points.
    /// How far the ring stands outside the selection's outline, which stands off a closed shape's
    /// edge (`CanvasEditor.outlineGap`): the two lines never lie over each other, and every kind's
    /// ring is the same distance from its shape. Zoomed out, where an outline is a ring on the
    /// frame, it's this far from the frame.
    static let padding: CGFloat = 3
    static let lineWidth: CGFloat = 2
    /// The corners of a ring around a small shape's bounds, before the outline's standoff grows them.
    static let cornerRadius: CGFloat = 4
    /// A shape smaller than this on screen, either way, is ringed by a rounded rect around its
    /// bounds, which looks the same there, and costs nothing to make.
    static let outlineMinSide: CGFloat = 32
    /// A ring grown at one zoom is kept while the zoom stays within this fraction of it: its padding
    /// is then off by at most a tenth of 3 points, which no one sees, and a pinch or a zoom's glide
    /// grows each ring once every tenth, not every frame.
    static let ringZoomTolerance: CGFloat = 0.1
}

/// The horizontal draws its own decoration; shapes never know they're invalid. A shape is outlined
/// in its worst issue's color: red with an error, orange with only warnings, not at all without;
/// nor while it's being edited, since what it says is still being written. In full, the ring
/// follows the shape's own outline (`ValidationRings`), as a selection's does, 3 view points outside
/// where that stands (a closed shape's is `outlineGap` off its edge, so its ring is that and 3 out;
/// an open one's is on its line), each stroked alone, and outside the rings of tinted outlines the
/// canvas draws round a closed shape (`OverlayContext.tintedOutset(of:)`: a shape in two lights,
/// or selected and lit, has its ring that much further out, so it isn't drawn over theirs).
/// Zoomed out, where shapes are skeletons, the
/// rings are a map of where the problems are, and there, with thousands in view, each is its
/// bounds' ring filled with square corners (as the selection's outlines are there), a run of one
/// color at a time as one path, and no outline is grown: Core Graphics fills rects in one path for
/// a fraction of what stroking each costs (4,800 at 10%: 2.7 ms against 21), while rounded corners
/// in one path, stroked or filled, cost ten times more than each stroked alone.
struct ValidationOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        guard let engine = context.editor.validation else { return }
        let results = engine.results
        engine.rings.forget(allBut: results)
        guard !results.isEmpty else { return }
        let editing = context.editor.editingShapeID
        let zoom = context.zoom, cg = context.cg
        let pad = ValidationStyle.padding / zoom, width = ValidationStyle.lineWidth / zoom
        // In paint order, so overlapping outlines stack the same way every time; only shapes whose
        // outline can reach the view, a closed shape's ring in full being outside the selection's
        // and the tinted rings'.
        let reach = pad + context.greatestTintedOutset / zoom + (context.drawsSkeletons ? 0 : context.editor.outlineGap / zoom) + width
        let shapes = context.editor.paintOrder(in: context.visibleRect.insetBy(dx: -reach, dy: -reach))
        guard context.drawsSkeletons else {
            cg.setLineWidth(width)
            cg.setLineJoin(.round)
            for record in shapes {
                guard record.id != editing, let worst = results[record.id]?.worst, let geometry = context.shapes.geometry(of: record.id) else { continue }
                let ring = engine.rings.ring(of: record, geometry: geometry, in: context.shapes, standoff: context.editor.outlineGap,
                                             outset: context.tintedOutset(of: record.id))
                // Where the shape is drawn, so the outline moves with a shaking shape.
                let offset = context.worldDrawingOffset(of: record.id)
                var shift = CGAffineTransform(translationX: offset.x, y: offset.y)
                cg.addPath(offset == .zero ? ring : ring.copy(using: &shift) ?? ring)
                cg.setStrokeColor(worst.color.cgColor)
                cg.strokePath()
            }
            return
        }
        // A run of one color at a time, so a front shape's ring is still over a back one's of the
        // other color.
        var run: (severity: Severity, path: CGMutablePath)?
        for record in shapes {
            guard record.id != editing, let worst = results[record.id]?.worst, let bounds = context.shapes.geometry(of: record.id)?.bounds else { continue }
            let offset = context.worldDrawingOffset(of: record.id)
            let away = pad + context.tintedOutset(of: record.id) / zoom
            let outline = bounds.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -away, dy: -away)
            if let filled = run, filled.severity != worst {
                Self.fill(filled.path, in: filled.severity.color, on: cg)
                run = nil
            }
            let path = run?.path ?? CGMutablePath()
            // The line's outer edge, and its inner one wound the other way (mirrored), so rings that
            // meet fill as their union.
            let inner = outline.insetBy(dx: width / 2, dy: width / 2)
            path.addRect(outline.insetBy(dx: -width / 2, dy: -width / 2))
            path.addRect(inner, transform: CGAffineTransform(translationX: 2 * inner.midX, y: 0).scaledBy(x: -1, y: 1))
            run = (worst, path)
        }
        if let run { Self.fill(run.path, in: run.severity.color, on: cg) }
    }

    private static func fill(_ path: CGPath, in color: NSColor, on cg: CGContext) {
        cg.addPath(path)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
    }
}

/// The line the overlay strokes around each shape with issues: the shape's outline as the core
/// strokes a selection (`registry.indicatorPath(of:in:)`), grown by the padding and, for a closed
/// shape, by the standoff the selection's outline has (`CanvasEditor.outlineGap`) and the rings of
/// tinted outlines round it (`OverlayContext.tintedOutset(of:)`), so a card's ring follows its
/// rounded corners and an arrow's its line, and a selected shape's accent line is never under its
/// ring, nor a lit shape's tint; a rounded rect around the bounds, grown the same, for a shape small
/// on screen. Growing an outline takes path arithmetic, so each shape's ring is kept until the shape
/// or its outline changes, or the zoom by more than a tenth (the padding is view points:
/// `ValidationStyle.ringZoomTolerance`), or the standoff, or the tinted rings, and dropped once the
/// shape has no issues.
@MainActor
final class ValidationRings {
    private struct Ring {
        let record: AnyShapeRecord
        let outline: [CGPoint]
        let zoom: CGFloat
        let standoff: CGFloat
        let outset: CGFloat
        let path: CGPath
    }

    private var rings: [ShapeID: Ring] = [:]
    /// How many rings it has grown, debug builds: a test holds a frame drawn again to none.
    #if DEBUG
    private(set) var grown = 0
    #endif

    /// The ring around `record`, in world units, where it is. `standoff` is how far (view points) the
    /// selection's outline stands off a closed shape's edge (`CanvasEditor.outlineGap`): the ring is
    /// its padding outside that, so a closed shape's is grown by both, and by `outset`, how far
    /// (view points) the tinted rings round it reach beyond where the selection's line stands.
    func ring(of record: AnyShapeRecord, geometry: ShapeGeometry, in shapes: ShapeContext, standoff: CGFloat, outset: CGFloat) -> CGPath {
        let zoom = shapes.zoom
        if let ring = rings[record.id], ring.standoff == standoff, ring.outset == outset,
           abs(zoom / ring.zoom - 1) < ValidationStyle.ringZoomTolerance, ring.outline == geometry.outline, ring.record == record {
            return ring.path
        }
        let lift = geometry.isClosed ? standoff : 0
        let pad = (lift + ValidationStyle.padding + outset) / zoom
        let bounds = geometry.bounds
        let path: CGPath
        if min(bounds.width, bounds.height) * zoom >= ValidationStyle.outlineMinSide,
           let outline = shapes.registry.indicatorPath(of: record, in: shapes), !outline.isEmpty {
            // Everything within the padding of the outline (and of what it stands off by), and inside
            // it for a closed shape: its edge is the outline grown by that.
            path = outline.grownOutward(by: pad, isClosed: geometry.isClosed)
            #if DEBUG
            grown += 1
            #endif
        } else {
            let reach = bounds.insetBy(dx: -pad, dy: -pad)
            let radius = min((ValidationStyle.cornerRadius + lift + outset) / zoom, reach.width / 2, reach.height / 2)
            path = CGPath(roundedRect: reach, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        rings[record.id] = Ring(record: record, outline: geometry.outline, zoom: zoom, standoff: standoff, outset: outset, path: path)
        return path
    }

    /// Drops the rings of shapes that no longer have issues (or are gone).
    func forget(allBut results: [ShapeID: ValidationResult]) {
        for id in rings.keys.filter({ results[$0] == nil }) { rings[id] = nil }
    }

    var count: Int { rings.count }
}

/// Where a shape breaks its kind's schema (`Registry.schemaViolations(of:)`): a warning for each
/// place, about the property it's in. Typed props always have their schema's shape, so what a shape
/// can break are the bounds its properties declare (a title's `maxLength`, an estimate's `minimum`)
/// and a number that isn't finite. Warnings, not errors: the shape still works, and saves.
@MainActor
func schemaIssues(of shape: AnyShapeRecord, in context: ValidationContext) -> [ValidationIssue] {
    context.schemaVerdicts.issues(of: shape, in: context.registry)
}

/// The schema rule's issues for each shape, kept until a commit changes the shape in any way but
/// moving it (`ChangeSet.moved`): checking a shape against its kind's schema costs microseconds,
/// while where a shape is is nothing its schema checks. A box is the core's rect in every kind's
/// schema, and moving one keeps it as finite as it was (a transaction refuses a box that isn't). So
/// the rule ignores moves (a drag, which commits every shape it drags on every event, doesn't run
/// it), and a shape checked again because a shape its rules looked up changed keeps its own.
@MainActor
final class SchemaVerdicts {
    private var verdicts: [ShapeID: [ValidationIssue]] = [:]

    func issues(of shape: AnyShapeRecord, in registry: Registry) -> [ValidationIssue] {
        if let issues = verdicts[shape.id] { return issues }
        let issues = registry.schemaViolations(of: shape).map { ValidationIssue.warning($0.message, field: $0.property) }
        verdicts[shape.id] = issues
        return issues
    }

    /// Drops the verdict of each shape the commit added, removed, or changed but by moving it, and
    /// of those it touched on other boards (kept by id, verdicts outlive a switch; a board taken back
    /// as it was left keeps its shapes', and one checked afresh forgets them all).
    func documentDidChange(_ changes: ChangeSet) {
        for id in changes.elsewhere { verdicts[id] = nil }
        for id in changes.added { verdicts[id] = nil }
        for id in changes.removed { verdicts[id] = nil }
        for id in changes.changed where !changes.moved.contains(id) { verdicts[id] = nil }
    }

    func forgetAll() { verdicts = [:] }
}

/// Validation, as a plugin: any plugin gives any kind rules (`x.validate { ... }`), each finding
/// errors or warnings on a shape, and every shape is checked against its kind's schema, each place it
/// breaks it a warning; the engine keeps every shape's issues, and the overlay outlines the shapes
/// that have any. They also show in the detail panel's Issues tab (`ValidationDetailsPlugin`) and
/// as a dot on a shape's row in the table of contents (`ValidationContentsPlugin`), plugins of
/// their own in this module.
public struct ValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .validation }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ValidationEngine(editor: $0) }
        registrar.overlay(ValidationOverlay())
        registrar.validateEveryShape(ignoringMoves: true, schemaIssues)
    }
}
