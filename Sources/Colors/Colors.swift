import AppKit
import Canvas
import Palette

/// Colors, as a plugin: a shape of a kind that opted in has a color, one of the named colors or any
/// hex value, and its kind draws it. Loosely tldraw's colors: a set of named colors, each drawn in
/// roles that suit a line, a surface, text and a sheet of paper on the light canvas and the dark
/// (Palette's `Swatch`); a file may add named colors of its own. A color is something the shape
/// knows, an added property, `color`, on the kinds that opt in (`colorable`); a shape with none set
/// looks as its kind says (`colorable(default:)`, or the kind's own look with no default).
///
/// What a kind does with its color is the kind's: it reads the roles in its render
/// (`context.colors(of:)`) and draws the one that suits each part. Where a color is picked (the
/// panel's row, `/color`, Color ▸) and what `canvas draw` and `canvas query` say of it are here.
extension PluginID {
    public static let colors: PluginID = "colors"
}

/// The color a shape holds (`ShapeColor`): nothing on a shape that has none of its own, which then
/// looks as its kind says.
public enum ColorProperty {}

extension ColorProperty: ShapeProperty {
    public static let key: PropertyKey = "color"
    public static var defaultValue: ShapeColor? { nil }
    public static var keywords: PropertyKeywords<ShapeColor> {
        PropertyKeywords().description("The shape's color: a named color, or a value as #RRGGBB.").examples(.blue, .value(RGB(hex: 0x4465E9)))
    }
    public static func isNone(_ color: ShapeColor) -> Bool { color.name?.isEmpty == true }
}

/// What a kind's shapes look like with no color of their own (`ColorDefault`), one per kind that
/// has colors.
public enum ColorDefaults {}

extension ColorDefaults: KeyedExtensionPoint {
    public typealias Contribution = ColorDefault
    public static var owner: PluginID { .colors }
    public static func uniqueKeys(of _: ColorDefault, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of contribution: ColorDefault, for target: ShapeTarget) -> String {
        "colorable" + (contribution.color.map { " (\($0.text))" } ?? "") + " → \(target)"
    }

    /// A kind's default is a color every file has: a built-in name or a value, never a file's own.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for kind in registry.kinds {
            guard let color = registry.contributions(to: ColorDefaults.self, for: kind).first?.color else { continue }
            if let name = color.name, BuiltInColors.named(name) == nil {
                throw .invalid(point: "ColorDefaults", reason: "\(kind)'s default color, \(name), isn't a built-in color")
            }
        }
    }
}

/// One kind's default: only the sugar makes one.
public struct ColorDefault: Sendable {
    /// What a shape of the kind with no color of its own is drawn in; nil for the kind's own look.
    public var color: ShapeColor?
}

extension ShapeRegistrar {
    /// This kind's shapes have a color: each holds one (`ColorProperty`, nil until it's set), the
    /// panel has its row, its text takes `/color` and its menu Color ▸. A shape with none is drawn
    /// in `default` (a built-in name or a value), or, with no default, as the kind looks on its own:
    /// `note.colorable(default: .yellow)`, `frame.colorable()`. The kind draws it: its render and
    /// its skeleton read `context.colors(of: shape)`.
    public mutating func colorable(default color: ShapeColor? = nil) {
        optIn(to: ColorProperty.self)
        contribute(ColorDefault(color: color), to: ColorDefaults.self)
    }
}

extension PluginRegistrar {
    /// Gives another plugin's kind a color, as `colorable(default:)` does a plugin's own.
    public mutating func colorable<P: ShapeProps>(_: P.Type, default color: ShapeColor? = nil) {
        optIn(P.self, to: ColorProperty.self)
        contribute(ColorDefault(color: color), to: ColorDefaults.self, for: .kind(P.kind))
    }
}

extension Registry {
    /// Whether a kind's shapes have a color (it called `colorable`).
    public func isColorable(_ kind: ShapeKind) -> Bool {
        memo(ColorableKey(kind: kind)) { properties(for: kind).contains(ColorProperty.key) }
    }

    /// What a kind's shapes are drawn in with no color of their own; nil for a kind with no default,
    /// and one with no colors.
    public func defaultColor(of kind: ShapeKind) -> ShapeColor? {
        memo(DefaultColorKey(kind: kind)) { contributions(to: ColorDefaults.self, for: kind).first?.color }
    }
}

private struct ColorableKey: Hashable { let kind: ShapeKind }
private struct DefaultColorKey: Hashable { let kind: ShapeKind }

extension AnyShapeRecord {
    /// The color the shape itself holds (`ColorProperty`), if any: not its kind's default.
    public var ownColor: ShapeColor? { self[ColorProperty.self] }
}

/// Colors' words and constants.
@MainActor
public enum ColorsStyle {
    /// The undo step of a change of color.
    public static let changeColor = "Change Color"
    /// The undo steps of a file's own colors: adding one, giving one another value, renaming one
    /// (and every shape that holds it), removing one (and what it leaves its shapes).
    public static let addColor = "Add Color"
    public static let changeColorValue = "Change Color"
    public static let renameColor = "Rename Color"
    public static let removeColor = "Remove Color"
    /// The longest a name of the file's color is, in characters. Read where a file is read, off the
    /// main actor.
    public nonisolated static let maxNameLength = 40
    /// What clears a shape's color, in every list.
    public static let none = "None"
    /// The panel's row, the menu and the command's argument.
    public static let color = "Color"
    /// What `/color` takes, in its list's hint.
    public static let colorArgument = "color"
    /// The system picker's row in the panel's grid.
    public static let other = "Other…"
}

/// The plugin: the property, the book that says what every color looks like (`editor.colors`), and
/// the two ways to pick one that need no panel, `/color` in a shape's text and Color ▸ in its menu.
/// A list with it needs `SlashCommandsPlugin` and `ContextMenusPlugin` (the registry refuses a
/// contribution whose owner isn't installed), as a list with Locking does. The panel's row is
/// `ColorDetailsPlugin`, the warning for a name the file lacks `ColorValidationPlugin`, and the
/// words draw and queries take `ColorNamesPlugin` and `ColorQueriesPlugin`, each a plugin value of
/// its own, so a list without its surface leaves it out.
public struct ColorsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .colors }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(ColorProperty.self)
        registrar.declare(file: FileColorsProperty.self)
        registrar.service { editor in
            let book = ColorBook(editor: editor)
            book.tellTintsOfChanges(in: editor)
            return book
        }
        registerColorTints(into: &registrar)
        // `/color` and Color ▸ go on the kinds that have colors, and no other.
        registrar.forShapes(holding: ColorProperty.self) { colored in
            registerColorCommand(into: &colored)
            registerColorMenu(into: &colored)
        }
    }
}
