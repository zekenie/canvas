import Canvas
import Geometry

/// The way back through the selections, one per editor (data-canvas's selection history): each
/// time the selection changes, or another board is shown, the selection it leaves goes on the
/// stack, with its board and the camera as it was at that moment, and going back
/// (`editor.goBack()`) takes the last one off and restores it.
struct SelectionHistory {
    struct Entry: Equatable {
        let board: BoardID
        let selection: [ShapeID]
        let camera: Camera
    }

    /// data-canvas's MAX_HISTORY_SIZE: past it, the oldest entry goes.
    static let limit = 50

    private(set) var entries: [Entry] = []

    /// Adds `entry` on top, unless the top one selects the same shapes (in any order) on the same
    /// board.
    mutating func push(_ entry: Entry) {
        if let top = entries.last, top.board == entry.board, Set(top.selection) == Set(entry.selection) { return }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    mutating func pop() -> Entry? { entries.popLast() }
}
