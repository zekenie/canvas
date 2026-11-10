import Canvas
import Clipboard
import Connections
import Draw
import Types

// What the kit reads from the pasteboard (Clipboard's paste readers, which go with the kit: a file with it off reads none): SQL's
// tables and enums (the Readers part), put down by Draw with their keys on the kit's channel (the Tables part's); and OpenAPI's API
// and its types, the types notes of the kind New Type makes (Types').

extension PluginRegistrar {
    /// ⌘V of SQL ("Paste SQL"): a text with `CREATE TABLE` or `AS ENUM`, or a `.sql` file, read when one table or enum reads.
    mutating func sqlPaste() {
        // The enums the file has measure a column typed as one as its pill: read again once they change (review R45).
        @MainActor func fileEnums(_ editor: CanvasEditor) -> Set<String> { Set((editor.service(KitNames.self)?.enums ?? []).map(\.name)) }
        pasteReader(SQLPaste.name, sniff: { SQLPaste.sniffs($0) }, readsOfFile: { AnyHashable(fileEnums($0)) }, read: { content, editor in
            SQLPaste.read(content, keys: SQLPaste.foreignKeys, fileEnums: fileEnums(editor))
        })
    }

    /// ⌘V of OpenAPI ("Paste OpenAPI"): a text, or a `.yaml`, `.yml` or `.json` file, that says `openapi`, read when it is OpenAPI 3
    /// with `paths`. Its types are notes of the kind a new type is (`newTypeKind`); with none, the API alone.
    mutating func openAPIPaste() {
        pasteReader(OpenAPIPaste.name, sniff: { OpenAPIPaste.sniffs($0) }, read: { content, editor in
            OpenAPIPaste.read(content, typeKind: editor.newTypeKind())
        })
    }
}

extension SQLPaste {
    /// A key's edge: an arrow on the kit's channel, a column's one.
    static var foreignKeys: KeyChannel {
        KeyChannel(attributes: [ChannelProperty.key.rawValue: ForeignKey.id.rawValue], type: ForeignKey.id.rawValue)
    }

    /// What ⌘V of `text` puts down, Draw to put it down (`Draw.put`): its tables and enums by their titles, in rows of four, each
    /// table's keys the edges it implies; nil when no table and no enum reads. `fileEnums`: the names of the enums the file has.
    @MainActor
    public static func program(of text: String, fileEnums: Set<String> = []) -> DrawPut? {
        program(of: text, keys: foreignKeys, fileEnums: fileEnums)
    }
}
