import Canvas
import CoreGraphics
import Foundation
import Queries

/// What one light found for a shape, as the landing reads it: every shape and connection it lit, each
/// with its hop and share (a one-hop answer's all at hop 1, share 1), and the connections between two
/// shapes of the reach it didn't travel, each with the strength the dim keeps it at and the tier it
/// arrives in. Plain values, made from the engine's answer, so the landing runs off the main actor.
struct ReachFound: Sendable, Equatable {
    var ids: [ShapeID] = []
    var hops: [Int] = []
    var shares: [Double] = []
    var spared: [Spared] = []

    struct Spared: Sendable, Equatable {
        var carrier: ShapeID
        var fade: CGFloat
        var tier: Int
    }

    /// One hop's matches: each at hop 1, share 1, the connections with them.
    init(oneHop ids: [ShapeID]) {
        self.ids = ids
        hops = Array(repeating: 1, count: ids.count)
        shares = Array(repeating: 1, count: ids.count)
    }

    /// A reach: its shapes, then the connections it travelled at their far ends' hops and shares, and
    /// those it spared at their weaker end's strength (no more than `ReachStyle.sparedMost`), arriving
    /// with their later end.
    init(_ reach: QueryReach) {
        ids = reach.ids + reach.carriers
        hops = reach.hops + reach.carrierHops
        shares = reach.shares + reach.carrierShares
        spared = reach.spared.map { spared in
            let from = ReachStyle.strength(hop: spared.from.hop, share: spared.from.share)
            let to = ReachStyle.strength(hop: spared.to.hop, share: spared.to.share)
            let weaker = from <= to ? spared.from : spared.to
            let fade = min(ReachStyle.fade(hop: weaker.hop, strength: min(from, to)), ReachStyle.sparedMost)
            return Spared(carrier: spared.carrier, fade: fade, tier: ReachLanding.tier(max(spared.from.hop, spared.to.hop, 1)))
        }
    }
}

/// Where a reach is drawn on the board shown, worked out once an answer lands, off the main actor,
/// from the file as it was then: each match as itself on the board shown, else as the shape there
/// that holds it (a subboard's card, at the strongest of what it holds), none on a board above; each
/// light's in rings as the lights shown together take them; in groups by tier (the hop, the fourth
/// and on together), ring step and ring, made once, so a step of the pulse only picks groups; and the
/// dim's focus for each step of the pulse.
struct ReachLanding: Sendable {
    /// The shape it's for.
    let subject: ShapeID
    /// Where the shape is drawn on the board shown: itself, its card, or nowhere.
    let subjectDrawn: ShapeID?
    /// Every shape and connection any light matched, whichever keys show it: what a change must touch
    /// to ask again.
    let matched: Set<ShapeID>
    /// The shapes on the board shown a match is drawn as where it isn't on it, and the subject's.
    let cards: Set<ShapeID>
    /// What shows for each set of keys some light is shown with.
    let shown: [Modifiers: Shown]
    /// Whether it was worked out on the main thread, which it never should be.
    var madeOnMainThread = false

    /// What the lights shown with one set of keys light.
    struct Shown: Sendable {
        /// Each group of rings: one light's shapes of one tier, at one ring step, in one ring; by light,
        /// then ring, then tier, then step.
        var groups: [Group]
        /// The dim's focus at each step of the pulse, `0...ReachStyle.pulseTiers`.
        var focus: [[ShapeID: CGFloat]]
    }

    struct Group: Sendable, Equatable {
        var light: Int
        var tier: Int
        var step: Int
        var ring: Int
        var shapes: [ShapeID]
    }

    /// The pulse's tier for a hop: 1, 2, 3, and the fourth on together.
    static func tier(_ hop: Int) -> Int { min(max(hop, 1), ReachStyle.pulseTiers) }
    /// The last tier shown at a step of the pulse: hop 1 alone at its first.
    static func lastTier(atStep step: Int) -> Int { min(step + 1, ReachStyle.pulseTiers) }
    /// The tier arriving at a step of the pulse, drawn as hop 1 is for that step; none at the first and once settled.
    static func arriving(atStep step: Int) -> Int? { step >= 1 && step < ReachStyle.pulseTiers ? step + 1 : nil }

    /// One drawn shape of a light: its nearest hop and strongest strength.
    private struct Drawn {
        var hop: Int
        var strength: Double
    }

