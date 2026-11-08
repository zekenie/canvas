import Canvas
import Connections
import DetailPanel
import LineRows
import Mentions
import Palette
import Selection
import SwiftUI
import TableOfContents
import Titles

// The engineering kit: database tables, their enums and the databases that hold them, drawn the way the design draws
// them. One product module, in parts: the kinds' props and shared look (Model), the line grammars rows are written in
// (Grammar), and the table, the enum and the database, drawn, placed and written (Tables). Its plugin joins the kit, so
// its tools (the toolbar's kit segment, Insert ▸ Engineering), its commands and slash commands are gone from a file with
// it off; its kinds, their looks and its words for `canvas draw` never switch, so a table drawn with it on stays drawn,
// editable and moved with it off.

/// The engineering kit: File ▸ Kits ▸ Engineering.
public enum EngineeringKit {}

extension EngineeringKit: Kit {
    public static let id: KitID = "engineering"
    public static var title: String { "Engineering" }
}

extension PluginID {
    public static let engineering: PluginID = "engineering"
}

/// The kit's plugin: the `table`, `enum-type` and `database` kinds; the Table, Enum and Database tools, each a new shape
/// whose name is typed in its pill as it lands (a database's tab), "Add Table"; `/table NAME`, `/database NAME` and Create
/// Database; and `canvas draw`'s `columns:` and `values:`, lines in their grammars. Its kinds opt into Titles (the name in
/// the pill, bars zoomed out), Mentions, the table of contents and the detail panel's header; Locking, Publishing and
/// Grouping are every shape's.
public struct EngineeringPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .engineering }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.join(EngineeringKit.self)
        registrar.service { KitNames(editor: $0) }
        // The keys of a row, listed with the kit that has rows: a file with it off lists none.
        registrar.keyHint("↩ in a Row", "Next Row; on an Empty Row, Finish", while: .text)
        registrar.keyHint("⌥↑ ⌥↓ in a Row", "Move the Row", while: .text)
        registrar.keyHint("⌘⌫ then ⌫ in a Row", "Delete the Row", while: .text)
        registrar.keyHint("⇧↩ in a Row", "New Shape Beside It", while: .text)
        // Keys: arrows on the `foreign-key` channel, column to column, and the index of each table's that its rows read.
        registrar.channel(ForeignKey.self)
        registrar.service { KeyIndex(editor: $0) }
        var editedTable: Placement?
        registrar.shape(TableDefinition()) { table in
            table.label(TableStyle.label, systemImage: TableStyle.symbol)
            let size = CGSize(width: TableStyle.width, height: KitStyle.height(rows: 1))
            let placing = table.editingPlacement(size: size) { DatabaseTable.starter() }
            editedTable = placing
            table.tool(label: TableStyle.label, systemImage: TableStyle.symbol, placing: placing)
            table.tint(NSColor(KitStyle.secondaryInk))
            table.title(symbolInPill: true, placeholderInPill: TableStyle.label, bars: true)
            table.mentionable()
            table.resizable(minimumSize: CGSize(width: TableStyle.minimumWidth, height: KitStyle.height(rows: 1)))
            table.contentsRow { _, _ in ContentsLabel("", placeholder: TableStyle.placeholder, systemImage: TableStyle.symbol) }
            table.details(header: { $table in TitleHeader($table, placeholder: TableStyle.placeholder, systemImage: TableStyle.symbol) }) {}
            table.accessibility { table, _ in AccessibleTraits(value: TableStyle.accessibleRows(table.props.columns.count)) }
            table.lineRows(TableLines())
            // Its columns take keys both ways: a dot at each end of the row the pointer is on, and a key's end on a row.
            table.partPorts(ForeignKey.self)
        }
        registrar.shape(EnumDefinition()) { type in
            type.label(EnumStyle.label, systemImage: EnumStyle.symbol)
            let size = CGSize(width: EnumStyle.width, height: KitStyle.height(rows: 1))
            type.tool(label: EnumStyle.label, systemImage: EnumStyle.symbol, placing: type.editingPlacement(size: size) { DatabaseEnum() })
            type.tint(NSColor(KitStyle.enumPurple))
            type.title(symbolInPill: true, placeholderInPill: EnumStyle.label, bars: true)
            type.titlePillLook { _, _ in TitlePillLook(tint: EnumStyle.titleTint) }
            type.mentionable()
            type.resizable(minimumSize: CGSize(width: EnumStyle.minimumWidth, height: KitStyle.height(rows: 1)))
            type.contentsRow { _, _ in ContentsLabel("", placeholder: EnumStyle.placeholder, systemImage: EnumStyle.symbol) }
            type.details(header: { $type in TitleHeader($type, placeholder: EnumStyle.placeholder, systemImage: EnumStyle.symbol) }) {}
            type.accessibility { type, _ in AccessibleTraits(value: EnumStyle.accessibleRows(type.props.values.count)) }
            type.lineRows(EnumLines())
        }
        registrar.shape(DatabaseDefinition()) { database in
            database.label(DatabaseStyle.label, systemImage: DatabaseStyle.symbol)
            let place = database.placement(size: DatabaseStyle.defaultSize, minimumSize: DatabaseStyle.minimumSize) { Database() }
            database.tool(label: DatabaseStyle.label, systemImage: DatabaseStyle.symbol, placing: place)
            database.tint(DatabaseStyle.tint)
            database.title(symbolInPill: true, placeholderInPill: DatabaseStyle.pillPlaceholder)
            database.titleTab { _, _ in TitleTabLook(surface: DatabaseStyle.fill, edge: DatabaseStyle.border) }
            database.mentionable()
            database.resizable(minimumSize: place.minimumSize)
            database.contentsRow { _, _ in ContentsLabel("", placeholder: DatabaseStyle.placeholder, systemImage: DatabaseStyle.symbol) }
            database.details(header: { $database in TitleHeader($database, placeholder: DatabaseStyle.placeholder, systemImage: DatabaseStyle.symbol) }) {}
            database.accessibility { database, editor in
                editor.document[database.id] == nil ? nil
                    : AccessibleTraits(value: DatabaseStyle.accessibleContents(editor.shapeContext.contents(of: database.id).count))
            }
        }
        if let editedTable { registrar.tableCommands(placing: editedTable) }
        registrar.rowsDraw()
    }
}
