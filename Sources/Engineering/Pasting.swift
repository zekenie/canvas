import Canvas
import Clipboard
import Connections
import Draw

// What the kit reads from the pasteboard (Clipboard's paste readers, which go with the kit: a file with it off reads none): SQL's
// tables and enums (the Readers part), put down by Draw with their keys on the kit's channel (the Tables part's).

extension PluginRegistrar {
    /// ⌘V of SQL ("Paste SQL"): a text with `CREATE TABLE` or `AS ENUM`, or a `.sql` file, read when one table or enum reads.
    mutating func sqlPaste() {
        pasteReader(SQLPaste.name, sniff: { SQLPaste.sniffs($0) }, read: { content, editor in
            SQLPaste.read(content, in: editor, keys: SQLPaste.foreignKeys)
        })
    }
}

extension SQLPaste {
    /// A key's edge: an arrow on the kit's channel, a column's one.
    static var foreignKeys: KeyChannel {
        KeyChannel(attributes: [ChannelProperty.key.rawValue: ForeignKey.id.rawValue], type: ForeignKey.id.rawValue)
    }

    /// What ⌘V of `text` puts down at `site`, Draw to put it down (`Draw.put`): its tables and enums by their titles, in rows of
    /// four, each table's keys the edges it implies; nil when no table and no enum reads.
    @MainActor
    public static func program(of text: String, at site: PutSite, in editor: CanvasEditor) -> DrawPut? {
        program(of: text, at: site, in: editor, keys: foreignKeys)
    }
}
