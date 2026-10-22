import Canvas
import Geometry

/// The way back through the selections, and forward again, one per editor (data-canvas's selection
/// history, with a browser's Forward): each time the selection changes, or another board is shown, the
/// selection it leaves goes on the stack, with its board and the camera as it was at that moment, and
/// going back (`editor.goBack()`) takes the last one off and restores it, putting where it was on the
/// way forward (`editor.goForward()`), which goes back to it. A new step lets the way forward go.
struct SelectionHistory {
    struct Entry: Equatable {
        let board: BoardID
        let selection: [ShapeID]
        let camera: Camera
    }

    /// data-canvas's MAX_HISTORY_SIZE: past it, the oldest entry goes, each way.
    static let limit = 50

    private(set) var entries: [Entry] = []
    /// The steps gone back from, the latest last: where going forward goes.
    private(set) var ahead: [Entry] = []

    /// A new step: adds `entry` on top, unless the top one selects the same shapes (in any order) on the
    /// same board, and lets the way forward go.
    mutating func push(_ entry: Entry) {
        ahead.removeAll()
        Self.add(entry, to: &entries)
    }

    mutating func pop() -> Entry? { entries.popLast() }

    /// Going back from `current`: it is where going forward returns.
    mutating func wentBack(from current: Entry) { Self.add(current, to: &ahead) }

    mutating func popAhead() -> Entry? { ahead.popLast() }

    /// Going forward from `current`: it is a step back again, and the way forward stays.
    mutating func wentForward(from current: Entry) { Self.add(current, to: &entries) }

    private static func add(_ entry: Entry, to stack: inout [Entry]) {
        if let top = stack.last, top.board == entry.board, Set(top.selection) == Set(entry.selection) { return }
        stack.append(entry)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }
}
