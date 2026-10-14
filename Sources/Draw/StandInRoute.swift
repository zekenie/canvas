import Canvas
import CoreGraphics
import DrawScript
import Geometry
import Topology

/// How a stand-in (a pill that stands for a shape) is read and made, for whatever draws or edits
/// arrows to shapes on other boards: the one answer to "what does this stand for", "which pills does
/// the board have", "which does a delete leave with no arrow", "which kind stands for this shape",
/// "is there a pill to reuse" and "where does a new one go". `canvas draw` asks it, and so can a
/// writer in another module, so the two put the same pill in the same place. Nil where no kind
/// stands in.
@MainActor
public struct StandInRoute {
    let standIns: StandIns
    private let registry: Registry

    public init?(_ registry: Registry) {
        let standIns = registry.standIns
        guard !standIns.isEmpty else { return nil }
        self.init(standIns, registry: registry)
    }

    init(_ standIns: StandIns, registry: Registry) {
        self.standIns = standIns
        self.registry = registry
    }

    /// The shape a direct pill names (a pill standing for exactly one shape: a query may stand for
    /// several, so it never matches), admitted or not, and the pill. Nil for any other shape.
    public func stoodFor(_ id: ShapeID, in document: CanvasDocument) -> (shape: ShapeID, pill: ShapeID, kind: ShapeKind)? {
        Self.read(id, in: document, standIns).map { ($0.shape, id, $0.kind) }
    }

    /// The same, for a caller that holds `StandIns` and not a route (nil where nothing stands in).
    static func read(_ id: ShapeID, in document: CanvasDocument, _ standIns: StandIns?) -> (shape: ShapeID, kind: ShapeKind)? {
        guard let standIns, let record = document[id],
              case .shapes(let named)? = standIns.forwarding(of: record), let first = named.first, first != id,
              named.allSatisfy({ $0 == first }) else { return nil }
        return (first, record.kind)
    }

    /// The board's direct pills by the shape each stands for, in document order, found in one pass.
    public func pills(in document: CanvasDocument) -> [ShapeID: [ShapeID]] {
        var found: [ShapeID: [ShapeID]] = [:]
        for record in document.shapes {
            if let stood = Self.read(record.id, in: document, standIns) { found[stood.shape, default: []].append(record.id) }
        }
        return found
    }

    /// The pills a delete of `deleting` leaves with no arrow, bound or loose: those bound by a
    /// record in `deleting` and by no record that stays. In document order. Reads only the records
    /// of kinds that bind shapes. (An arrow a step changes in place stays: it is not in `deleting`.)
    public func emptied(by deleting: Set<ShapeID>, in document: CanvasDocument) -> [ShapeID] {
        let kinds = registry.referencingKinds
        guard !kinds.isEmpty else { return [] }
        let context = ShapeContext(document: document, registry: registry)
        var touched: Set<ShapeID> = [], held: Set<ShapeID> = []
        for record in document.shapes where kinds.contains(record.kind) {
            let gone = deleting.contains(record.id)
            for end in record.boundShapes(in: context) {
                if gone { touched.insert(end) } else { held.insert(end) }
            }
        }
        return document.shapes.map(\.id).filter {
            touched.contains($0) && !held.contains($0) && !deleting.contains($0) && Self.read($0, in: document, standIns) != nil
        }
    }
}

// MARK: Making

/// Which end of an edge: the start, or the end.
public enum EdgePlace: Sendable {
    case from, to

    var other: EdgePlace { self == .from ? .to : .from }
}

/// Where a new pill goes beside a shape (`StandInRoute.spot`): the side, and the column of pills
/// already there that it joins.
public struct StandInSpot: Equatable, Sendable {
    /// The shape the pill is beside.
    public var near: ShapeID
    /// Which side of `near` it goes on: right of a start, left of an end, or the side the edge names.
    public var direction: Direction
    /// The last pill of the column already beside `near` on that side, which the new one goes past;
    /// nil for the first.
    public var after: ShapeID?
    /// How far past `after` (`LayoutProblem.impliedListStep`), else the normal gap from `near`.
    public var step: CGFloat
    /// What it lines up with in the column: the left edge of a column right of `near`, the right edge
    /// of one left of it; none above and below it, where the middles do.
    public var level: AlignSide?

    public init(near: ShapeID, direction: Direction, after: ShapeID? = nil, step: CGFloat, level: AlignSide? = nil) {
        self.near = near
        self.direction = direction
        self.after = after
        self.step = step
        self.level = level
    }

