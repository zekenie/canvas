import CoreGraphics

/// How one frame's tinted groups (`Outlines.tinted`) stand round each shape: what the pass that
/// strokes them asks, and what overlays that decorate shapes beyond them do
/// (`OverlayContext.tintedOutset(of:)`). A frame that has a group makes one, and each answer is
/// worked out when it's first asked for, and only then, for what's asked: the shapes in view.
///
/// A shape is in a ring for each group it's in (`TintedOutlines.ring`), and one that's outlined in
/// full too (selected, or the hint) has its tint one ring further out, clear of the line the
/// selection draws over where ring 0 stands.
@MainActor
final class TintedRings {
    /// A few shapes outlined in full are looked for one by one, which compares ids, cheaper than
    /// hashing them; more, in a set made once.
    private static let fewOutlined = 8

    private let outlines: Outlines
    private var outlined: Set<ShapeID>?
    private var outermost: [ShapeID: Int]?

    init(_ outlines: Outlines) {
        self.outlines = outlines
    }

    /// Whether any shape is outlined in full: with none, no tint stands further out.
    var hasOutlinedInFull: Bool { !outlines.shapes.isEmpty }

    /// Whether the shape is outlined in full too: selected, or the hint, which the core strokes
    /// alike. A hover's faint outline is over a tint, and moves none.
    func isOutlinedInFull(_ id: ShapeID) -> Bool {
        let full = outlines.shapes
        guard full.count > Self.fewOutlined else { return full.contains(id) }
        if outlined == nil { outlined = Set(full) }
        return outlined?.contains(id) == true
    }

    /// The ring of the outermost tinted outline round the shape, counting the one further out of a
    /// shape outlined in full; nil for a shape no group has. The first ask makes it for every shape
    /// the groups name, one pass over them.
    func outermostRing(of id: ShapeID) -> Int? {
        if outermost == nil { outermost = Self.outermostRings(of: outlines.tinted) }
        guard let ring = outermost?[id] else { return nil }
        return ring + (isOutlinedInFull(id) ? 1 : 0)
    }

    /// The outermost ring any shape could be in: one pass over the groups, not the shapes, for an
    /// overlay that culls by how far its decoration reaches.
    var greatestRing: Int {
        outlines.tinted.reduce(0) { max($0, $1.ring) } + (hasOutlinedInFull ? 1 : 0)
    }

    private static func outermostRings(of groups: [TintedOutlines]) -> [ShapeID: Int] {
        var rings: [ShapeID: Int] = [:]
        rings.reserveCapacity(groups.reduce(0) { $0 + $1.shapes.count })
        for group in groups {
            let ring = max(group.ring, 0)
            for id in group.shapes { rings[id] = max(rings[id] ?? 0, ring) }
        }
        return rings
    }
}
