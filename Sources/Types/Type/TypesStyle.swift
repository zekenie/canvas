import AppKit
import ProseMaps

/// Types' look and words. A type's color is Colors' (`TypeColors`). Fixed colors: a highlight is the
/// same in both appearances, as every shape's body is. Declared in the lowest part that draws, and each part above adds its own
/// constants in an extension, in its own files.
@MainActor
public enum TypesStyle {
    /// The steps.
    public static let makeType = "Make Type"
    public static let removeType = "Remove Type"
    /// The mark by hand: a relationship type made, and taken back to the plain type it still is.
    public static let makeRelationshipType = "Make Relationship Type"
    public static let makePlainType = "Make Plain Type"
    /// The step `/is-a` takes, and what the chips' and the panel's Remove take back with Remove Type's.
    public static let addType = "Add Type"
    /// The step a new type is made in: the note and the link.
    public static let newType = "New Type"
    /// The same, for an arrow's label: the new type is a relationship type.
    public static let newRelationshipType = "New Relationship Type"
    /// The row offered for what was typed, last: `New type “Company”`.
    static func newTypeRow(_ name: String) -> String { "New type “\(name)”" }
    /// What `/is-a` takes, beside its name in the list.
    static let isAArgument = "type"
    /// `/is-a`'s rows: `Type`, which makes the shape one, and the mark each has.
    static let typeChoice = "Type"
    static let typeSymbol = "curlybraces"
    /// `Relationship Type`, beside `Type`, and the mark its pill and its rows carry where a type's has braces.
    static let relationshipTypeChoice = "Relationship Type"
    static let relationshipTypeSymbol = "arrow.right"
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
    /// `Type` and an untitled type in `/is-a`'s list: no color of their own.
    public static let grayChip = NSColor(white: 0.40, alpha: 1)
    /// The panel's Types rows, and what a type the shape is through another says beside it: `through Toyota`.
    static let typeRowSymbol = "tag"
    static func through(_ name: String) -> String { "through \(name)" }
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