    /// The placements of a pill there, as a script would write them (so every message about it, and
    /// what it is solved against, are Draw's): beside `near` named `nearName`, or, past `after`
    /// named `afterName`, a step below it (above, in a column above `near`) and lined up with it.
    func clauses(near nearName: String, after afterName: String?) -> [Clause] {
        guard after != nil, let afterName else { return [Clause(relation: .direction(direction), targets: [Target(.title(nearName))])] }
        let way: Direction = direction == .above ? .above : .below, gap = Gap.units(step)
        var clauses = [Clause(relation: .direction(way), targets: [Target(.title(afterName))], gap: gap,
                              written: Clause.written(.direction(way), naming: [afterName], gap: gap))]
        if let level {
            clauses.append(Clause(relation: .level(level), targets: [Target(.title(afterName))], written: Clause.written(.level(level), naming: [afterName])))
        }
        return clauses
    }
}

extension StandInRoute {
    /// Which pill, if any, a new arrow reuses rather than make another for the same shape.
    public enum Sharing {
        /// None: a pill of its own.
        case never
        /// Any pill of the kind for the shape in the same container as the shape it is beside.
        case any
        /// The pill an arrow of this shape already runs into (or out of).
        case host(ShapeID)
    }

    /// What a board holds that routing reads, found in one pass: its direct pills by what they stand
    /// for, and the shapes its arrows join to each shape. Made once (`index(of:)`) by a caller that
    /// asks many times of one document.
    public struct Index {
        let pills: [ShapeID: [ShapeID]]
        let tied: [ShapeID: [(arrow: ShapeID, other: ShapeID)]]
    }

    public func index(of document: CanvasDocument) -> Index {
        var tied: [ShapeID: [(arrow: ShapeID, other: ShapeID)]] = [:]
        if let edging = registry.drawEdging, let kind = edging.kind(registry) {
            for connection in Drawing.connections(in: document, kind: kind, edging: edging, registry: registry) where connection.from != connection.to {
                tied[connection.from, default: []].append((connection.record.id, connection.to))
                tied[connection.to, default: []].append((connection.record.id, connection.from))
            }
        }
        return Index(pills: pills(in: document), tied: tied)
    }

    /// The first kind, in plugin order, that can be made to stand for `far` and admits it, or, with
    /// `fulfilling`, can be made to admit it (`StandIns.fulfil`: a private shape made public); `fulfils`
    /// says it takes that. Without `fulfilling` it is Draw's rule: a script never changes the shape.
    public func kind(for far: AnyShapeRecord, fulfilling: Bool) -> (kind: ShapeKind, fulfils: Bool)? {
        kind(for: far, fulfilling: fulfilling, among: standIns.makers)
    }

    /// The same, for a caller that asks of many shapes and has the makers (`StandIns.makers`, which looks them up) once.
    public func kind(for far: AnyShapeRecord, fulfilling: Bool, among makers: [ShapeKind]) -> (kind: ShapeKind, fulfils: Bool)? {
        for kind in makers {
            if standIns.admits(kind, far) { return (kind, false) }
            guard fulfilling else { continue }
            var made = far
            if standIns.fulfil(kind, &made) { return (kind, true) }
        }
        return nil
    }

    /// A pill of `kind` for `far` to reuse, or nil to make one. `.any`: the board's first in the
    /// container `near` is in; `.host(h)`: the one an arrow of `h` already runs into, in any
    /// container; `.never`: none. `excluding` are shapes the caller is deleting.
    public func existing(for far: ShapeID, kind: ShapeKind, sharing: Sharing, near: ShapeID, in document: CanvasDocument,
                         excluding: Set<ShapeID> = [], index: Index? = nil) -> ShapeID? {
        let kinds = registry.containingKinds
        return existing(for: far, kind: kind, sharing: sharing, container: kinds.isEmpty ? nil : document.container(of: near, containingKinds: kinds),
                        in: document, excluding: excluding, index: index)
    }

    /// The same where the container is known (of a shape the caller has yet to put down).
    func existing(for far: ShapeID, kind: ShapeKind, sharing: Sharing, container: ShapeID?, in document: CanvasDocument,
                  excluding: Set<ShapeID> = [], index: Index? = nil) -> ShapeID? {
        switch sharing {
        case .never:
            return nil
        case .any:
            let kinds = registry.containingKinds
            for pill in (index ?? self.index(of: document)).pills[far] ?? [] where !excluding.contains(pill) {
                guard document[pill]?.kind == kind,
                      (kinds.isEmpty ? nil : document.container(of: pill, containingKinds: kinds)) == container else { continue }
                return pill
            }
            return nil
        case .host(let host):
            for tie in (index ?? self.index(of: document)).tied[host] ?? [] where !excluding.contains(tie.arrow) && !excluding.contains(tie.other) {
                guard let stood = Self.read(tie.other, in: document, standIns), stood.shape == far, stood.kind == kind else { continue }
                return tie.other
            }
            return nil
        }
    }

