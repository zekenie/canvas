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
/// shape again when one of them changes. Add lookups here as rules need them.
@MainActor
public struct ValidationContext {
    /// The shapes rules see: the engine's, the editor's document; `validationIssues(of:in:)`'s,
    /// whatever it's given (a transaction's, mid-way).
    let shapes: ShapeContext
    let registry: Registry
    /// Validation's own rule's: each shape's schema issues, kept from one check to the next.
    let schemaVerdicts: SchemaVerdicts
    let lookups: Lookups

    public func shape(_ id: ShapeID) -> AnyShapeRecord? {
        lookups.ids.insert(id)
        return shapes.shape(id)
    }
}

/// The shapes a shape's rules looked up while it was checked.
@MainActor
final class Lookups {
    var ids: Set<ShapeID> = []
}

public struct ValidationRule {
    let check: @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]
    public init(_ check: @escaping @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]) {
        self.check = check
    }
}

/// Validation's extension point: this plugin declares it, any plugin contributes, the core never
/// sees what it means.
public enum ValidationRules: ExtensionPoint {
    public typealias Contribution = ValidationRule
    public static var owner: PluginID { .validation }
}

extension ShapeRegistrar {
    /// A rule for this kind, with its props typed.
    public mutating func validate(_ rule: @escaping @MainActor (ShapeRecord<Definition.Props>, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule { record, context in
            record.typed(as: Definition.Props.self).map { rule($0, context) } ?? []
        }, to: ValidationRules.self)
    }
}

extension PluginRegistrar {
    /// A rule for a kind another plugin registers.
    public mutating func validate<P: ShapeProps>(_: P.Type, _ rule: @escaping @MainActor (ShapeRecord<P>, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule { record, context in
            record.typed(as: P.self).map { rule($0, context) } ?? []
        }, to: ValidationRules.self, for: .kind(P.kind))
    }

    /// A rule for every kind.
    public mutating func validateEveryShape(_ rule: @escaping @MainActor (AnyShapeRecord, ValidationContext) -> [ValidationIssue]) {
        contribute(ValidationRule(rule), to: ValidationRules.self, for: .any)
    }
}

/// Every shape's issues: on the first read, every shape's; after that, on the first read after a
/// change, only those of the shapes it touched and of the shapes whose rules looked one of them up.
/// It checks the board shown; what it found on the boards shown last is kept for going back to
/// them, and taken back while those boards are as they were left (`BoardStash`).
@MainActor
public final class ValidationEngine {
    /// What's kept of a board that isn't shown.
    private struct Kept {
        let cache: [ShapeID: ValidationResult]
        let unchecked: Set<ShapeID>
        let lookups: [ShapeID: Set<ShapeID>]
        let lookedUpBy: [ShapeID: Set<ShapeID>]
    }

    private unowned let editor: CanvasEditor
    /// Each kind's rules, found once: the registry is frozen.
    private var rules: [ShapeKind: [ValidationRule]] = [:]
    /// Only shapes with at least one issue.
    private var cache: [ShapeID: ValidationResult] = [:]
    /// The shapes to check on the next read; nil for every shape.
    private var unchecked: Set<ShapeID>?
    /// The revision `unchecked` is up to date with. Read before this engine has heard of a commit
    /// (by a service that hears first), it checks every shape.
    private var heardRevision: Int
    /// The shapes each shape's rules looked up, and the other way around.
    private var lookups: [ShapeID: Set<ShapeID>] = [:]
    private var lookedUpBy: [ShapeID: Set<ShapeID>] = [:]
    /// What the schema rule found of each shape, so one that only moved isn't checked again.
    private let schemaVerdicts = SchemaVerdicts()
    /// The boards shown last, as they were left.
    private var kept = BoardStash<Kept>()

    init(editor: CanvasEditor) {
        self.editor = editor
        heardRevision = editor.revision
    }

    /// Only shapes with at least one issue.
    public var results: [ShapeID: ValidationResult] {
        refreshIfNeeded()
        return cache
    }

