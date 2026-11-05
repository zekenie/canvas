import Adornments
import AppKit
import Canvas
import Colors
import Palette

extension PluginID {
    public static let typeColors: PluginID = "type-colors"
}

/// Types' color for Colors: a shape of a type that holds no color of its own is drawn in its type's color
/// (`TypeIndex.color(inheritedBy:)`, through Colors' `InheritedColors`), the one its type's pill shows,
/// wherever its color shows: a note's paper, a relationship's line, a typed subboard's card (in place of its
/// indigo) or a typed frame's border and surface, its symbol in a list, the panel's row.
/// A color set on a type comes first, the nearest up its chain; with none set, the one its type's id says.
/// A type that holds none is given the one its id says, as its pill is, and takes nothing from the types
/// it is built on. A plugin value of its own, after Colors and Types, so a list without Colors leaves it out.
public struct TypeColorsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .typeColors }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(holding: IsAProperty.self) { typeable in
            typeable.inheritedColor { id, editor in editor.types?.color(inheritedBy: id) }
        }
    }
}

/// A type's color: the color its shape holds (`record.ownColor`, Colors') where the file has it, else
/// one of eight built-in names worked out from its id, so two types can share one. The same
/// everywhere the type shows (`TypeLook`): its pill is solid in it, the chips of the shapes that
/// are it are light in it, a row of `/is-a`'s list is a capsule in it. Without `ColorsPlugin`
/// a type's color is always the one its id says. It is its shapes' too (notes, arrows, subboards, frames), where
/// they hold none of their own (`TypeColorsPlugin`).
@MainActor
public enum TypeColors {
    /// The eight a type's id chooses among, in the order of the index: never gray, which reads as no
    /// color, nor red, which reads as wrong.
    public static let names: [ShapeColor] = builtIns.map(\.color)

    private static let builtIns: [NamedColor] = [
        BuiltInColors.orange, BuiltInColors.yellow, BuiltInColors.green, BuiltInColors.teal,
        BuiltInColors.blue, BuiltInColors.indigo, BuiltInColors.purple, BuiltInColors.pink,
    ]

    /// Which of the eight a type's id says: the first eight bytes of its UUID, each summed with its
    /// position, modulo eight. Never `hashValue`, which changes with the process.
    public static func index(of id: ShapeID) -> Int {
        let bytes = id.rawValue.uuid
        let first = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
        return first.enumerated().reduce(0) { $0 + Int($1.element) + $1.offset } % builtIns.count
    }

    /// The color a type's id says, whatever its shape holds.
    public static func name(of id: ShapeID) -> ShapeColor { names[index(of: id)] }

    /// What has no color of its own: `Type`, and a type that is untitled.
    public static let gray = AdornmentTint(TypesStyle.grayChip, style: .solid)

    /// A type's color as it is drawn: `own`, the color its shape holds, where `book` has it, else the
    /// one its id says.
    static func look(of id: ShapeID, own: ShapeColor?, book: ColorBook?) -> TypeLook {
        if let own, let swatch = book?.swatch(for: own) { return look(of: swatch) }
        return builtInLooks[index(of: id)]
    }

    private static let builtInLooks: [TypeLook] = builtIns.map { look(of: $0.swatch) }

    /// How many looks are kept before the lot is let go: a color picked by dragging makes one a value.
    private static let capacity = 512
    private static var kept: [Swatch: TypeLook] = [:]

    /// The look of a swatch, made once and kept: Adornments keeps its fills by tint, and a tint is
    /// equal to another only if it is made of the same colors.
    private static func look(of swatch: Swatch) -> TypeLook {
        if let known = kept[swatch] { return known }
        let made = TypeLook(swatch)
        if kept.count >= capacity { kept.removeAll(keepingCapacity: true) }
        kept[swatch] = made
        return made
    }
}

/// How a type's color is drawn, from the roles of its swatch (Palette's): all of it follows the
/// appearance, but for the tick, which is drawn on a note's paper.
public struct TypeLook {
    /// The roles the color is drawn in.
    public let swatch: Swatch
    /// The type's pill: its `solid`, with its `onSolid` text (white on most, black on yellow and orange).
    public let solid: AdornmentTint
    /// The type's chip: its `solid` faint, with a line of it, its title in the color's `ink`.
    public let light: AdornmentTint
    /// The color alone: a row of `/is-a`'s list, and what its title is drawn in there.
    public let row: NSColor
    public let rowInk: NSColor
    /// The mark at the left of a note's row that a type gave: its `solid` in the light appearance,
    /// since a note's paper is light in both.
    public let tick: NSColor

    init(_ swatch: Swatch) {
        self.swatch = swatch
        row = NSColor(swatch.solid)
        rowInk = NSColor(swatch.onSolid)
        solid = AdornmentTint(row, ink: rowInk, style: .solid)
        light = AdornmentTint(row, ink: NSColor(swatch.ink), style: .light)
        tick = NSColor(swatch.solid.light)
    }
}
