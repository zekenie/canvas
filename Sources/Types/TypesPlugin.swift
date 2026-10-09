import AppKit
import Canvas
import DetailPanel
import ProseMaps
import Selection
import Validation

extension PluginID {
    public static let types: PluginID = "types"
}

/// Types, as a plugin: a shape whose kind can be a type (`canBeType()`, a note) is one while it holds
/// a JSON Schema (`TypeSchemaProperty`), named by its title. Its words say what the type holds, and
/// the sync keeps the two saying the same thing through the editor's language model (`TypeSync`);
/// its words are highlighted where they say a part of its schema (a prose map, `SchemaTarget`, which
/// ProseMaps asks for: without `ProseMapsPlugin` there are none), each part shown in a popover on its
/// words; a mention of another type in its words is a `$ref` to that type's schema
/// (`SchemaReferences`). `/type` makes a shape one (public, through Publishing), and Remove Type
/// (`removeType`) one no longer. The file's types are `editor.types` (`TypeIndex`). Its rules
/// (`TypeValidationPlugin`) and its panel (`TypeDetailsPlugin`) are plugin values of their own, so a
/// list without Validation or the panel can install Types. It knows no kind: a kind hands it its
/// words (`typeWords`).
public struct TypesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .types }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TypeSchemaProperty.self)
        // The index first: the sync and what reads types hear each commit after it.
        registrar.service { TypeIndex(editor: $0) }
        registrar.service { TypeSync<TypeSchemaProperty>(editor: $0) }
        // Resting the pointer on a highlight's words shows the part of the schema they say; in the
        // editor, its own view asks (`TypeIndex.popover(at:on:)`).
        registrar.shapePopovers { editor, record, point in
            guard editor.editingShapeID != record.id else { return nil }
            return TypeHighlights.popover(at: point, on: record, in: editor)
        }
        registerTypeCommands(into: &registrar)
    }

    #if DEBUG
    /// How many times a type's schema has been read (parsed) in this process, debug builds only:
    /// tests hold what reads a type to reading only the types whose text changed.
    public static var schemasRead: Int { SchemaReadings.made }
    #endif
}

/// Validation's rules for a type's schema (`SchemaReadings.issues`): not JSON, or not an object, is an
/// error; `required` naming no property, or a `type` that isn't JSON Schema's, a warning. After
/// `TypesPlugin` and `ValidationPlugin`.
public struct TypeValidationPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "type-validation" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.validateEveryShape { shape, _ in SchemaReadings.reading(of: shape)?.issues ?? [] }
    }
}

/// A type's Schema tab in the detail panel: its JSON, its issues and the sync's status. After
/// `TypesPlugin` and `DetailPanelPlugin`.
public struct TypeDetailsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "type-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registerTypePanel(into: &registrar)
    }
}

/// Types' look and words. Fixed colors: a highlight is the same in both appearances, as every
/// shape's body is.
@MainActor
public enum TypesStyle {
    /// The steps.
    public static let makeType = "Make Type"
    public static let removeType = "Remove Type"
    /// Behind the words a highlight links to the schema: a field's pale blue, a rule's pale amber,
    /// light enough on a note's yellow, and on white, that the text stays the text's gray.
    static let fieldHighlight = NSColor(srgbRed: 0.20, green: 0.47, blue: 0.96, alpha: 0.16).cgColor
    static let validationHighlight = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 0.24).cgColor
    static func highlightColor(_ role: LinkRole) -> CGColor {
        switch role {
        case .element: fieldHighlight
        case .rule: validationHighlight
        }
    }
    /// What a highlight fills of a line its words are on (`ProseHighlights.lines`): its words'
    /// width, and the line's height less half a point above and below, so highlights on lines one
    /// under the other stay apart.
    static func highlightFill(_ line: CGRect) -> CGRect { line.insetBy(dx: 0, dy: 0.5) }
    /// The most lines of a part a popover shows; "…" on a line after them says there's more.
    static let popoverMaxLines = 40
}
