import CoreGraphics
import Geometry

/// What settling shapes did (`Transaction.settle(_:)`).
public enum Settlement: Equatable, Sendable {
    /// Each shape it nudged, by how far it moved (world units): what was put down, what that holds,
    /// and what rode with it; empty when nothing needed nudging. What `CanvasEditor.glide` takes.
    case settled(nudges: [ShapeID: CGPoint])
    /// A read-only container (a locked frame) would have taken what was put down: nothing changed,
    /// and services hear it was refused (`EditorService.didRefuseChanges`), so it shakes.
    case refused(by: ShapeID)

    /// What it nudged: none for a refusal.
    public var nudges: [ShapeID: CGPoint] {
        if case .settled(let nudges) = self { return nudges }
        return [:]
    }

    /// How far inside a container's edge what's nudged in comes to rest, and how far outside one
    /// what's nudged out, in world units: the edge stays clear to grab. A resize keeps a shape in a
    /// container this far inside its edge too (Selection's).
    public static var gap: CGFloat { Style.containerGap }
}

// The in-or-out rule: nothing sits across a container's edge. A shape put down (dropped, placed,
// pasted, drawn) is judged by area: if more than half of its box is inside a container, it goes in
// that one (where containers nest, the innermost holding most of it that it fits in), nudged fully in
// if it hangs over the edge, to `Style.containerGap` inside it, so the edge stays clear to grab;
// otherwise it's in none of them, and nudged fully out of any it reaches into, as far outside. Shapes
// put down together from one container are judged as one, by their summed area, and nudged together
// by one translation, so their arrangement holds; those from different containers, container by
// container. A group that doesn't fit the container holding most of it is judged shape by shape, and a
// shape too big for a container can't be in it. Read-only shapes are never nudged, and stay where they
// are in or out.
extension Transaction {
    /// Settles shapes put down (a drag's drop, a placement, a paste, a draw) by the in-or-out rule:
    /// each goes into the container holding most of it, or out of every container, nudged fully in or
    /// fully out if it hangs over an edge. They're judged together by the container each was in (as
    /// a drag's selection may come from two); what they hold goes with them, and a shape that can't
    /// be in a container (an arrow) rides with them when all of them are judged as one, so what was
    /// put down together keeps its arrangement. Then each container among them takes in what it
    /// lands on (`settle(container:)`). Read-only shapes stay as they are. A read-only container (a
    /// locked frame) takes nothing: if any of them would go into one, nothing changes, services hear
    /// that container refused, and the answer names it, for the caller to send them back (a drop) or
    /// report it. Joining a container raises a shape just above what it holds (`setContainer`).
    /// Nothing happens without a `ShapeContaining` kind installed. O(the board).
    public mutating func settle(_ ids: some Sequence<ShapeID>) -> Settlement {
        let kinds = registry.containingKinds
        guard !kinds.isEmpty else { return .settled(nudges: [:]) }
        let put = Set(ids).compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }.filter { !holds($0) }
        let putIDs = Set(put.map(\.id))
        // Judged: what can be in a container, but what's in another of them (it goes with that one).
        var judged: [AnyShapeRecord] = [], riders: [ShapeID] = []
        for record in put {
            guard record.box != nil else {
                riders.append(record.id)
                continue
            }
            if record.namesContainer, document.containers(of: record.id, containingKinds: kinds).contains(where: putIDs.contains) { continue }
            judged.append(record)
        }
        guard !judged.isEmpty else { return .settled(nudges: [:]) }
        var excluded = putIDs
        for record in judged { excluded.formUnion(document.descendants(of: record.id, containingKinds: kinds)) }
        let sites = ContainerRule.sites(containerIDs(excluding: excluded), excluding: [], in: document, containingKinds: kinds)
        // Grouped by the container each was in, in the order they come; each worked out before
        // anything changes, so a refusal changes nothing.
        var origins: [ShapeID?] = [], groups: [ShapeID?: [AnyShapeRecord]] = [:]
        for record in judged {
            let origin = document.container(of: record, containingKinds: kinds)
            if groups[origin] == nil { origins.append(origin) }
            groups[origin, default: []].append(record)
        }
        // By the frames they are laid out in (a note grown by its type is as big as it looks), read
        // from one context before anything changes.
        var frames: [ShapeID: CGRect] = [:]
        do {
            let context = shapes
            for record in judged { frames[record.id] = context.frame(of: record) }
        }
        var plans: [(members: [ShapeID], verdict: ContainerRule.Verdict)] = []
        for origin in origins {
            let members = groups[origin]!
            let boxes = members.map { frames[$0.id]! }
            if let verdict = verdict(for: boxes, together: true, among: sites) {
                plans.append((members.map(\.id), verdict))
            } else {
                for (member, box) in zip(members, boxes) {
                    plans.append(([member.id], verdict(for: [box], together: false, among: sites)!))
                }
            }
        }
        for plan in plans {
            guard let target = plan.verdict.target, let holder = document[target], holds(holder) else { continue }
            refused.insert(target)
            return .refused(by: target)
        }
        var nudges: [ShapeID: CGPoint] = [:]
        for plan in plans {
            join(plan.members, plan.verdict.target)
            guard plan.verdict.delta != .zero else { continue }
            for id in translated(Set(plan.members + (plans.count == 1 ? riders : [])), by: plan.verdict.delta) {
                nudges[id] = (nudges[id] ?? .zero) + plan.verdict.delta
            }
        }
        // A container put down takes in what it lands on.
        for record in judged where registry.isContainer(record) {
            for (id, delta) in settle(container: record.id) { nudges[id] = (nudges[id] ?? .zero) + delta }
        }
        return .settled(nudges: nudges)
    }

    /// Settles shapes on another board of the file, in this transaction: `settle(_:)`'s rule there,
    /// against that board as this transaction leaves it (`contents(of:)`), so what a move took there
    /// (`move(_:to:)`) is put down as a drop or a placement puts it down on the board shown, a
    /// container among it taking in what it lands on. What this transaction brought there (moved, or
    /// in with its owner) isn't held, as what it adds here isn't. A refusal (`.refused(by:)`) changes
    /// nothing there and is noted in `refusedShapes`, as `settle(_:)`'s is, so a caller in
    /// `editor.transactWhole` drops the whole move and says so, as Transform drops a turn.
    /// The nudges are on that board, where nothing glides. On this transaction's own board it's
    /// `settle(_:)`; a board the editor couldn't show once this transaction commits settles nothing.
    /// `board` can't be one going with a shape this transaction deleted. O(that board).
    @discardableResult
    public mutating func settle(_ ids: some Sequence<ShapeID>, on board: BoardID) -> Settlement {
        guard board != self.board else { return settle(ids) }
        guard var there = transaction(on: board) else { return .settled(nudges: [:]) }
        let settlement = there.settle(ids)
        take(there)
        return settlement
    }

    /// Settles what a container was resized, moved or drawn onto, by the in-or-out rule: each shape
    /// in it that hangs over its edge, and each shape at its level (in the container it's in, or on
    /// the board) that it reaches, judged one by one (`settle(_:)`'s rule), so the container takes in
    /// what's mostly inside it and nudges out what's mostly outside, and keeps what's in it that
    /// hangs over its edge, nudged in, unless it's mostly outside, when it leaves. Read-only shapes
    /// stay as they are, in or out, and so does a shape a read-only container would take. The
    /// container itself isn't judged: one put down, or grown across its own container's edge,
    /// settles first (`settle(_:)`). Returns what it nudged, by how far (world units), what they
    /// hold included. O(the board).
    @discardableResult
    public mutating func settle(container id: ShapeID) -> [ShapeID: CGPoint] {
        let kinds = registry.containingKinds
        guard let holder = document[id], registry.isContainer(holder), let edge = holder.box else { return [:] }
        let level = document.container(of: holder, containingKinds: kinds)
        // Judged by the frames they are laid out in, whose sizes are kept: one context reads them
        // (let go before anything changes), and each is put at its origin as it is by then.
        var judged: [ShapeID] = [], sizes: [ShapeID: CGSize] = [:]
        do {
            let context = shapes
            for member in document.contents(of: id, containingKinds: kinds) {
                if let record = document[member], let box = context.frame(of: record), !edge.contains(box), !holds(record) {
                    judged.append(member)
                    sizes[member] = box.size
                }
            }
            document.shapes.forEach { record in
                guard record.id != id, let box = context.frame(of: record), ContainerRule.overlap(box, edge) > 0,
                      document.container(of: record, containingKinds: kinds) == level, !holds(record) else { return }
                judged.append(record.id)
                sizes[record.id] = box.size
            }
        }
        guard !judged.isEmpty else { return [:] }
        // The containers, as they are: worked out again only once a container judged has moved or
        // joined another (what's raised into a container rises once, at the end).
        var sites = ContainerRule.sites(containerIDs(excluding: []), excluding: [], in: document, containingKinds: kinds)
        var nudges: [ShapeID: CGPoint] = [:], joined: [ShapeID: [ShapeID]] = [:]
        for shape in judged {
            // As the board is by now: one judged before may have moved, or taken it in.
            guard let record = document[shape], let origin = record.box?.origin, let size = sizes[shape] else { continue }
            let box = CGRect(origin: origin, size: size)
            let isContainer = registry.isContainer(record)
            var others = sites
            if isContainer {
                let excluded = Set([shape] + document.descendants(of: shape, containingKinds: kinds))
                others.removeAll { excluded.contains($0.id) }
            }
            guard let verdict = verdict(for: [box], together: false, among: others) else { continue }
            // A read-only container takes nothing new, one this transaction put down too (a locked
            // frame's copy, pasted: copies are locked).
            if let target = verdict.target, target != document.container(of: record, containingKinds: kinds),
               let into = document[target], isReadOnly(into) { continue }
            if name(verdict.target, for: shape), let target = verdict.target { joined[target, default: []].append(shape) }
            if verdict.delta != .zero {
                for moved in translated([shape], by: verdict.delta) { nudges[moved] = (nudges[moved] ?? .zero) + verdict.delta }
            }
            if isContainer { sites = ContainerRule.sites(containerIDs(excluding: []), excluding: [], in: document, containingKinds: kinds) }
        }
        for (target, shapes) in joined { raise(shapes, into: target) }
        return nudges
    }

    /// The containers on this board that could take something, but `excluded`: back to front.
    private func containerIDs(excluding excluded: Set<ShapeID>) -> [ShapeID] {
        let kinds = registry.containingKinds
        var found: [ShapeID] = []
        document.shapes.forEach { if kinds.contains($0.kind) && !$0.isOpaque && !excluded.contains($0.id) { found.append($0.id) } }
        return found
    }

    /// The rule over `boxes` among `sites`, the containers on the board as they are.
    private func verdict(for boxes: [CGRect], together: Bool, among sites: [ContainerRule.Site]) -> ContainerRule.Verdict? {
        ContainerRule.verdict(for: boxes, together: together, among: sites,
                              ancestors: { document.containers(of: $0, containingKinds: registry.containingKinds) })
    }
}

