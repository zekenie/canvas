import Canvas

/// Where a shape comes in board order (`TopologySnapshot.boardOrder(from:)`): the order Find lists
/// and steps through the file in, the root's shapes in file order (what a frame holds right after
/// the frame), then each board under it, depth first, a board's own shapes before the boards under
/// it. Keys sort as that order does, so a few shapes are put in it without walking the file
/// (`boardOrderKey(of:)`, O(depth)), whichever boards they're on.
///
/// A key is a chain of per-board segments, from the root's board down to the shape's own: on each
/// board but the last, the place of the shape that owns the next board, and on the last, the
/// shape's own. A place is the shape's container chain on that board, as `fileOrderKey` builds it,
/// outermost first. Compared segment by segment, a shape's own segment comes before the segment of
/// an owner at the same place (the owner, then the boards under its board) and before every owner
/// on its board (a board's own shapes come before the boards under it), and a place that is a
/// prefix of another comes first (a frame, then what it holds).
///
/// Stored flat so a key is one array: each segment is a mark (`own` or `owner`), then its places
/// shifted by `shift`, so a mark, which the next segment starts with, is less than any place and
/// plain lexicographic order is the order above. Equal keys are the same shape.
public struct BoardOrderKey: Hashable, Comparable, Sendable {
    /// Marks a segment that is the shape's own, the last: before any owner's.
    static let own = 0
    /// Marks a segment that is an owner's, with another after it.
    static let owner = 1
    /// What a place is shifted by, to sit above the marks.
    static let shift = 2

    let parts: [Int]

    init(parts: [Int]) { self.parts = parts }

    public static func < (a: BoardOrderKey, b: BoardOrderKey) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}

extension ChangeSet {
    /// Whether the commit may have changed where some shape comes in board order (`BoardOrderKey`), so a key kept from before
    /// it is no longer to be compared with one taken now: the document was replaced, a shape was added, removed or restacked
    /// (every later place on its board shifts, and the boards under them), another board was reached, or a shape that was not
    /// only moved has another container than it had (a frame put in a frame, a card in one: the keys of everything inside go
    /// with it, though no shape was restacked). `file` is the file as the commit leaves it. A commit that only edits or moves
    /// shapes, the common one, is none of these. Conservative where it cannot tell: a changed shape the change set holds no
    /// earlier record of counts as moved to another container.
    public func mayHaveChangedBoardOrder(in file: CanvasFile) -> Bool {
        if replacedDocument || reordered || !added.isEmpty || !removed.isEmpty || !elsewhere.isEmpty || !boardsReached.isEmpty { return true }
        for id in changed where !moved.contains(id) {
            guard let before = before(id), let now = file.record(id) else { return true }
            if before.container != now.container { return true }
        }
        return false
    }
}
