import Adornments
import AppKit
import Palette

// The looks of the kit's three kinds at rest, beside the kit's own (`KitStyle`): what each is called and its symbol, the
// size a new one is, its marks, and its skeleton's, a kind's skeleton's beside its full look's.

/// A table's look.
@MainActor
enum TableStyle {
    static let label = "Table"
    static let symbol = "tablecells"
    /// Its row in the table of contents and its panel's header while it has no title.
    static let placeholder = "Untitled Table"
    /// A new table's width.
    static let width: CGFloat = 260
    /// The narrowest it's resized to: a name and a short type.
    static let minimumWidth: CGFloat = 120
    /// What its rows are, said by VoiceOver: "5 columns".
    static func accessibleRows(_ count: Int) -> String { count == 1 ? "1 column" : "\(count.formatted()) columns" }
    /// What VoiceOver calls the field a new table's name is typed in.
    static let titleFieldName = "Table name"
    static let addStep = "Add Table"
    static let renameStep = "Rename Table"
    /// A column's steps, each a commit of its line.
    static let addColumnStep = "Add Column"
    static let pasteColumnsStep = "Paste Columns"
    static let renameColumnStep = "Rename Column"
    static let changeColumnStep = "Change Column"
    static let deleteColumnStep = "Delete Column"
    static let deleteColumnsStep = "Delete Columns"
    static let moveColumnStep = "Move Column"
    /// A line's `→` the only change: a key made, re-aimed, or taken out.
    static let addKeyStep = "Add Key"
    static let changeKeyStep = "Change Key"
    static let deleteKeyStep = "Delete Key"
    /// ⌘L on a table, a table picked: the key column made and its key drawn.
    static let addKeyColumnStep = "Add Key Column"
    /// How faint a key's target's pill is behind it in a line.
    static let keyPillFill: CGFloat = 0.14

    /// The gutter's marks: a primary key's key, in the frames' gold made to read on the paper (it measured 2.9), and a
    /// unique column's "1" in a rounded square, in the types' grey.
    static let keySymbol = "key.horizontal"
    static let uniqueSymbol = "1.square"
    static let markSize: CGFloat = 13
    static let keyColor = KitStyle.onPaper(KitStyle.keyGold).solid.light
    /// A column that starts a key (the key index's): a link, in the frames' blue made to read on the paper.
    static let linkSymbol = "link"
    static let linkColor = KitStyle.onPaper(KitStyle.linkBlue).solid.light
    static let uniqueColor = KitStyle.secondaryInk

    /// An enum-typed column's pill: the frames' purple as Palette makes it on the paper, faint behind the enum's name in
    /// its ink, a line of it round.
    static let enumPill: AdornmentTint = {
        let roles = KitStyle.onPaper(KitStyle.enumPurple)
        return AdornmentTint(NSColor(roles.solid), ink: NSColor(roles.ink), style: .light)
    }()
    /// How strong the purple is behind an enum's name typed in a line, as a light pill's is.
    static let enumPillFill: CGFloat = 0.14
    /// The nullable's `?` after a type, in the names' ink.
    static let nullMark = "?"

    /// Zoomed out: a bar where a name is and one where its type is, the names' 15-point text greeked (0.52 em a column),
    /// the types' 13-point monospaced (0.6 em), each bar where the text's x-height is.
    static let skeletonNameColumn: CGFloat = 0.52 * 15
    static let skeletonTypeColumn: CGFloat = 0.6 * 13
    static let skeletonBarHeight: CGFloat = 8
    /// The most columns a bar stands for, so a name of hundreds of characters costs what one of twenty does.
    static let skeletonMostColumns = 40
    /// The least a row is on screen, view points, for a skeleton to draw its bars: under it the paper says it.
    static let skeletonLeastRow: CGFloat = 2
}

/// An enum's look.
@MainActor
enum EnumStyle {
    static let label = "Enum"
    static let symbol = "list.bullet"
    static let placeholder = "Untitled Enum"
    static let width: CGFloat = 220
    static let minimumWidth: CGFloat = 100
    static func accessibleRows(_ count: Int) -> String { count == 1 ? "1 value" : "\(count.formatted()) values" }
    static let titleFieldName = "Enum name"
    static let addStep = "Add Enum"
    static let renameStep = "Rename Enum"
    /// A value's steps, each a commit of its line.
    static let addValueStep = "Add Value"
    static let pasteValuesStep = "Paste Values"
    static let renameValueStep = "Rename Value"
    static let deleteValueStep = "Delete Value"
    static let deleteValuesStep = "Delete Values"
    static let moveValueStep = "Move Value"
    /// What a new enum holds: none. Its height keeps one row's room.
    static let skeletonColumn: CGFloat = 0.6 * 14

    /// Its title's pill: solid, the frames' purple as Palette makes it on the canvas, its text white or black as reads.
    static let titleTint: AdornmentTint = {
        let roles = Swatch(KitStyle.enumPurple)
        return AdornmentTint(NSColor(roles.solid), ink: NSColor(roles.onSolid), style: .solid)
    }()
}

/// A database's look: a region of its board, as a frame is (a surface a step up from the canvas, a hairline border, no
/// shadow), its name in a tab on its top edge after a cylinder.
@MainActor
enum DatabaseStyle {
    static let label = "Database"
    static let symbol = "cylinder"
    static let placeholder = "Untitled Database"
    /// What its tab says while it has no title, dimmed.
    static let pillPlaceholder = "Database"
    static let createStep = "Create Database"
    /// What a click with its tool, or a database made around nothing, is.
    static let defaultSize = CGSize(width: 640, height: 400)
    /// The smallest one is drawn or resized to.
    static let minimumSize = CGSize(width: 96, height: 64)
    /// How far one made around shapes reaches past them, world units (Create Frame's).
    static let padding: CGFloat = 32
    static let cornerRadius: CGFloat = 12
    /// Its border, and how far either side of its edge one that holds shapes is pressed, view points.
    static let borderWidth: CGFloat = 1
    static let borderReach: CGFloat = 6
    static let fill = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 1, alpha: 1) }
    static let border = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12) }
    static let tint = NSColor.systemGray
    /// What VoiceOver reads as its value: what it holds, "4 shapes".
    static func accessibleContents(_ count: Int) -> String {
        switch count {
        case 0: "Empty"
        case 1: "1 shape"
        default: "\(count.formatted()) shapes"
        }
    }

    static func path(_ rect: CGRect, radius: CGFloat = cornerRadius) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
