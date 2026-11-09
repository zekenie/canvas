import Adornments
import Canvas

// Connections drawn together (arrow-look 2.7): where several connections are drawn on one path, they are one line or lines
// drawn apart, worked out from where their ends are shown, never stored. The arrows of a folded group end at the group's line
// and so coincide: the first in paint order leads, drawn once with a count on its pill ("writes · 9"), and the others are its
// members, drawn, hit and spoken by it. Connections with the same two drawn ends on different channels (a writes and a reads
// from one row to one table) bow apart, each its own line and pill (a slot of several). Connections that end where others from
// their shape end (six rows into one table, two keys into one row) are fanned: each comes in at an angle of its own and its pill
// slides toward its other end. A line to a shape written as lines as a whole comes in at a row clear of the rows other lines end
// at. One provider answers, the plugin that owns what is folded (LineRows); the connector reads it as it works out a
// connection's geometry.

/// How a connection is drawn among those that share its path: what the connector reads (`ConnectionBundle.input`), provided by
/// the plugin that folds shapes' rows. A connection with none of it has no answer (nil), and is drawn as ever.
public struct ConnectionBundle: Hashable, Sendable {
    /// Its place in a bundle: drawn for several, drawn by another, or neither.
    public enum Role: Hashable, Sendable {
        /// Drawn as itself.
        case alone
        /// Drawn once for `count` connections (itself among them), whose end at a fold's line stands at `standing` (a closed
        /// header): its pill says the count ("writes · 9"), VoiceOver "9 arrows".
        case lead(count: Int, standing: PartAddress?)
        /// Drawn, hit and spoken by `lead`: not on its own.
        case member(lead: ShapeID)
    }

    /// One of a connection's ends, as the connector says them: where it starts, or where it ends.
    public enum End: Hashable, Sendable {
        case start, end
    }

    /// An end it shares with connections from the same shape, which come in at angles of their own: `index` of `count`, in the
    /// order their other ends are along that shape (top to bottom).
    public struct Fan: Hashable, Sendable {
        public let end: End
        public let index: Int
        public let count: Int

        public init(end: End, index: Int, count: Int) {
            self.end = end
            self.index = index
            self.count = count
        }

        /// Where it is among the fan, from -1 (the first) to 1 (the last); 0 for the middle, or a fan of one.
        public var spread: Double { count > 1 ? Double(index) / Double(count - 1) * 2 - 1 : 0 }
    }

    public var role: Role
    /// Its place among the connections drawn with the same two ends (bundles' leads among them), 0 ..< `slots`: each bows apart
    /// by its slot, its pill on a line of its own. One slot for a connection that shares its ends with none.
    public var slot: Int
    public var slots: Int
    /// The ends it shares with others from one shape, fanned.
    public var fans: [Fan]
    /// For an end bound to a shape written as lines as a whole: the row it comes in at, clear of the rows other lines end at
    /// (nil: the kind's own entry).
    public var entries: [End: PartID]

    public init(role: Role = .alone, slot: Int = 0, slots: Int = 1, fans: [Fan] = [], entries: [End: PartID] = [:]) {
        self.role = role
        self.slot = slot
        self.slots = slots
        self.fans = fans
        self.entries = entries
    }

    /// Says nothing: drawn as ever.
    public var isPlain: Bool { role == .alone && slots <= 1 && fans.isEmpty && entries.isEmpty }

    /// Drawn by another, its lead.
    public var lead: ShapeID? { if case .member(let lead) = role { lead } else { nil } }

    /// How many connections it draws for: its bundle's count for a lead, else 1.
    public var count: Int { if case .lead(let count, _) = role { count } else { 1 } }

    /// The fan at `end`, if it has one.
    public func fan(at end: End) -> Fan? { fans.first { $0.end == end } }

    /// How far the middle of its slot bows from the path all of them would take, in slots: 0 for one alone, -0.5 and 0.5 for two.
    public var slotOffset: Double { Double(slot) - Double(slots - 1) / 2 }

    /// The answer the connector reads as it lays a connection out: provided by one plugin (the fold's owner).
    public static let input = LayoutInputKey<ConnectionBundle>("connection-bundle")
}

extension CanvasEditor {
    /// The bundles of these connections changed with no commit to them (a fold, another connection drawn on their path): their
    /// geometry and the pill on each are worked out again.
    public func connectionBundlesDidChange(_ ids: Set<ShapeID>) {
        guard !ids.isEmpty else { return }
        shapesDidChangeLayout(Array(ids))
        adornmentsDidChange(for: ids)
    }

    /// How `id` is drawn among the connections that share its path, as its layout reads it now; nil for one drawn as ever.
    public func connectionBundle(of id: ShapeID) -> ConnectionBundle? {
        guard let record = document[id] ?? shape(inFile: id) else { return nil }
        return shapeContext.layoutInput(ConnectionBundle.input, of: record)
    }
}
