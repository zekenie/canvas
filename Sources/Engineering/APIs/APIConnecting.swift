import Canvas
import Connections

/// What ⌘L's picker means on an API (`ConnectPicks`). Opened on an endpoint's row (one being edited, or selected as an item), it
/// lists the tables of the file, which the endpoint writes or reads (picked, the arrow is drawn plain and the release lists writes and
/// reads) and the endpoints of the file, which it calls (E4 panel 4: one on another board through a pill for that endpoint); never
/// a table's column, an enum, a path prefix or a shape of another kind (calls end on endpoints' rows alone). A pick is "Connect". Opened on the
/// API as a whole, which has no dots of its own, it lists nothing.
@MainActor
enum EndpointPicks {
    static func admits(_ pick: ConnectPick, _ editor: CanvasEditor) -> Bool {
        guard let row = pick.from.part, let source = editor.shape(inFile: pick.from.shape), isEndpoint(row, of: source),
              let far = editor.shape(inFile: pick.to.shape) else { return false }
        if far.kind == DatabaseTable.kind { return pick.to.part == nil }
        // Calls end on endpoints' rows alone: an API's, or one standing alone; any other kind takes none.
        guard let part = pick.to.part else { return false }
        return pick.to.address != pick.from.address && isEndpoint(part, of: far)
    }

    /// Whether `part` is an endpoint of `record`: an API's endpoint row (not a header), or an endpoint standing alone's row.
    static func isEndpoint(_ part: PartID, of record: AnyShapeRecord) -> Bool {
        if let api = record.typed(as: API.self) { return api.props.endpoints.contains { $0.id == part && $0.endpoint != nil } }
        if let alone = record.typed(as: StandaloneEndpoint.self) { return alone.props.endpoint.id == part }
        return false
    }

    static func plan(_ pick: ConnectPick, _ editor: CanvasEditor) -> ConnectPlan? {
        admits(pick, editor) ? ConnectPlan(from: pick.from, to: pick.to) : nil
    }
}
