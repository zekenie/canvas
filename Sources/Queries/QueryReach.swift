import Canvas
import Topology

// A reach: everything a one-step query leads to from a shape, and what it leads to from there, until
// nothing new is found (`QueryState.reaches(_:)`): the shapes downstream of one, or upstream of it,
// each with how far it is and how the reach divides on the way. Asked in one capture and one
// evaluation, off the main actor, for what a hover's lights show.

/// A step followed from a shape, as a light says it: the query that finds what one shape leads to,
/// and, if the step is lit with the connections that run it, the query that finds those from the
/// same shape.
public struct QueryReachRequest: Sendable {
    /// The one-hop query, written with `:scope`, which is the shape stepped from (a light's `query(":scope")`).
    public var step: String
    /// The query that finds the connections run between the shape stepped from and the shapes it
    /// steps to, written with `:scope` too (a light's `between?(":scope")`); nil for none.
    public var between: String?
    /// Where the walk starts: never in its answer, whatever cycle leads back to it.
    public var start: ShapeID
    /// The edges both queries read.
    public var edges: EdgeView
    /// How strong a shape at a hop with a share is, for choosing among candidates: the end a connection into a stand-in stands for
    /// when it stands for several, and the one of several runs of a connection that is spared. The greater is chosen, a tie going
    /// to the nearer hop and then the greater share. The caller owns the number (the engine knows no light's look); nil chooses
    /// by the nearest hop, then the greatest share.
    public var strength: (@Sendable (_ hop: Int, _ share: Double) -> Double)?

    public init(step: String, between: String? = nil, start: ShapeID, edges: EdgeView = .resolved,
                strength: (@Sendable (_ hop: Int, _ share: Double) -> Double)? = nil) {
        self.step = step
        self.between = between
        self.start = start
        self.edges = edges
        self.strength = strength
    }
}

/// What a reach found: the shapes it met, nearest hop first, each with the hop it is at and how the
/// reach divided on the way to it, and the connections it ran, travelled or spared.
///
/// A shape's **hop** is its shortest distance from the start. Its **ways** are the distinct shapes
/// of the hop before whose step leads to it. Its **share** is 1 at hop 1 and, past it, the sum, over
/// its ways in, of their share divided by how many shapes of the next hop each leads to: what
/// reaches a shape splits among what it reaches, and adds up where paths meet.
public struct QueryReach: Sendable, Equatable {
    /// What a connection between two shapes of the reach says of each end.
    public struct End: Sendable, Equatable {
        public var hop: Int
        public var share: Double

        public init(hop: Int, share: Double) {
            self.hop = hop
            self.share = share
        }
    }

    /// A connection between two shapes of the reach (or the start) that the reach did not travel.
    public struct Spared: Sendable, Equatable {
        public var carrier: ShapeID
        /// The end the shape stepped from is, and the end the connection runs to: the start's is hop 0, share 1.
        public var from: End
        public var to: End

        public init(carrier: ShapeID, from: End, to: End) {
            self.carrier = carrier
            self.from = from
            self.to = to
        }
    }

    /// The shapes met: nearest hop first, in no order within one; the start is not among them. A
    /// stand-in the reach went into through a connection (an arrow bound to a pill) is among them, at
    /// the hop and share of what it stands for (the nearest hop of those, then the greatest share).
    public var ids: [ShapeID]
    /// Each shape's hop, `>= 1`, aligned with `ids`.
    public var hops: [Int]
    /// Each shape's ways in, `>= 1`, aligned with `ids`.
    public var ways: [Int]
    /// Each shape's share, `> 0`, aligned with `ids`.
    public var shares: [Double]
    /// The connections the reach travelled, from a hop to the next, in the order met.
    public var carriers: [ShapeID]
    /// The hop of the shape each connection leads to (the strongest, if it leads to several), aligned with `carriers`.
    public var carrierHops: [Int]
    /// The share of that shape, aligned with `carriers`.
    public var carrierShares: [Double]
    /// The connections between two shapes of the reach, or between one and the start, that it didn't
    /// travel (within a hop, or back to an earlier one: a cycle's); none that is also travelled. One for a connection, the run
    /// whose weaker end is the strongest if it has several.
    public var spared: [Spared]
    /// `editor.revision` as the file was taken up.
    public var revision: Int

    public init(ids: [ShapeID], hops: [Int], ways: [Int], shares: [Double], carriers: [ShapeID], carrierHops: [Int], carrierShares: [Double],
                spared: [Spared], revision: Int) {
        self.ids = ids
        self.hops = hops
        self.ways = ways
        self.shares = shares
        self.carriers = carriers
        self.carrierHops = carrierHops
        self.carrierShares = carrierShares
        self.spared = spared
        self.revision = revision
    }
}

/// A request of a batch, checked: its place, its plans and itself.
struct BatchedReach: Sendable {
    let index: Int
    let step: QueryPlan
    let between: QueryPlan?
    let request: QueryReachRequest
}