    /// Lands `found` (each light's, in light order, nil for one that found nothing or was refused),
    /// whose keys are `keys`, for `subject`, on `board` of `file`.
    static func land(_ found: [ReachFound?], keys: [Modifiers], subject: ShapeID, file: CanvasFile, board: BoardID) -> ReachLanding {
        var holders: [BoardID: ShapeID?] = [:]
        func drawn(_ id: ShapeID) -> ShapeID? {
            guard let on = file.board(containing: id) else { return nil }
            if on == board { return id }
            if let known = holders[on] { return known }
            let holder = file.shape(on: board, holding: id)
            holders[on] = holder
            return holder
        }
        let subjectDrawn = drawn(subject)
        let card = subjectDrawn.flatMap { $0 == subject ? nil : $0 }
        var matched: Set<ShapeID> = []
        matched.reserveCapacity(found.reduce(0) { $0 + ($1?.ids.count ?? 0) + ($1?.spared.count ?? 0) })
        // Each light's drawn shapes, and its spared connections on the board shown.
        var lit: [[ShapeID: Drawn]] = []
        var order: [[ShapeID]] = []
        var spared: [[ReachFound.Spared]] = []
        for light in found {
            var shapes: [ShapeID: Drawn] = [:], seen: [ShapeID] = [], kept: [ReachFound.Spared] = []
            if let light {
                matched.formUnion(light.ids)
                shapes.reserveCapacity(light.ids.count)
                for index in light.ids.indices {
                    guard let shape = drawn(light.ids[index]), shape != subject, shape != card else { continue }
                    let strength = ReachStyle.strength(hop: light.hops[index], share: light.shares[index])
                    if var known = shapes[shape] {
                        known.hop = min(known.hop, light.hops[index])
                        known.strength = max(known.strength, strength)
                        shapes[shape] = known
                    } else {
                        shapes[shape] = Drawn(hop: light.hops[index], strength: strength)
                        seen.append(shape)
                    }
                }
                for connection in light.spared {
                    matched.insert(connection.carrier)
                    if file.board(containing: connection.carrier) == board { kept.append(connection) }
                }
            }
            lit.append(shapes)
            order.append(seen)
            spared.append(kept)
        }
        var shown: [Modifiers: Shown] = [:]
        for set in Set(keys) {
            let lights = keys.indices.filter { keys[$0] == set }
            shown[set] = Self.shown(lights, lit: lit, order: order, spared: spared, subject: subjectDrawn)
        }
        return ReachLanding(subject: subject, subjectDrawn: subjectDrawn, matched: matched, cards: Set(holders.values.compactMap { $0 }), shown: shown,
                            madeOnMainThread: Thread.isMainThread)
    }

    /// The groups and the pulse's focus for the lights shown together, in light order: a shape's
    /// first light its first ring.
    private static func shown(_ lights: [Int], lit: [[ShapeID: Drawn]], order: [[ShapeID]], spared: [[ReachFound.Spared]],
                                          subject: ShapeID?) -> Shown {
        struct Key: Hashable { var ring: Int, tier: Int, step: Int }
        var groups: [Group] = []
        var rings: [ShapeID: Int] = [:]
        var steps = Array(repeating: [ShapeID: CGFloat](), count: ReachStyle.pulseTiers + 1)
        if let subject { for step in steps.indices { steps[step][subject] = 1 } }
        func keep(_ shape: ShapeID, tier: Int, fade: CGFloat) {
            for step in steps.indices where tier <= lastTier(atStep: step) {
                let strength = arriving(atStep: step) == tier ? 1 : fade
                if strength > steps[step][shape] ?? 0 { steps[step][shape] = strength }
            }
        }
        for light in lights {
            var made: [Key: [ShapeID]] = [:]
            for shape in order[light] {
                guard let found = lit[light][shape], let step = ReachStyle.ringStep(found.strength) else { continue }
                let ring = rings[shape, default: 0]
                rings[shape] = ring + 1
                let tier = tier(found.hop)
                made[Key(ring: ring, tier: tier, step: step), default: []].append(shape)
                keep(shape, tier: tier, fade: ReachStyle.fade(hop: found.hop, strength: found.strength))
            }
            for key in made.keys.sorted(by: { ($0.ring, $0.tier, -$0.step) < ($1.ring, $1.tier, -$1.step) }) {
                groups.append(Group(light: light, tier: key.tier, step: key.step, ring: key.ring, shapes: made[key] ?? []))
            }
            for connection in spared[light] { keep(connection.carrier, tier: connection.tier, fade: connection.fade) }
        }
        return Shown(groups: groups, focus: steps)
    }
}
