/// The shapes of the lists a frame outlines, as sets to ask what is in them, kept from frame to frame. A list of
/// thousands (⌘A's) with few of its shapes in view is outlined by asking each shape in view whether it is in it, and
/// a set made of the list every frame would cost what looking at each shape in it did.
///
/// A list is the same as one kept when it holds the same ids in the same order, which for the list the frame is
/// handed again is a comparison of the storage they share. As many are kept as the frame has lists (`keep(atLeast:)`: the
/// selection, a faint group and each tinted group, never fewer than a few), so a frame that outlines them all finds each, in
/// whatever order: a cache of fewer, cycled through in the same order every frame, would miss every time and make every set again.
///
/// It keeps the tinted groups' outermost rings too (`outermostRings(of:)`), for as long as the groups are the same.
@MainActor
final class OutlineMembers {
    private static let fewest = 4

    private var kept = OutlineMembers.fewest
    private var lists: [(ids: [ShapeID], members: Set<ShapeID>)] = []
    private var rings: (groups: [TintedOutlines], rings: [ShapeID: Int])?
    #if DEBUG
    /// How many sets have been made (debug builds).
    private(set) var made = 0
    /// How many maps of rings have been made (debug builds).
    private(set) var ringMapsMade = 0
    #endif

    /// Room for `count` lists (at least a few), from this frame on: the lists the frame is about to outline.
    func keep(atLeast count: Int) {
        kept = max(Self.fewest, count)
        if lists.count > kept { lists.removeLast(lists.count - kept) }
    }

    /// The outermost ring of every shape the groups name (`TintedRings`): one pass over them, made again only when the groups
    /// aren't the ones it was made for.
    func outermostRings(of groups: [TintedOutlines]) -> [ShapeID: Int] {
        if let rings, rings.groups == groups { return rings.rings }
        var map: [ShapeID: Int] = [:]
        map.reserveCapacity(groups.reduce(0) { $0 + $1.shapes.count })
        for group in groups {
            let ring = max(group.ring, 0)
            for id in group.shapes { map[id] = max(map[id] ?? 0, ring) }
        }
        #if DEBUG
        ringMapsMade += 1
        #endif
        rings = (groups, map)
        return map
    }

    /// The shapes in `ids`.
    func members(of ids: [ShapeID]) -> Set<ShapeID> {
        if let found = lists.firstIndex(where: { $0.ids == ids }) {
            if found != 0 { lists.insert(lists.remove(at: found), at: 0) }
            return lists[0].members
        }
        let members = Set(ids)
        #if DEBUG
        made += 1
        #endif
        lists.insert((ids, members), at: 0)
        if lists.count > kept { lists.removeLast() }
        return members
    }
}
