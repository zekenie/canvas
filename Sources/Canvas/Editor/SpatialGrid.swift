import CoreGraphics
import Geometry

/// Which cells of a uniform grid each shape's extent covers, kept with a paint list: the shapes near a rect or a
/// point are found by looking in the cells it covers, and at a short list of shapes no cell holds, never at every
/// shape, so finding what's in view, or under the pointer, costs the cells and what is found there.
///
/// A shape is filed under its paint position, in every cell its extent covers, and filed again when its extent
/// changes (`update`), which costs nothing for an extent that stays in the same cells. An extent that can't be
/// filed by cell is `wide`, and every search looks at it: one with no bounds to cull by (infinite, or not a number),
/// one far past anything on a board, and one that covers more cells than a shape is filed in (a frame round a whole
/// neighbourhood). A null extent is filed nowhere, as no rect touches it.
///
/// It only narrows what to look at: a search hands back each shape filed where its rect reaches (some more than once),
/// and the caller asks of each what it would ask of every shape (the same `touches`, the same `mayHit`), so what is
/// found is what a pass over every shape finds. A rect with no bounds, or that covers more cells than are worth
/// visiting, isn't searched (`block(of:)` is nil): the caller goes through every shape, as it did.
///
/// The cells are in an open-addressed table keyed by their coordinates, so the board has no edge and a shape
/// dragged far away costs a cell. Cells emptied stay in the table until it grows, when they are left behind.
final class SpatialGrid {
    /// Where a shape is filed.
    enum Placement: Equatable {
        /// Nowhere: a null extent.
        case nowhere
        /// Among the shapes every search looks at.
        case wide
        /// In every cell of the block, from the first column and row to the last, inclusive.
        case cells(x0: Int32, y0: Int32, x1: Int32, y1: Int32)
    }

    /// The cells a rect covers, inclusive.
    struct Block {
        var x0: Int, y0: Int, x1: Int, y1: Int
        var count: Int { (x1 - x0 + 1) * (y1 - y0 + 1) }
    }

    /// One shape in one cell: its paint position, and the next link of the cell.
    private struct Link {
        var position: Int32
        var next: Int32
    }

    /// What a shape is filed in at most: more cells than this and it is `wide`.
    static let mostCells = 64
    /// Past this, in either direction on either axis, a coordinate is no place on a board.
    static let farthest: CGFloat = 1e9
    /// The smallest cell, and the cell of a board whose shapes tell nothing of one.
    static let smallestCell: CGFloat = 32
    static let usualCell: CGFloat = 256

    /// The side of a cell, in world units: a little over a usual shape's.
    let cell: CGFloat
    private let inverse: CGFloat

    private static let free: Int64 = .min
    private var keys: [Int64]
    private var heads: [Int32]
    private var shift: UInt64
    /// How many slots have a cell, emptied or not.
    private var occupied = 0

    private var links: [Link] = []
    private var freeLink: Int32 = -1

    /// The shapes every search looks at, and where each is in the list (-1 for one that isn't).
    private(set) var wide: [Int32] = []
    private var wideSlot: [Int32]
    /// How many were wide when the grid was made.
    private var wideAtStart = 0

    /// Files every shape by its extent, in paint order.
    init(extents: [CGRect]) {
        let cell = Self.cellSize(for: extents)
        self.cell = cell
        inverse = 1 / cell
        var capacity = 64
        while capacity < extents.count * 2 { capacity *= 2 }
        keys = [Int64](repeating: Self.free, count: capacity)
        heads = [Int32](repeating: -1, count: capacity)
        shift = UInt64(64 - capacity.trailingZeroBitCount)
        wideSlot = [Int32](repeating: -1, count: extents.count)
        links.reserveCapacity(extents.count * 3)
        for position in extents.indices { insert(Int32(position), placement(of: extents[position])) }
        wideAtStart = wide.count
    }

