import Canvas

/// Every mentionable shape on a board, ready for the picker to match: each shape's appearance, and
/// its label folded once (`MentionMatcher.Label`), the keys of every label back to back in one
/// buffer, so a keystroke reads them in two linear passes with nothing to retain or allocate per
/// shape. A renamed shape's new keys go at the end; the buffer is packed again once half of it is
/// keys no shape uses.
@MainActor
struct MentionCatalog {
    /// One shape's place in the catalog: plain values only, so reading one costs nothing more.
    struct Entry {
        let id: ShapeID
        /// Its label's keys in `keys`.
        var start: Int
        var count: Int
        /// Its label's length in characters, for ties.
        var labelLength: Int
        var isPlaceholder: Bool
        /// Where it is among the recent picks, the latest 0; -1 if it isn't one.
        var recentRank: Int
    }

    private(set) var entries: [Entry] = []
    /// Beside `entries`, index for index.
    private(set) var appearances: [MentionAppearance] = []
    private(set) var keys: [UInt32] = []
    private var slots: [ShapeID: Int] = [:]
    /// Keys in `keys` no entry uses any longer.
    private var unused = 0

    var count: Int { entries.count }

    func slot(of id: ShapeID) -> Int? { slots[id] }

    func contains(_ id: ShapeID) -> Bool { slots[id] != nil }

    func appearance(of id: ShapeID) -> MentionAppearance? { slots[id].map { appearances[$0] } }

    /// Puts a shape in, or updates it: its label's keys are folded again only if its label changed.
    mutating func set(_ id: ShapeID, _ appearance: MentionAppearance, recentRank: Int) {
        if let slot = slots[id] {
            if appearances[slot].label != appearance.label {
                unused += entries[slot].count
                let start = keys.count
                entries[slot].labelLength = MentionMatcher.appendKeys(of: appearance.label, to: &keys)
                entries[slot].start = start
                entries[slot].count = keys.count - start
            }
            entries[slot].isPlaceholder = appearance.isPlaceholder
            entries[slot].recentRank = recentRank
            appearances[slot] = appearance
        } else {
            let start = keys.count
            let length = MentionMatcher.appendKeys(of: appearance.label, to: &keys)
            slots[id] = entries.count
            entries.append(Entry(id: id, start: start, count: keys.count - start, labelLength: length,
                                 isPlaceholder: appearance.isPlaceholder, recentRank: recentRank))
            appearances.append(appearance)
        }
        packIfWasteful()
    }

    /// Takes a shape out: the last entry takes its place.
    mutating func remove(_ id: ShapeID) {
        guard let slot = slots.removeValue(forKey: id) else { return }
        unused += entries[slot].count
        let last = entries.count - 1
        if slot != last {
            entries[slot] = entries[last]
            appearances[slot] = appearances[last]
            slots[entries[slot].id] = slot
        }
        entries.removeLast()
        appearances.removeLast()
        packIfWasteful()
    }

    /// Marks the recent picks, the latest first; `previous` are those marked before.
    mutating func markRecent(_ recent: [ShapeID], previous: [ShapeID]) {
        for id in previous { if let slot = slots[id] { entries[slot].recentRank = -1 } }
        for (rank, id) in recent.enumerated() { if let slot = slots[id] { entries[slot].recentRank = rank } }
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