/// The in-or-out rule as geometry over boxes (world units), pure: where boxes put down together go,
/// and how far they're nudged. What `Transaction.settle` applies, and what a drag outlines as it goes
/// (`TranslatingSession`).
enum ContainerRule {
    /// A container something put down could go into, as the board is now.
    struct Site {
        let id: ShapeID
        let box: CGRect
        /// How many containers it's in.
        let depth: Int
        /// Where it is in the stack: of two as deep, the one in front wins.
        let index: Int
    }

    struct Verdict: Equatable {
        /// The container it goes into; nil for none (the board, or the container that holds them all).
        var target: ShapeID?
        /// How far it's nudged, in or out.
        var delta: CGPoint
    }

    /// `ids`' containers as `document` has them now, but `excluded`: those with a box.
    static func sites(_ ids: [ShapeID], excluding excluded: Set<ShapeID>, in document: CanvasDocument, containingKinds kinds: Set<ShapeKind>) -> [Site] {
        ids.compactMap { id in
            guard !excluded.contains(id), let index = document.index(of: id), let box = document.shapes[index].box else { return nil }
            return Site(id: id, box: box, depth: document.containers(of: id, containingKinds: kinds).count, index: index)
        }
    }

    /// Where `boxes` go, and how far they're nudged: into the innermost of `sites` holding more than
    /// half their summed area that their union fits in, nudged fully in if they hang over its edge;
    /// then clear of each other site they reach into, but that one and those it's in (`ancestors`),
    /// by the shortest way out of them all that keeps them in it (straight out of one, or out of one
    /// and then of the next it would reach into; none, and they stay). Put down `together`
    /// (several), a union that doesn't fit the innermost site holding most of it is nil: judged one
    /// by one instead.
    static func verdict(for boxes: [CGRect], together: Bool, among sites: [Site], ancestors: (ShapeID) -> [ShapeID]) -> Verdict? {
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        let holding = majority(of: boxes, among: sites)
        var target: Site?
        if let innermost = holding.first {
            if fits(union, in: innermost.box) {
                target = innermost
            } else if together, boxes.count > 1 {
                return nil
            } else {
                target = holding.dropFirst().first { fits(union, in: $0.box) }
            }
        }
        let into = target.map { nudge(union, into: $0.box) } ?? .zero
        let kept = target.map { Set([$0.id] + ancestors($0.id)) } ?? []
        let others = sites.filter { !kept.contains($0.id) }
        /// The other sites the boxes reach into, moved by `offset`, each with the boxes that do.
        func reached(_ offset: CGPoint) -> [(site: Site, boxes: CGRect)] {
            others.compactMap { site in
                let reaching = boxes.lazy.map { $0.offsetBy(dx: offset.x, dy: offset.y) }.filter { reaches($0, into: site.box) }
                    .reduce(CGRect.null) { $0.union($1) }
                return reaching.isNull ? nil : (site, reaching)
            }
        }
        func ways(from offset: CGPoint) -> [CGPoint] {
            reached(offset).flatMap { out($0.boxes, of: $0.site.box).map { CGPoint(x: offset.x + $0.x, y: offset.y + $0.y) } }
        }
        guard !reached(into).isEmpty else { return Verdict(target: target?.id, delta: into) }
        let straight = ways(from: into)
        let candidates = straight + straight.flatMap { ways(from: $0) }
        let clear = candidates.filter { offset in
            reached(offset).isEmpty && (target.map { $0.box.contains(union.offsetBy(dx: offset.x, dy: offset.y)) } ?? true)
        }
        let shortest = clear.min { hypot($0.x - into.x, $0.y - into.y) < hypot($1.x - into.x, $1.y - into.y) }
        return Verdict(target: target?.id, delta: shortest ?? into)
    }

