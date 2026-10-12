import AppKit
import ProseMaps

/// Types' look and words. Fixed colors: a highlight is the same in both appearances, as every
/// shape's body is. Declared in the lowest part that draws, and each part above adds its own
/// constants in an extension, in its own files.
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