    /// Where a new pill goes beside `near` (a shape of `reading`'s board): right of it where it is
    /// the start of the edge, left of it where it is the end, or on `side`, the side the edge names;
    /// at the end of the column of pills already there (`after`). Those are the pills an arrow joins to
    /// `near`, wholly on that side of it and lined up as a list beside it lines its members up, on the
    /// line nearest it whose pills reach across from its middle; the lowest of them (the topmost,
    /// above it). None where `staying` says `near` or that pill is moved by the caller, which would
    /// no longer be beside it. `excluding` are shapes the caller is deleting.
    public func spot(beside near: ShapeID, edgeIs place: EdgePlace, side: EdgeSide?, in reading: BoardReading,
                     excluding: Set<ShapeID> = [], staying: (ShapeID) -> Bool = { _ in true }, index: Index? = nil) -> StandInSpot {
        let direction: Direction = switch side {
        case .left?: .left
        case .right?: .right
        case .top?: .above
        case .bottom?: .below
        case nil: place == .from ? .right : .left
        }
        let end = columnEnd(beside: near, direction, in: reading, excluding: excluding, staying: staying, index: index ?? self.index(of: reading.document))
        let level: AlignSide? = switch direction {
        case .right where end != nil: .left
        case .left where end != nil: .right
        default: nil
        }
        return StandInSpot(near: near, direction: direction, after: end,
                           step: end == nil ? GapName.normal.value : LayoutProblem.impliedListStep, level: level)
    }

    /// Where a pill of `size` lands at `spot`, as `canvas draw` lands a pill: placed against `near`, or
    /// the column's end, and pushed clear of what is on the board and of `avoiding` (boxes a caller
    /// has planned and not yet put down). Nil for a spot that is not on the board.
    public func landing(of size: CGSize, at spot: StandInSpot, in surroundings: Surroundings, avoiding: [CGRect] = []) -> Landing? {
        surroundings.landing(of: size, at: spot, avoiding: avoiding)
    }

    private func columnEnd(beside near: ShapeID, _ direction: Direction, in reading: BoardReading, excluding: Set<ShapeID>,
                           staying: (ShapeID) -> Bool, index: Index) -> ShapeID? {
        guard staying(near), let nearBox = reading.shapes.geometry(of: near)?.bounds, nearBox.isFinite else { return nil }
        let document = reading.document
        let slack: CGFloat = 0.5
        var beside: [(id: ShapeID, box: CGRect)] = []
        for tie in index.tied[near] ?? [] {
            let other = tie.other
            guard !excluding.contains(tie.arrow), !excluding.contains(other), Self.read(other, in: document, standIns) != nil,
                  !beside.contains(where: { $0.id == other }),
                  let box = reading.shapes.geometry(of: other)?.bounds, box.isFinite else { continue }
            let wholly = switch direction {
            case .right: box.minX >= nearBox.maxX - slack
            case .left: box.maxX <= nearBox.minX + slack
            case .below: box.minY >= nearBox.maxY - slack
            default: box.maxY <= nearBox.minY + slack
            }
            if wholly { beside.append((other, box)) }
        }
        /// Where a pill's box is across the column, and how far from `near` it is.
        func line(_ box: CGRect) -> (across: CGFloat, distance: CGFloat) {
            switch direction {
            case .right: (box.minX, box.minX - nearBox.maxX)
            case .left: (box.maxX, nearBox.minX - box.maxX)
            case .below: (box.midX, box.minY - nearBox.maxY)
            default: (box.midX, nearBox.minY - box.maxY)
            }
        }
        for nearest in beside.sorted(by: { line($0.box).distance < line($1.box).distance }) {
            let column = beside.filter { abs(line($0.box).across - line(nearest.box).across) <= slack }
            let span = column.reduce(CGRect.null) { $0.union($1.box) }
            let across = direction == .right || direction == .left ? span.minY <= nearBox.midY && nearBox.midY <= span.maxY
                : span.minX <= nearBox.midX && nearBox.midX <= span.maxX
            guard across else { continue }
            let end = direction == .above ? column.min { $0.box.minY < $1.box.minY } : column.max { $0.box.maxY < $1.box.maxY }
            guard let end, staying(end.id) else { return nil }
            return end.id
        }
        return nil
    }
}
