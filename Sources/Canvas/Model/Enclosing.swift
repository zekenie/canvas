import CoreGraphics
import Geometry

// Putting a container down around shapes (`CanvasEditor.place(_:around:padding:minimumSize:)`: Frames'
// Create Frame): a new container sized to them, in the container they're all in, holding them where they
// are.

extension Transaction {
    /// Puts `container`, a new shape of a `ShapeContaining` kind, down around shapes on this board,
    /// holding them: those of `ids` with a box, but what's in another of them (it goes with that one).
    /// A shape without a box (an arrow) is in no container: it follows what it's bound to. The frame is
    /// around them and, among `ids`, what's bound to some of them and to nothing else (an arrow between
    /// two of them), grown by `padding`, kept `Style.containerGap` inside the innermost container
    /// they're all in, which it goes in, unless what it holds reaches nearer that one's edge, then
    /// grown to `minimumSize` about its middle, as far as that room allows; it holds each of them whole
    /// as `CGRect.contains` reads it, though a side be flush with one. In the stack it goes just below
    /// the lowest of them, so they keep their places, and what was under them all is under it. What
    /// it lands on there is settled as what a container's drawn over is (`settle(container:)`): what's
    /// mostly inside it comes in, nudged fully in, rising above what it holds; what's mostly outside is
    /// nudged out; read-only shapes stay. Those it took out of a container that it then took in are put
    /// down again (`settle(_:)`, with the others from that container), so they go back into it rather
    /// than lying under it; those from a container it didn't take in stay in it.
    ///
    /// Returns what settling nudged, by how far; nil, changing nothing, when none of them can be held,
    /// or when one that would be is read-only (all or nothing: noted in `refusedShapes`, for
    /// `editor.transactWhole` to give it all up, as a refusal settling meets on the way is).
    mutating func enclose(_ ids: [ShapeID], in container: AnyShapeRecord, padding: CGFloat, minimumSize: CGSize) -> [ShapeID: CGPoint]? {
        let kinds = registry.containingKinds
        guard registry.isContainer(container) else { return nil }
        let asked = ids.compactMap { document[$0] }
        let boxed = Set(asked.lazy.filter { $0.box != nil }.map(\.id))
        let held = boxed.compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }.filter { record in
            !(record.namesContainer && document.containers(of: record.id, containingKinds: kinds).contains(where: boxed.contains))
        }
        guard let lowest = held.first else { return nil }
        let stuck = held.filter { holds($0) }
        guard stuck.isEmpty else {
            refused.formUnion(stuck.map(\.id))
            return nil
        }
        var shared = document.containers(of: lowest.id, containingKinds: kinds)
        for record in held.dropFirst() where !shared.isEmpty {
            let chain = Set(document.containers(of: record.id, containingKinds: kinds))
            shared.removeAll { !chain.contains($0) }
        }
        let parent = shared.first
        var record = container
        record.box = frame(around: held, with: asked, padding: padding, minimumSize: minimumSize, in: parent)
        record.container = parent
        insert(record)
        guard document[record.id] != nil else { return nil }
        move(record.id, below: lowest.id)
        // Those it takes out of a container inside the one it goes in, with the container each leaves.
        let leaving = held.compactMap { member -> (id: ShapeID, from: ShapeID)? in
            guard let from = document.container(of: member, containingKinds: kinds), from != parent else { return nil }
            return (member.id, from)
        }
        setContainer(held.map(\.id), to: record.id)
        var nudges = settle(container: record.id)
        var froms: [ShapeID] = [], back: [ShapeID: [ShapeID]] = [:]
        for member in leaving where document.containers(of: member.from, containingKinds: kinds).contains(record.id) {
            if back[member.from] == nil { froms.append(member.from) }
            back[member.from, default: []].append(member.id)
        }
        for from in froms {
            nudges.merge(settle(back[from] ?? []).nudges) { $0 + $1 }
        }
        return nudges
    }

    /// The frame a container put down around `held` gets (`enclose`): around them and what's bound to
    /// them alone among `asked`, grown by `padding`, kept the gap inside `parent`, grown to `minimumSize`
    /// within that, and never a far edge short of one of them (its origin plus its size can round an ulp
    /// under it).
    private func frame(around held: [AnyShapeRecord], with asked: [AnyShapeRecord], padding: CGFloat, minimumSize: CGSize,
                       in parent: ShapeID?) -> CGRect {
        let context = shapes
        let boxes = held.compactMap { context.frame(of: $0) }
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        var around = union
        if asked.contains(where: { $0.box == nil && registry.referencingKinds.contains($0.kind) }) {
            let inside = Set(held.flatMap { [$0.id] + document.descendants(of: $0.id, containingKinds: registry.containingKinds) })
            for record in asked where record.box == nil && record.isBound(onlyTo: inside, in: context) {
                if let bounds = context.bounds(of: [record.id]) { around = around.union(bounds) }
            }
        }
        let padding = max(0, padding), edge = parent.flatMap { document[$0]?.box }
        let x = Self.span(around.minX - padding, around.maxX + padding, holding: union.minX, union.maxX,
                          within: edge.map { ($0.minX, $0.maxX) }, minimum: minimumSize.width)
        let y = Self.span(around.minY - padding, around.maxY + padding, holding: union.minY, union.maxY,
                          within: edge.map { ($0.minY, $0.maxY) }, minimum: minimumSize.height)
        var frame = CGRect(x: x.low, y: y.low, width: x.high - x.low, height: y.high - y.low)
        for box in boxes {
            while frame.maxX < box.maxX { frame.size.width = frame.size.width.nextUp }
            while frame.maxY < box.maxY { frame.size.height = frame.size.height.nextUp }
        }
        return frame
    }

    /// One axis of that frame: `low`…`high`, kept the gap inside the container's `edge` unless what it
    /// holds (`first`…`last`) reaches nearer, then, if it's shorter than `minimum`, grown about its middle
    /// as far as that room allows, shifted into it. Its low end is never past `first`.
    private static func span(_ low: CGFloat, _ high: CGFloat, holding first: CGFloat, _ last: CGFloat,
                             within edge: (low: CGFloat, high: CGFloat)?, minimum: CGFloat) -> (low: CGFloat, high: CGFloat) {
        let gap = Style.containerGap
        let room = edge.map { (low: min($0.low + gap, first), high: max($0.high - gap, last)) } ?? (low: -.infinity, high: .infinity)
        let low = max(low, room.low), high = min(high, room.high)
        let length = min(max(high - low, minimum), room.high - room.low)
        guard length > high - low else { return (low, high) }
        let start = min(max((low + high - length) / 2, room.low), room.high - length, low)
        return (start, start + length)
    }
}