    /// The site `boxes` go into, as one: the innermost holding more than half their summed area that
    /// their union fits in; nil for none.
    static func target(of boxes: [CGRect], among sites: [Site]) -> ShapeID? {
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull else { return nil }
        return majority(of: boxes, among: sites).first { fits(union, in: $0.box) }?.id
    }

    /// The sites holding more than half of `boxes`' summed area (or, for boxes with none, their
    /// middle), innermost first: the deepest, then the one in front. Not one their union covers
    /// whole: over all of a container, they're over it, not in it, as they're not across its edge
    /// (`reaches`), so a container's copy pasted on it stays beside it, not in it.
    static func majority(of boxes: [CGRect], among sites: [Site]) -> [Site] {
        let total = boxes.reduce(0) { $0 + area($1) }
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        let holding = sites.filter { site in
            guard !union.contains(site.box) else { return false }
            guard total > 0 else { return !union.isNull && site.box.contains(CGPoint(x: union.midX, y: union.midY)) }
            return boxes.reduce(0) { $0 + overlap($1, site.box) } * 2 > total
        }
        return holding.sorted { ($0.depth, $0.index) > ($1.depth, $1.index) }
    }

    /// Whether `union` can be inside `box`: no wider and no taller.
    static func fits(_ union: CGRect, in box: CGRect) -> Bool { union.width <= box.width && union.height <= box.height }