    /// A cell for these extents: one and a half times the middle of a sample of their longer sides.
    static func cellSize(for extents: [CGRect]) -> CGFloat {
        let step = max(1, extents.count / 1024)
        var sides: [CGFloat] = []
        var position = 0
        while position < extents.count {
            let extent = extents[position]
            if !extent.isNull, extent.isFinite {
                let side = max(abs(extent.size.width), abs(extent.size.height))
                if side < farthest { sides.append(side) }
            }
            position += step
        }
        guard !sides.isEmpty else { return usualCell }
        sides.sort()
        return max(smallestCell, sides[sides.count / 2] * 1.5)
    }

    // MARK: Filing

    func placement(of extent: CGRect) -> Placement {
        if extent.isNull { return .nowhere }
        let x = extent.origin.x, y = extent.origin.y, width = extent.size.width, height = extent.size.height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return .wide }
        let minX = min(x, x + width), maxX = max(x, x + width), minY = min(y, y + height), maxY = max(y, y + height)
        guard minX >= -Self.farthest, maxX <= Self.farthest, minY >= -Self.farthest, maxY <= Self.farthest else { return .wide }
        let x0 = (minX * inverse).rounded(.down), x1 = (maxX * inverse).rounded(.down)
        let y0 = (minY * inverse).rounded(.down), y1 = (maxY * inverse).rounded(.down)
        guard (x1 - x0 + 1) * (y1 - y0 + 1) <= CGFloat(Self.mostCells) else { return .wide }
        return .cells(x0: Int32(x0), y0: Int32(y0), x1: Int32(x1), y1: Int32(y1))
    }

    /// Room for one more shape, not filed anywhere yet.
    func addPosition() { wideSlot.append(-1) }

    /// The shape at `position` has another extent: filed where it now is, and no longer where it was.
    func update(_ position: Int, from old: CGRect, to new: CGRect) {
        let before = placement(of: old), after = placement(of: new)
        guard before != after else { return }
        remove(Int32(position), before)
        insert(Int32(position), after)
    }

    /// Whether the grid has fallen behind the board: far more shapes are wide than when it was made, which a cell of
    /// another size might file.
    var isStale: Bool { wide.count > 2 * wideAtStart + max(256, wideSlot.count / 16) }

    private func insert(_ position: Int32, _ placement: Placement) {
        switch placement {
        case .nowhere: break
        case .wide:
            wideSlot[Int(position)] = Int32(wide.count)
            wide.append(position)
        case let .cells(x0, y0, x1, y1):
            for y in y0...y1 {
                for x in x0...x1 { file(position, inCell: Self.key(x, y)) }
            }
        }
    }

    private func remove(_ position: Int32, _ placement: Placement) {
        switch placement {
        case .nowhere: break
        case .wide:
            let slot = Int(wideSlot[Int(position)])
            let last = wide.removeLast()
            if last != position {
                wide[slot] = last
                wideSlot[Int(last)] = Int32(slot)
            }
            wideSlot[Int(position)] = -1
        case let .cells(x0, y0, x1, y1):
            for y in y0...y1 {
                for x in x0...x1 { unfile(position, fromCell: Self.key(x, y)) }
            }
        }
    }

    private static func key(_ x: Int32, _ y: Int32) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: y)) }

    private func slot(of key: Int64) -> Int {
        var slot = Int((UInt64(bitPattern: key) &* 0x9E37_79B9_7F4A_7C15) >> shift)
        let mask = keys.count - 1
        while true {
            let found = keys[slot]
            if found == key || found == Self.free { return slot }
            slot = (slot + 1) & mask
        }
    }

    private func file(_ position: Int32, inCell key: Int64) {
        var slot = slot(of: key)
        if keys[slot] == Self.free {
            if (occupied + 1) * 2 > keys.count {
                grow()
                slot = self.slot(of: key)
            }
            keys[slot] = key
            occupied += 1
        }
        let link: Int32
        if freeLink >= 0 {
            link = freeLink
            freeLink = links[Int(link)].next
            links[Int(link)] = Link(position: position, next: heads[slot])
        } else {
            link = Int32(links.count)
            links.append(Link(position: position, next: heads[slot]))
        }
        heads[slot] = link
    }

    private func unfile(_ position: Int32, fromCell key: Int64) {
        let slot = slot(of: key)
        guard keys[slot] == key else {
            assertionFailure("a shape filed in a cell the grid doesn't have")
            return
        }
        var previous: Int32 = -1, link = heads[slot]
        while link >= 0 {
            let next = links[Int(link)].next
            if links[Int(link)].position == position {
                if previous < 0 { heads[slot] = next } else { links[Int(previous)].next = next }
                links[Int(link)].next = freeLink
                freeLink = link
                return
            }
            previous = link
            link = next
        }
        assertionFailure("a shape missing from the cell it was filed in")
    }

    /// The table doubles (or, with a good many of its cells emptied, stays the size it is), leaving the emptied cells
    /// behind.
    private func grow() {
        var live = 0
        for slot in keys.indices where keys[slot] != Self.free && heads[slot] >= 0 { live += 1 }
        var capacity = keys.count
        while (live + 1) * 4 > capacity { capacity *= 2 }
        let old = (keys, heads)
        keys = [Int64](repeating: Self.free, count: capacity)
        heads = [Int32](repeating: -1, count: capacity)
        shift = UInt64(64 - capacity.trailingZeroBitCount)
        occupied = 0
        for index in old.0.indices where old.0[index] != Self.free && old.1[index] >= 0 {
            let slot = slot(of: old.0[index])
            keys[slot] = old.0[index]
            heads[slot] = old.1[index]
            occupied += 1
        }
    }

    // MARK: Searching

    /// The cells `rect` covers, grown by `margin` cells, or nil when it has no bounds, is far past anything on a board,
    /// or covers more than `most` cells.
    func block(of rect: CGRect, margin: Int = 0, most: Int) -> Block? {
        let x = rect.origin.x, y = rect.origin.y, width = rect.size.width, height = rect.size.height
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        let minX = min(x, x + width), maxX = max(x, x + width), minY = min(y, y + height), maxY = max(y, y + height)
        guard minX >= -Self.farthest, maxX <= Self.farthest, minY >= -Self.farthest, maxY <= Self.farthest else { return nil }
        let block = Block(x0: Int((minX * inverse).rounded(.down)) - margin, y0: Int((minY * inverse).rounded(.down)) - margin,
                          x1: Int((maxX * inverse).rounded(.down)) + margin, y1: Int((maxY * inverse).rounded(.down)) + margin)
        return block.count <= most ? block : nil
    }

    /// Adds to `found` the position of every shape filed in a cell of `block` or wide, some more than once; with a
    /// `rect`, only those whose extent touches it. False, with `found` partly filled, when it would add more than
    /// `most`.
    func gather(_ block: Block, touching rect: CGRect?, extents: UnsafeBufferPointer<CGRect>, into found: inout [Int32], most: Int) -> Bool {
        if let rect {
            for position in wide where extents[Int(position)].touches(rect) { found.append(position) }
        } else {
            found.append(contentsOf: wide)
        }
        for y in block.y0...block.y1 {
            for x in block.x0...block.x1 {
                let key = Self.key(Int32(x), Int32(y))
                let slot = slot(of: key)
                guard keys[slot] == key else { continue }
                var link = heads[slot]
                while link >= 0 {
                    let entry = links[Int(link)]
                    if let rect {
                        if extents[Int(entry.position)].touches(rect) { found.append(entry.position) }
                    } else {
                        found.append(entry.position)
                    }
                    link = entry.next
                }
            }
            if found.count > most { return false }
        }
        return found.count <= most
    }

    /// `gather` over extents in an array, for a caller that keeps them in one.
    func gather(_ block: Block, touching rect: CGRect?, extents: [CGRect], into found: inout [Int32], most: Int) -> Bool {
        extents.withUnsafeBufferPointer { gather(block, touching: rect, extents: $0, into: &found, most: most) }
    }
}
