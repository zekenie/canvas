import AppKit
import Canvas

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
    public var worst: Severity? { issues.map(\.severity).max() }
    /// Worst first (the errors, then the warnings), each severity in the rules' order: how every list
    /// of them reads.
    public var worstFirst: [ValidationIssue] {
        issues.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// Rules' only way into the document. The engine notes the shapes a rule looks up, and checks the
/// shape again when one of them changes; for a rule that ignores moves, not when one only moves.
/// Add lookups here as rules need them.
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

    public func shape(_ id: ShapeID) -> AnyShapeRecord? {
        if lookups.ignoringMoves { lookups.steady.insert(id) } else { lookups.placed.insert(id) }
        return shapes.shape(id)
    }
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
    public init(ignoringMoves: Bool = false, _ check: @escaping @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]) {
        self.check = check
        ignoresMoves = ignoringMoves
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
    /// what shapes are, never where (`ValidationRule`).
    public mutating func validate(ignoringMoves: Bool = false,
                                  _ rule: @escaping @MainActor (ShapeRecord<Definition.Props>, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(ignoringMoves: ignoringMoves) { record, context in
            record.typed(as: Definition.Props.self).map { rule($0, context) } ?? []
        }, to: ValidationRules.self)
    }
}

extension PluginRegistrar {
    /// A rule for a kind another plugin registers.
    public mutating func validate<P: ShapeProps>(_: P.Type, ignoringMoves: Bool = false,
                                                 _ rule: @escaping @MainActor (ShapeRecord<P>, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(ignoringMoves: ignoringMoves) { record, context in
            record.typed(as: P.self).map { rule($0, context) } ?? []
        }, to: ValidationRules.self, for: .kind(P.kind))
    }

    /// A rule for every kind.
    public mutating func validateEveryShape(ignoringMoves: Bool = false,
                                            _ rule: @escaping @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(ignoringMoves: ignoringMoves, rule), to: ValidationRules.self, for: .any)
    }
}

/// Every shape's issues: on the first read, every shape's; after that, on the first read after a
/// change, only those of the shapes it touched and of the shapes whose rules looked one of them up.
/// A commit that only moves shapes runs none of the rules that ignore moves again (the schema
/// rule is one): it checks the shapes it moved, and those whose other rules looked one of them up,
/// with those other rules alone, each keeping what the rest found. It checks the board shown; what
/// it found on the boards shown last is kept for going back to them, and taken back while those
/// boards are as they were left (`BoardStash`).
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

    /// The shapes whose rules looked one of `ids` up when they were last checked: those a change to
    /// it may check again, besides itself. For a plugin that keeps what it shows of each shape's
    /// issues and redoes it for what each commit changed (ValidationContents' marks).
    public func dependents(of ids: Set<ShapeID>) -> Set<ShapeID> {
        guard let board else { return [] }
        return ids.reduce(into: []) { found, id in
            found.formUnion(board.steadyLookups.by[id] ?? [])
            found.formUnion(board.placedLookups.by[id] ?? [])
        }
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
        let context = ValidationContext(shapes: shapes, registry: shapes.registry, schemaVerdicts: schemaVerdicts, lookups: lookups)
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
        guard board != nil else { return }                 // every shape is unchecked already
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
    public func validationIssues(of record: AnyShapeRecord, in shapes: ShapeContext) -> [ValidationIssue] {
        guard !record.isOpaque else { return [] }
        // Verdicts of its own: the engine's are kept by id, for shapes as the board has them.
        let context = ValidationContext(shapes: shapes, registry: self, schemaVerdicts: SchemaVerdicts(), lookups: Lookups())
        return contributions(to: ValidationRules.self, for: record.kind).flatMap { $0.check(record, context) }
    }
}

extension Severity {
    /// What the outline is drawn in, for a bridge that shows the severity elsewhere to match.
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
    static let padding: CGFloat = 3
    static let lineWidth: CGFloat = 2
    static let cornerRadius: CGFloat = 4
}

/// The horizontal draws its own decoration; shapes never know they're invalid. A shape is outlined
/// in its worst issue's color: red with an error, orange with only warnings, not at all without.
struct ValidationOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        guard let results = context.editor.validation?.results, !results.isEmpty else { return }
        let zoom = context.zoom
        let pad = ValidationStyle.padding / zoom, radius = ValidationStyle.cornerRadius / zoom
        // In paint order, so overlapping outlines stack the same way every time; only shapes whose
        // outline can reach the view.
        let reach = pad + ValidationStyle.lineWidth / zoom
        for record in context.editor.paintOrder(in: context.visibleRect.insetBy(dx: -reach, dy: -reach)) {
            guard let worst = results[record.id]?.worst, let bounds = context.shapes.geometry(of: record.id)?.bounds else { continue }
            // Where the shape is drawn, so the outline moves with a shaking shape.
            let offset = context.worldDrawingOffset(of: record.id)
            let outline = bounds.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -pad, dy: -pad)
            context.cg.addPath(CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.cg.setStrokeColor(worst.color.cgColor)
            context.cg.setLineWidth(ValidationStyle.lineWidth / zoom)
            context.cg.strokePath()
        }
    }
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
/// that have any. Where else they show is for bridges: the detail panel's Issues tab
/// (ValidationDetails), a dot on a shape's row in the table of contents (ValidationContents).
public struct ValidationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .validation }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ValidationEngine(editor: $0) }
        registrar.overlay(ValidationOverlay())
        registrar.validateEveryShape(ignoringMoves: true, schemaIssues)
    }
}
