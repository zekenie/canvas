import AppKit
import Canvas

extension PluginID {
    public static let validation: PluginID = "validation"
}

public enum Severity: Int, Comparable, Sendable {
    case info, warning, error
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
    public static func warning(_ message: String, field: String? = nil) -> ValidationIssue { ValidationIssue(message, severity: .warning, field: field) }
    public static func info(_ message: String, field: String? = nil) -> ValidationIssue { ValidationIssue(message, severity: .info, field: field) }
}

public struct ValidationResult: Equatable, Sendable {
    public var issues: [ValidationIssue]
    public init(issues: [ValidationIssue]) { self.issues = issues }
    /// Derived, never stored: valid means no error-severity issue.
    public var isValid: Bool { !issues.contains { $0.severity == .error } }
    public var worst: Severity? { issues.map(\.severity).max() }
}

/// Rules' only way into the document, so dependency tracking can replace full recomputation
/// later without changing any rule. Add lookups here as rules need them.
@MainActor
public struct ValidationContext {
    let document: CanvasDocument
    public func shape(_ id: ShapeID) -> AnyShapeRecord? { document[id] }
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

/// Every shape's issues, recomputed on the first read after the document changes.
@MainActor
public final class ValidationEngine {
    private unowned let editor: CanvasEditor
    private var checkedRevision = -1
    private var cache: [ShapeID: ValidationResult] = [:]

    init(editor: CanvasEditor) { self.editor = editor }

    /// Only shapes with at least one issue.
    public var results: [ShapeID: ValidationResult] {
        refreshIfNeeded()
        return cache
    }

    public func result(for id: ShapeID) -> ValidationResult? { results[id] }

    private func refreshIfNeeded() {
        guard checkedRevision != editor.revision else { return }
        let context = ValidationContext(document: editor.document)
        var fresh: [ShapeID: ValidationResult] = [:]
        // Shapes the board keeps aside aren't the app's to judge.
        for shape in editor.document.shapes where !shape.isOpaque {
            let issues = editor.registry.contributions(to: ValidationRules.self, for: shape.kind).flatMap { $0.check(shape, context) }
            if !issues.isEmpty { fresh[shape.id] = ValidationResult(issues: issues) }
        }
        cache = fresh
        checkedRevision = editor.revision
    }
}

extension ValidationEngine: EditorService {}

extension CanvasEditor {
    public var validation: ValidationEngine? { service(ValidationEngine.self) }
}

@MainActor
enum ValidationStyle {
    static let error = NSColor.systemRed
    static let warning = NSColor.systemOrange
    static let info = NSColor.systemBlue
    // View points.
    static let padding: CGFloat = 3
    static let lineWidth: CGFloat = 2
    static let cornerRadius: CGFloat = 4
}

/// The horizontal draws its own decoration; shapes never know they're invalid.
struct ValidationOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }
    func draw(in context: OverlayContext) {
        guard let results = context.editor.validation?.results, !results.isEmpty else { return }
        let zoom = context.zoom
        // In paint order, so overlapping outlines stack the same way every time.
        for record in context.editor.paintOrder() {
            guard let worst = results[record.id]?.worst, let bounds = context.shapes.geometry(of: record.id)?.bounds else { continue }
            let pad = ValidationStyle.padding / zoom, radius = ValidationStyle.cornerRadius / zoom
            context.cg.addPath(CGPath(roundedRect: bounds.insetBy(dx: -pad, dy: -pad), cornerWidth: radius, cornerHeight: radius, transform: nil))
            let color = switch worst {
            case .error: ValidationStyle.error
            case .warning: ValidationStyle.warning
            case .info: ValidationStyle.info
            }
            context.cg.setStrokeColor(color.cgColor)
            context.cg.setLineWidth(ValidationStyle.lineWidth / zoom)
            context.cg.strokePath()
        }
    }
}

public struct ValidationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .validation }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { ValidationEngine(editor: $0) }
        registrar.overlay(ValidationOverlay())
    }
}