    /// How far to move `union`, which fits in `box`, so it's inside it: along an axis it hangs over,
    /// to `Style.containerGap` inside the edge (centered, where that's too tight); along one it
    /// doesn't, nowhere.
    static func nudge(_ union: CGRect, into box: CGRect) -> CGPoint {
        func along(_ low: CGFloat, _ high: CGFloat, within min: CGFloat, _ max: CGFloat) -> CGFloat {
            guard low < min || high > max else { return 0 }
            let gap = Style.containerGap
            guard high - low <= max - min - 2 * gap else { return (min + max) / 2 - (low + high) / 2 }
            return low < min ? min + gap - low : max - gap - high
        }
        return CGPoint(x: along(union.minX, union.maxX, within: box.minX, box.maxX), y: along(union.minY, union.maxY, within: box.minY, box.maxY))
    }

    /// The four ways to move `union` clear of `box`, to `Style.containerGap` outside it: left, right,
    /// up and down.
    static func out(_ union: CGRect, of box: CGRect) -> [CGPoint] {
        let gap = Style.containerGap
        return [CGPoint(x: box.minX - gap - union.maxX, y: 0), CGPoint(x: box.maxX + gap - union.minX, y: 0),
                CGPoint(x: 0, y: box.minY - gap - union.maxY), CGPoint(x: 0, y: box.maxY + gap - union.minY)]
    }

    /// Whether a box reaches into a container's: they overlap, and it doesn't cover the container
    /// whole (a shape over all of a small container is over it, not across its edge).
    static func reaches(_ box: CGRect, into container: CGRect) -> Bool { overlap(box, container) > 0 && !box.contains(container) }

    /// The area two rects share: none for rects that only touch.
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let width = min(a.maxX, b.maxX) - max(a.minX, b.minX), height = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return width > 0 && height > 0 ? width * height : 0
    }

    static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
