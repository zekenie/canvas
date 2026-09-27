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
    let document: CanvasDocument
    let registry: Registry
    let lookups: Lookups

    public func shape(_ id: ShapeID) -> AnyShapeRecord? {
        lookups.ids.insert(id)
        return document[id]
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
@MainActor
public final class ValidationEngine {
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
        guard let ids = unchecked else {
            cache = [:]
            lookups = [:]
            lookedUpBy = [:]
            for shape in document.shapes { check(shape, in: document) }
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
                check(shape, in: document)
            } else {
                cache[id] = nil
            }
        }
    }

    private func check(_ shape: AnyShapeRecord, in document: CanvasDocument) {
        // Shapes the board keeps aside aren't the app's to judge.
        guard !shape.isOpaque else {
            cache[shape.id] = nil
            return
        }
        let context = ValidationContext(document: document, registry: editor.registry, lookups: Lookups())
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
        heardRevision = editor.revision
        guard unchecked != nil else { return }             // every shape is unchecked already
        for id in changes.shapeIDs {
            unchecked!.insert(id)
            unchecked!.formUnion(lookedUpBy[id] ?? [])
        }
    }
}

extension CanvasEditor {
    public var validation: ValidationEngine? { service(ValidationEngine.self) }
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
    context.registry.schemaViolations(of: shape).map { .warning($0.message, field: $0.property) }
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
