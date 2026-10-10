import AppKit
import Canvas
import DetailPanel
import ProseMaps
import Selection
import Titles
import Topology
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
/// (`SchemaReferences`). `/is-a type` makes a shape one, and Remove Type
/// (`removeType`) one no longer. The file's types are `editor.types` (`TypeIndex`). Its rules
/// (`TypeValidationPlugin`) and its panel (`TypeDetailsPlugin`) are plugin values of their own, so a
/// list without Validation or the panel can install Types. It knows no kind: a kind hands it its
/// words (`typeWords`).
public struct TypesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .types }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TypeSchemaProperty.self)
        // What a shape is: the types it names (`typeable()` kinds), and the edge each is; and the values it
        // holds for their fields.
        registrar.declare(IsAProperty.self)
        registrar.declare(FieldValuesProperty.self)
        registrar.edgeType(IsAEdge.self)
        registrar.edges(in: IsAProperty.self, as: IsAEdge.self)
        // The index first: the sync and what reads types hear each commit after it.
        registrar.service { TypeIndex(editor: $0) }
        // What the types of a list give, resolved once and kept; it reads nothing as it is made.
        registrar.service { FieldBook(editor: $0) }
        registrar.service { TypeSync<TypeSchemaProperty>(editor: $0) }
        // What changes a shape's field values (one writer for every surface), what is said of them (the check),
        // and the card a row with more in it opens.
        registrar.service { FieldWriter(editor: $0) }
        registrar.service { FieldChecks(editor: $0) }
        registrar.service { FieldCards(editor: $0) }
        // Resting the pointer on a highlight's words shows the part of the schema they say; in the
        // editor, its own view asks (`TypeIndex.popover(at:on:)`).
        registrar.shapePopovers { editor, record, point in
            guard editor.editingShapeID != record.id else { return nil }
            return TypeHighlights.popover(at: point, on: record, in: editor)
        }
        registerIsACommand(into: &registrar)
        registerTypeMenus(into: &registrar)
        registerTypeChips(into: &registrar)
        // A type's pill is its title in its color, after the mark of a type; untitled, gray and dimmed.
        // Asked of the kinds that hold a schema, a note's, and a plain note's pill is as it was.
        registrar.titlePillLook(forShapesHolding: TypeSchemaProperty.self) { record, title in
            guard record[TypeSchemaProperty.self] != nil else { return nil }
            return TitlePillLook(symbol: TypesStyle.typeSymbol, tint: title == nil ? nil : TypeColors.solid(record.id),
                                 placeholder: TypesStyle.untitledType)
        }
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
        // Only the schema's text matters, never where the shape is: a drag of a thousand notes
        // checks none of them again for this.
        registrar.validateEveryShape(ignoringMoves: true) { shape, _ in SchemaReadings.reading(of: shape)?.issues ?? [] }
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
    /// The step `/is-a` takes, and what the chips' and the panel's Remove take back with Remove Type's.
    public static let addType = "Add Type"
    /// The step a new type is made in: the note and the link.
    public static let newType = "New Type"
    /// The row offered for what was typed, last: `New type “Company”`.
    static func newTypeRow(_ name: String) -> String { "New type “\(name)”" }
    /// What `/is-a` takes, beside its name in the list.
    static let isAArgument = "type"
    /// `/is-a`'s rows: `Type`, which makes the shape one, and the mark each has.
    static let typeChoice = "Type"
    static let typeSymbol = "curlybraces"
    /// The chips: what a type that has no title, or is gone and was never known by one, is called.
    static let untitledType = "Untitled"
    static let deletedType = "Deleted"
    /// A chip's menu: `Go to “Person”`, `Remove “Person”`, as a mention's pill's menu says it.
    static func goTo(_ name: String) -> String { "Go to “\(name)”" }
    static func remove(_ name: String) -> String { "Remove “\(name)”" }
    /// How a type is named in those: its title, else what an untitled or gone one is called.
    static func menuName(_ name: TypeLinkName) -> String {
        switch name {
        case .live(let title): title ?? untitledType
        case .missing(let lastKnown): lastKnown ?? deletedType
        }
    }
    /// A type's color is one of these eight, by its id (`TypeColors`): hues spread round the wheel,
    /// none red (red is the invalid ring and the wrong value). `base` is the pill's, with white text
    /// on it at 4.5:1 or more, and the same in both appearances; `lightInk` and `darkInk` are the
    /// color's ink on a chip, over its own 14% tint on the light canvas and on the dark, 4.5:1 or
    /// more each (TypeColorsTests holds all of it).
    public typealias RGB = (CGFloat, CGFloat, CGFloat)
    public static let colorTable: [(base: RGB, lightInk: RGB, darkInk: RGB)] = [
        (base: (0.172, 0.447, 0.860), lightInk: (0.145, 0.377, 0.725), darkInk: (0.450, 0.670, 1.000)),   // blue
        (base: (0.695, 0.373, 0.139), lightInk: (0.585, 0.314, 0.117), darkInk: (1.000, 0.681, 0.450)),   // orange
        (base: (0.669, 0.220, 0.880), lightInk: (0.570, 0.187, 0.750), darkInk: (0.824, 0.450, 1.000)),   // purple
        (base: (0.105, 0.525, 0.223), lightInk: (0.089, 0.445, 0.189), darkInk: (0.450, 1.000, 0.604)),   // green
        (base: (0.102, 0.510, 0.510), lightInk: (0.086, 0.430, 0.430), darkInk: (0.450, 1.000, 1.000)),   // teal
        (base: (0.830, 0.166, 0.564), lightInk: (0.690, 0.138, 0.469), darkInk: (1.000, 0.450, 0.780)),   // magenta
        (base: (0.565, 0.438, 0.113), lightInk: (0.480, 0.372, 0.096), darkInk: (1.000, 0.846, 0.450)),   // gold
        (base: (0.313, 0.264, 0.880), lightInk: (0.313, 0.264, 0.880), darkInk: (0.586, 0.550, 1.000)),   // indigo
    ]
    /// `Type` and an untitled type in `/is-a`'s list: no color of their own.
    public static let grayChip = NSColor(white: 0.40, alpha: 1)
    /// The panel's Types rows.
    static let typeRowSymbol = "tag"
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
