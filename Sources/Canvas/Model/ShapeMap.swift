/// A dictionary keyed by shape id that is copied a piece at a time: its entries are kept in shards, and
/// a copy shares every shard with the original until one of them writes to it, which copies the shard
/// the write reaches and the short list of shards, never the rest. So a board's lookup tables (where
/// each shape is in its stack, `ShapeStack`; which board each shape of a file is on, `CanvasFile`)
/// cost a commit what the commit changed, whatever the board holds, where one plain dictionary is
/// copied whole by the first write after a copy was made.
///
/// An id's shard is chosen by its spread bits (`ShapeID.spread`), not by hashing it, so a lookup costs
/// one more array read than a dictionary's. The shards number a power of two, and the map spreads
/// over more of them as it fills (a pass over its entries, each time it has grown fourfold), so a
/// shard holds some 128 to 1,024 entries whatever the size of the map.
struct ShapeMap<Value: Sendable>: Sendable {
    /// The entries: an id's are in `shards[id.spread & (shards.count - 1)]`. A power of two of them,
    /// or none while the map has never held an entry.
    private var shards: [[ShapeID: Value]] = []
    private(set) var count = 0

    #if DEBUG
    /// How many entries a shard holds on average, at most, when the map has just spread over shards,
    /// and the most before it does again. Debug builds' (the tests') are small, so a map of a few
    /// hundred entries spreads over shards again and again.
    private static var roomy: Int { 4 }
    private static var crowded: Int { 16 }
    #else
    private static var roomy: Int { 256 }
    private static var crowded: Int { 1024 }
    #endif

    init() {}

    /// A map to hold about `expected` entries, with room for them in its shards.
    init(expecting expected: Int) {
        guard expected > 0 else { return }
        let wanted = Self.shardCount(for: expected)
        shards = [[ShapeID: Value]](repeating: [:], count: wanted)
        let each = expected / wanted + expected / wanted / 4 + 1
        for shard in shards.indices { shards[shard].reserveCapacity(each) }
    }

    /// The fewest shards, a power of two, that hold `entries` entries at no more than `roomy` each on average.
    private static func shardCount(for entries: Int) -> Int {
        var wanted = 1
        while entries > wanted * roomy { wanted *= 2 }
        return wanted
    }

    private func shard(of id: ShapeID) -> Int { id.spread & (shards.count - 1) }

    subscript(id: ShapeID) -> Value? {
        get {
            guard !shards.isEmpty else { return nil }
            return shards[shard(of: id)][id]
        }
        set {
            if let newValue { updateValue(newValue, forKey: id) } else { removeValue(forKey: id) }
        }
    }

    /// Sets the entry, returning the one it replaced. A write to a shard a copy shares copies the
    /// shard, even when it sets what was there: ask first (`self[id]`) when most writes would not change.
    @discardableResult
    mutating func updateValue(_ value: Value, forKey id: ShapeID) -> Value? {
        if shards.isEmpty { shards = [[:]] }
        let old = shards[shard(of: id)].updateValue(value, forKey: id)
        if old == nil {
            count += 1
            if count > shards.count * Self.crowded { spread() }
        }
        return old
    }

    /// Removes the entry, returning it; nothing happens, and nothing is copied, for an id with none.
    @discardableResult
    mutating func removeValue(forKey id: ShapeID) -> Value? {
        guard !shards.isEmpty, shards[shard(of: id)][id] != nil else { return nil }
        count -= 1
        return shards[shard(of: id)].removeValue(forKey: id)
    }

    /// Spreads the entries over more shards, as many as `roomy` asks for.
    private mutating func spread() {
        let wanted = Self.shardCount(for: count)
        guard wanted > shards.count else { return }
        var spread = [[ShapeID: Value]](repeating: [:], count: wanted)
        let each = count / wanted + count / wanted / 4 + 1
        for shard in spread.indices { spread[shard].reserveCapacity(each) }
        for old in shards { for (id, value) in old { spread[id.spread & (wanted - 1)][id] = value } }
        shards = spread
    }
}
