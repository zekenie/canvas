/// The shapes of the lists a frame outlines, as sets to ask what is in them, kept from frame to frame. A list of
/// thousands (⌘A's) with few of its shapes in view is outlined by asking each shape in view whether it is in it, and
/// a set made of the list every frame would cost what looking at each shape in it did.
///
/// A list is the same as one kept when it holds the same ids in the same order, which for the list the frame is
/// handed again is a comparison of the storage they share. The last few are kept, so a frame that outlines a
/// selection, a faint group and tinted groups finds each.
@MainActor
final class OutlineMembers {
    private static let kept = 4

    private var lists: [(ids: [ShapeID], members: Set<ShapeID>)] = []
    #if DEBUG
    /// How many sets have been made (debug builds).
    private(set) var made = 0
    #endif

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
        if lists.count > Self.kept { lists.removeLast() }
        return members
    }
}