    public func result(for id: ShapeID) -> ValidationResult? { results[id] }

    /// The shapes whose rules looked one of `ids` up when they were last checked: those a change to
    /// it checks again, besides itself. For a plugin that keeps what it shows of each shape's issues
    /// and redoes it for what each commit changed (ValidationContents' marks).
    public func dependents(of ids: Set<ShapeID>) -> Set<ShapeID> {
        ids.reduce(into: []) { found, id in found.formUnion(lookedUpBy[id] ?? []) }
    }

    private func refreshIfNeeded() {
        let document = editor.document
        if heardRevision != editor.revision {
            unchecked = nil
            heardRevision = editor.revision
        }
        // Lookups in the document, and nothing else: rules see shapes only through `shape(_:)`.
        let shapes = ShapeContext(document: document, registry: editor.registry)
        guard let ids = unchecked else {
            cache = [:]
            lookups = [:]
            lookedUpBy = [:]
            schemaVerdicts.forgetAll()
            for shape in document.shapes { check(shape, in: shapes) }
            unchecked = []
            return
        }
        guard !ids.isEmpty else { return }
        unchecked = []
        for id in ids {
            for other in lookups.removeValue(forKey: id) ?? [] {
                lookedUpBy[other]?.remove(id)
                if lookedUpBy[other]?.isEmpty == true { lookedUpBy[other] = nil }
            }
            if let shape = document[id] {
                check(shape, in: shapes)
            } else {
                cache[id] = nil
            }
        }
    }

    private func check(_ shape: AnyShapeRecord, in shapes: ShapeContext) {
        // Shapes the board keeps aside aren't the app's to judge.
        guard !shape.isOpaque else {
            cache[shape.id] = nil
            return
        }
        let context = ValidationContext(shapes: shapes, registry: shapes.registry, schemaVerdicts: schemaVerdicts, lookups: Lookups())
        let issues = rules(for: shape.kind).flatMap { $0.check(shape, context) }
        cache[shape.id] = issues.isEmpty ? nil : ValidationResult(issues: issues)
        guard !context.lookups.ids.isEmpty else { return }
        lookups[shape.id] = context.lookups.ids
        for other in context.lookups.ids { lookedUpBy[other, default: []].insert(shape.id) }
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
        // can be trusted to still hold. The rest catches up when that one is heard.
        if heardRevision < editor.revision - 1 { schemaVerdicts.forgetAll() }
        heardRevision = editor.revision
        schemaVerdicts.documentDidChange(changes)
        guard unchecked != nil else { return }             // every shape is unchecked already
        for id in changes.shapeIDs {
            unchecked!.insert(id)
            unchecked!.formUnion(lookedUpBy[id] ?? [])
        }
    }

    /// Keeps what it found on the board left, if it has checked it, for going back to it.
    public func boardWillChange(from old: BoardID, to new: BoardID, in editor: CanvasEditor) {
        guard old != new, heardRevision == editor.revision, let unchecked else { return }
        kept.keep(Kept(cache: cache, unchecked: unchecked, lookups: lookups, lookedUpBy: lookedUpBy), for: old, in: editor)
    }

    /// Checks the board shown: what it found there, if it's as it was left, and the shapes it hadn't
    /// checked again yet; else every shape, on the next read.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        let taken = kept.take(for: change.to, in: editor)
        cache = taken?.cache ?? [:]
        unchecked = taken?.unchecked
        lookups = taken?.lookups ?? [:]
        lookedUpBy = taken?.lookedUpBy ?? [:]
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
/// moving it (`ChangeSet.moved`): a drag commits every shape it drags on every event, and checking
/// a task card against its schema costs several microseconds, while where a shape is is nothing its
/// schema checks. A box is the core's rect in every kind's schema, and moving one keeps it as finite
/// as it was (a transaction refuses a box that isn't). And a shape checked again because a shape
/// its rules looked up changed keeps its own.
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
        registrar.validateEveryShape(schemaIssues)
    }
}
