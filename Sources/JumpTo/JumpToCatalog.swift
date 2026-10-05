import Canvas
import FuzzyMatching

/// Every titled shape on the boards of a file the editor can show, ready for a keystroke to match:
/// each shape's title and the container it's directly in (its frame, else the owner of its board;
/// nil on the root), and the title's keys folded once (`FuzzyMatcher`), every shape's back to back
/// in one buffer, so a keystroke reads them in two linear passes with nothing to retain or allocate
/// per shape. It keeps no paths (a container's rename or move costs nothing here, and a path is made
/// for the rows shown), nor the file's order, nor boards. A renamed shape's new keys go at the end,
/// and a shape's folded label (`FuzzyMatcher.Label`, which the path matcher takes) is made the first
/// time a query reaches it and kept; the buffer is packed again once half of it is keys no shape
/// uses. Mentions' catalog has this shape (its labels, not titles).
@MainActor
struct JumpToCatalog {
    /// One shape's place in the catalog: plain values only, so reading one costs nothing more.
    struct Entry {
        let id: ShapeID
        /// What it's directly in: a frame, else the owner of its board; nil on the root.
        var parent: ShapeID?
        /// Where `parent` is in `containers`: a query's rows for containers are kept by it, in an
        /// array; -1 for the root.
        var container: Int32
        /// Its title's keys in `keys`.
        var start: Int
        var count: Int
        /// Where it is among the recent picks, the latest 0; -1 if it isn't one.
        var recentRank: Int
    }

    private(set) var entries: [Entry] = []
    /// Beside `entries`, index for index.
    private(set) var titles: [String] = []
    private(set) var keys: [UInt32] = []
    private var labels: [FuzzyMatcher.Label?] = []
    private var slots: [ShapeID: Int] = [:]
    /// Every container an entry has been directly in, each once, as the entries number them
    /// (`Entry.container`); kept until the catalog is made again, a few more than there are.
    private(set) var containers: [ShapeID] = []
    private var containerSlots: [ShapeID: Int32] = [:]
    /// Keys in `keys` no entry uses any longer.
    private var unused = 0

    var count: Int { entries.count }

    func slot(of id: ShapeID) -> Int? { slots[id] }

    func contains(_ id: ShapeID) -> Bool { slots[id] != nil }

    /// Puts a shape in, or updates it: its title's keys are folded again only if its title changed.
    mutating func set(_ id: ShapeID, title: String, parent: ShapeID?, recentRank: Int) {
        if let slot = slots[id] {
            if titles[slot] != title {
                unused += entries[slot].count
                let start = keys.count
                _ = FuzzyMatcher.appendKeys(of: title, to: &keys)
                entries[slot].start = start
                entries[slot].count = keys.count - start
                titles[slot] = title
                labels[slot] = nil
            }
            entries[slot].parent = parent
            entries[slot].container = intern(parent)
            entries[slot].recentRank = recentRank
        } else {
            let start = keys.count
            _ = FuzzyMatcher.appendKeys(of: title, to: &keys)
            slots[id] = entries.count
            entries.append(Entry(id: id, parent: parent, container: intern(parent), start: start, count: keys.count - start, recentRank: recentRank))
            titles.append(title)
            labels.append(nil)
        }
        packIfWasteful()
    }

    /// A container's number, made the first time it's asked; -1 for none (the root).
    private mutating func intern(_ container: ShapeID?) -> Int32 {
        guard let container else { return -1 }
        if let known = containerSlots[container] { return known }
        let index = Int32(containers.count)
        containers.append(container)
        containerSlots[container] = index
        return index
    }

    /// Takes a shape out: the last entry takes its place.
    mutating func remove(_ id: ShapeID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        unused += entries[slot].count
        let last = entries.count - 1
        if slot != last {
            entries[slot] = entries[last]
            titles[slot] = titles[last]
            labels[slot] = labels[last]
            slots[entries[slot].id] = slot
        }
        entries.removeLast()
        titles.removeLast()
        labels.removeLast()
        packIfWasteful()
    }

    /// Marks the recent picks, the latest first; `previous` are those marked before.
    mutating func markRecent(_ recent: [ShapeID], previous: [ShapeID]) {
        for id in previous { if let slot = slots[id] { entries[slot].recentRank = -1 } }
        for (rank, id) in recent.enumerated() { if let slot = slots[id] { entries[slot].recentRank = rank } }
    }

    /// A shape's title folded, as the path matcher takes it; made once and kept.
    mutating func label(at slot: Int) -> FuzzyMatcher.Label {
        if let label = labels[slot] { return label }
        let label = FuzzyMatcher.Label(titles[slot])
        labels[slot] = label
        return label
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
