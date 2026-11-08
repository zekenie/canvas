import Canvas
import Connections

/// What ⌘L's picker means on an API (`ConnectPicks`). Opened on an endpoint's row (one being edited, or selected as an item), it
/// lists the tables of the file, which the endpoint writes or reads (picked, the arrow is drawn plain and the release lists writes and
/// reads), the endpoints of the file, which it calls (E4 panel 4: one on another board through a pill for that endpoint), and the
/// shapes of any other kind that takes a call; never a table's column, an enum or a path prefix. A pick is "Connect". Opened on the
/// API as a whole, which has no dots of its own, it lists nothing.
@MainActor
enum EndpointPicks {
    static func admits(_ pick: ConnectPick, _ editor: CanvasEditor) -> Bool {
        guard let row = pick.from.part, let source = editor.shape(inFile: pick.from.shape)?.typed(as: API.self),
              source.props.endpoints.contains(where: { $0.id == row && $0.endpoint != nil }),
              let far = editor.shape(inFile: pick.to.shape) else { return false }
        if far.kind == DatabaseTable.kind { return pick.to.part == nil }
        if let api = far.typed(as: API.self) {
            guard let part = pick.to.part else { return false }
            return pick.to.address != pick.from.address && api.props.endpoints.contains { $0.id == part && $0.endpoint != nil }
        }
        // Another kind: as a whole, where it takes a call.
        return pick.to.part == nil && editor.registry.takes(far.kind, Calls.id, as: .target)
    }

    static func plan(_ pick: ConnectPick, _ editor: CanvasEditor) -> ConnectPlan? {
        admits(pick, editor) ? ConnectPlan(from: pick.from, to: pick.to) : nil
    }
}
