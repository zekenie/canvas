import Canvas
import FuzzyMatching

/// The rows of the catalog's named shapes (`PartedShape`'s parts, read with each entry: a table's columns), ready to match as
/// the shapes are: each row's name folded once, the keys back to back in one buffer. A row is its shape's: read again with its
/// shape's entry (only when its parts' names changed), gone with it, so a commit costs the rows of the shapes it changed. What a
/// list that asks for rows ranks (`candidates(…listingParts:)`): a row that stands alone (an endpoint) by its name, and every row
/// by its path, its shape's place and the shape's own name before it (`orders cust`).
@MainActor
struct MentionPartCatalog {
    /// One row: its shape, what it is (`PartName`), and its name's keys in `keys`.
    struct Entry {
        let shape: ShapeID
        let part: PartName
        var start: Int
        var count: Int
        /// Its name's length in characters, for ties.
        var labelLength: Int
    }

    private(set) var entries: [Entry] = []
    private(set) var keys: [UInt32] = []
    /// Each shape's rows' slots, in its order.
    private var slots: [ShapeID: [Int]] = [:]
    /// Keys in `keys` no entry uses any longer.
    private var unused = 0

    /// How many rows it holds.
    var count: Int { entries.count }

    /// A shape's rows, in its order.
    func rows(of shape: ShapeID) -> [Entry] { (slots[shape] ?? []).map { entries[$0] } }

    /// Whether the row at `slot` is all its shape is: its shape's one row, standing alone (an endpoint of its own).
    func isItsOwnRow(_ slot: Int) -> Bool {
        let entry = entries[slot]
        return entry.part.standsAlone && slots[entry.shape]?.count == 1
    }

    /// A shape's rows, put in or read again: nothing changes while their names, kind words, leads and order are as held.
    mutating func set(_ shape: ShapeID, parts: [PartName]) {
        if let held = slots[shape], held.count == parts.count, zip(held, parts).allSatisfy({ entries[$0].part == $1 }) { return }
        remove(shape)
        guard !parts.isEmpty else { return }
        var made: [Int] = []
        made.reserveCapacity(parts.count)
        for part in parts {
            let start = keys.count
            let length = FuzzyMatcher.appendKeys(of: part.name, to: &keys)
            made.append(entries.count)
            entries.append(Entry(shape: shape, part: part, start: start, count: keys.count - start, labelLength: length))
        }
        slots[shape] = made
        packIfWasteful()
    }

    /// Takes a shape's rows out: the last entries take their places.
    mutating func remove(_ shape: ShapeID) {
        guard let held = slots.removeValue(forKey: shape) else { return }
        // The largest first: an entry moved into a gap is never one of the shape's, which are all past it by then.
        for slot in held.sorted(by: >) {
            unused += entries[slot].count
            let last = entries.count - 1
            if slot != last {
                let moved = entries[last]
                entries[slot] = moved
                if var list = slots[moved.shape], let at = list.firstIndex(of: last) {
                    list[at] = slot
                    slots[moved.shape] = list
                }
            }
            entries.removeLast()
        }
        packIfWasteful()
    }

    private mutating func packIfWasteful() {
        guard unused > 4096, unused * 2 > keys.count else { return }
        var packed: [UInt32] = []
        packed.reserveCapacity(keys.count - unused)
        for i in entries.indices {
            let start = packed.count
            packed.append(contentsOf: keys[entries[i].start..<entries[i].start + entries[i].count])
            entries[i].start = start
        }
        keys = packed
        unused = 0
    }
}
