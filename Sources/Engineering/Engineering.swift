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

/// The kit's plugin: the `table`, `enum-type`, `api` and `database` kinds; the Table, Enum, API and Database tools, each a new
/// shape whose name is typed in its pill as it lands (a database's tab), "Add Table"; `/table NAME`, `/api [NAME]`, `/database
/// NAME` and Create Database; ⌘V of SQL ("Paste SQL") and of OpenAPI ("Paste OpenAPI"); and `canvas draw`'s `columns:`, `values:`, `server:` and `endpoints:`,
/// lines in their grammars. Its kinds opt into Titles (the name in
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
        registrar.keyHint("⌘L in a Row", "Connect the Row", while: .text)
        registrar.keyHint("⌘↓ in a Column", "Show the Column's Details", while: .text)
        registrar.keyHint("⌘↓ in an Endpoint", "Show the Endpoint's Details", while: .text)
        // Keys: arrows on the `foreign-key` channel, column to column, and the index of each table's that its rows read.
        registrar.channel(ForeignKey.self)
        // What an API does: an endpoint writes or reads a table, and something calls an endpoint; each a pill on its line.
        registrar.channel(Calls.self)
        registrar.channel(Writes.self)
        registrar.channel(Reads.self)
        registrar.service { KeyIndex(editor: $0) }
        // A key's marks and width, from its column: a crow's foot (bars when unique), bars (a bar and a circle when nullable), 2.5.
        registrar.connectionLook(KeyLooks.look)
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
            // An endpoint writes or reads it as a whole: it takes them on its sides, with no dots there.
            table.ports(Writes.self, role: .target)
            table.ports(Reads.self, role: .target)
            // ⌘L's picker on a table: from a row, the tables and their columns, a key to the row picked (a table's, its primary key);
            // from the table, a table picked makes the key column for it ("Add Key Column").
            table.connectPicks(admitting: KeyPicks.admits, KeyPicks.plan)
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
        var placedAPI: Placement?
        registrar.shape(APIDefinition()) { api in
            api.label(APIStyle.label, systemImage: APIStyle.symbol)
            let size = CGSize(width: APIStyle.width, height: APIRows.height(lines: 1))
            let placing = api.editingPlacement(size: size) { API() }
            placedAPI = placing
            api.tool(label: APIStyle.label, systemImage: APIStyle.symbol, placing: placing)
            api.tint(NSColor(KitStyle.secondaryInk))
            api.title(symbolInPill: true, placeholderInPill: APIStyle.label, bars: true)
            api.mentionable()
            api.resizable(minimumSize: CGSize(width: APIStyle.minimumWidth, height: APIRows.height(lines: 1)))
            api.contentsRow { _, _ in ContentsLabel("", placeholder: APIStyle.placeholder, systemImage: APIStyle.symbol) }
            api.details(header: { $api in TitleHeader($api, placeholder: APIStyle.placeholder, systemImage: APIStyle.symbol) }) {}
            api.accessibility { api, _ in AccessibleTraits(value: APIStyle.accessibleRows(api.props.endpoints.count { $0.endpoint != nil })) }
            // Its server and rows written as lines; an endpoint's card (⌘↓, or the "›" on its row).
            api.lineRows(APILines())
            // An endpoint's row has a dot at each end: it calls another endpoint (or is called, by anything with dots), writes and
            // reads tables. Calls first, so its dots are calls' blue and a drag onto another endpoint calls it.
            api.partPorts(Calls.self)
            api.partPorts(Writes.self, role: .source)
            api.partPorts(Reads.self, role: .source)
            // ⌘L from an endpoint: the tables it may write or read, the endpoints it may call, and what else takes a call.
            api.connectPicks(admitting: EndpointPicks.admits, EndpointPicks.plan)
        }
        // One endpoint taken out of an API, standing alone (E3 panel 4): no tool (a row taken out makes one), titled by its name.
        registrar.shape(EndpointDefinition()) { endpoint in
            endpoint.label(EndpointStyle.label, systemImage: APIStyle.symbol)
            endpoint.tint(NSColor(KitStyle.secondaryInk))
            endpoint.title(symbolInPill: true, placeholderInPill: EndpointStyle.label) { EndpointStyle.title(of: $0.props.endpoint) }
            endpoint.mentionable()
            endpoint.resizable(minimumSize: CGSize(width: APIStyle.minimumWidth, height: KitStyle.height(rows: 1)))
            endpoint.contentsRow { _, _ in ContentsLabel("", placeholder: EndpointStyle.placeholder, systemImage: APIStyle.symbol) }
            endpoint.details(header: { $endpoint in
                TitleHeader($endpoint.endpoint.name, placeholder: EndpointStyle.title(of: endpoint.endpoint), systemImage: APIStyle.symbol)
            }) {}
            endpoint.accessibility { endpoint, _ in AccessibleTraits(value: EndpointStyle.accessibleValue(of: endpoint.props.endpoint)) }
            // Its one row, as LineRows moves rows: an item of it, its chip its lead (the method menu, a drag into an API).
            endpoint.lineRows(EndpointLines())
            // Its row's dots, as an API's row's: it calls, writes and reads, and is called.
            endpoint.partPorts(Calls.self)
            endpoint.partPorts(Writes.self, role: .source)
            endpoint.partPorts(Reads.self, role: .source)
            endpoint.connectPicks(admitting: EndpointPicks.admits, EndpointPicks.plan)
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
        if let placedAPI { registrar.apiCommands(placing: placedAPI) }
        // New Version, Group by Prefix and Change Method ▸, the selection's menu's and the command bar's.
        registrar.apiChanges()
        registrar.rowsDraw()
        registrar.apiDraw()
        // ⌘V of SQL, and of OpenAPI: tables and enums, an API and its types, put down by names, the kit's (gone with it off).
        registrar.sqlPaste()
        registrar.openAPIPaste()
    }
}
