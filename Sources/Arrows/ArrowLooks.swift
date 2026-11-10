import Canvas
import Connections
import CoreGraphics
import Geometry

// How an arrow looks beyond tldraw's: the marks at its ends and its width, which the plugin that owns what the arrow means
// answers through Connections' `ConnectionLooks` (a key: a crow's foot at its column, two bars or a bar and a circle at the row
// it references, 2.5 wide), and the level curve an arrow with an end at a row is drawn as. Worked out with the arrow's geometry
// and kept in it (`ShapeGeometry.detail`), so a frame draws what is kept and asks nothing; the look's reads (a column made
// nullable) are the geometry's, so they work it out again. An arrow with none of it (no end at a row, no look, not a
// relationship's end) keeps no detail and is drawn exactly as before: the parity goldens and transcript never see one.
//
// Departures from tldraw (checked at v5.0.1: its heads are one of nine stored per end, `TLArrowShape.ts`, drawn in
// `arrowheads.ts`, and it has no crow's foot, double bar or set-back bar and circle): the marks are worked out from the
// relation, never stored; a marked end has no gap and ignores the stored head, which is kept; and the line is as wide as the
// look says (a key 2.5, where tldraw's sizes are 2, 3.5, 5 and 10).

/// The marks an end is drawn with, in world units along the line from the end and across it, measured from the frames
/// (arrow-look §0). Pure: a mark is strokes at the line's width, set along the way into the arrow from its end.
enum ArrowMarks {
    /// A crow's foot: toes this far either side of the line at the end, meeting on it `toeReach` out; the middle toe on the line.
    static let toeSpread: CGFloat = 8.5
    static let toeReach: CGFloat = 13
    /// A bar is this far either side of the line.
    static let barHalf: CGFloat = 9
    /// The bars of "one", out from the end; the bar of "zero or one" is the nearer.
    static let barNear: CGFloat = 12
    static let barFar: CGFloat = 17.5
    /// The hollow circle of "zero or one": its radius, and how far out its centre is. The line is cut inside it.
    static let circleRadius: CGFloat = 5
    static let circleCentre: CGFloat = 25

    /// How far out along the line a mark reaches from its end: what is long enough to show zoomed out.
    static func reach(of mark: EndMark) -> CGFloat {
        switch mark {
        case .none, .arrowhead: 0
        case .many: toeReach
        case .one: barFar
        case .zeroOrOne: circleCentre + circleRadius
        }
    }

    /// Adds the strokes of `mark` at an end to `path`, each set on the line where it is: `along(d)` is the point `d` along
    /// the line from the end and the way on into the arrow there (`ArrowGeometry.point(_:along:)`), so a curved line's bars
    /// stand square to it and its circle is on it. Returns the circle the line is cut inside, for "zero or one".
    @discardableResult
    static func add(_ mark: EndMark, along: (CGFloat) -> (point: CGPoint, inward: CGPoint), to path: CGMutablePath) -> CGRect? {
        func bar(at distance: CGFloat) {
            let (point, inward) = along(distance)
            path.move(to: point + inward.perpendicular * barHalf)
            path.addLine(to: point - inward.perpendicular * barHalf)
        }
        switch mark {
        case .none, .arrowhead:
            return nil
        case .many:
            let (tip, inward) = along(0), meet = along(toeReach).point
            for toe in [tip + inward.perpendicular * toeSpread, tip, tip - inward.perpendicular * toeSpread] {
                path.move(to: toe)
                path.addLine(to: meet)
            }
            return nil
        case .one:
            bar(at: barNear)
            bar(at: barFar)
            return nil
        case .zeroOrOne:
            bar(at: barNear)
            let circle = CGRect(center: along(circleCentre).point, size: CGSize(width: circleRadius * 2, height: circleRadius * 2))
            path.addEllipse(in: circle)
            return circle
        }
    }
}

/// What an arrow's geometry keeps besides its outline (`ShapeGeometry.detail`): the end line through a relationship type's pill
/// (`EndLine`, Types'), the look its connection's meaning gives (`ConnectionLook`), the width it is drawn at, and, for an
/// arrow drawn level or with a look, what is drawn, worked out once. `CGPath` is immutable once made, so sharing it is safe.
struct ArrowDetail: @unchecked Sendable {
    let line: EndLine?
    let look: ConnectionLook?
    /// Its line's width, world units: the look's, else `ArrowStyle.strokeWidth`.
    let width: CGFloat
    /// How it is drawn among the connections sharing its path (a slot's bow, a fan, a row it comes in at), and that answer: nil
    /// for one drawn as ever.
    var spread: ArrowSpread? = nil
    var bundle: ConnectionBundle? = nil
    /// Where its label is laid instead of where it is stored (a fanned arrow's, slid toward its other end): kept, so the label
    /// is edited where it is drawn.
    var labelPosition: CGFloat? = nil
    /// What a frame draws: nil for an arrow that is only a relationship's end, drawn as it always was.
    var drawing: ArrowDrawing?

    /// The arrow as it is drawn: a relationship's end's (no head at the pill, its bend), and a marked end's head as the look
    /// says (none but for `.arrowhead`), the stored flags kept.
    func drawn(_ stored: Arrow) -> Arrow {
        var arrow = line?.drawn(stored) ?? stored
        if let mark = look?.start { arrow.startArrowhead = mark == .arrowhead }
        if let mark = look?.end { arrow.endArrowhead = mark == .arrowhead }
        return arrow
    }

    /// Bends under `ArrowGeometry.minBend` draw straight, but a line through a pill's, worked out from where the pill is.
    var minBend: CGFloat { line?.bend == nil ? ArrowGeometry.minBend : 0 }

    /// Whether the look says what `end` is drawn with, so its stored head isn't used (nor toggled).
    func isMarked(_ end: ArrowEnd) -> Bool { look?.mark(atStart: end == .start) != nil }

    /// How far out along the line each end's mark reaches (0 for an end with none).
    var markReach: (start: CGFloat, end: CGFloat) {
        (mark(at: .start).map(ArrowMarks.reach(of:)) ?? 0, mark(at: .end).map(ArrowMarks.reach(of:)) ?? 0)
    }

    /// The mark at `end`, if the look gives one that is drawn as a mark (not a head, not nothing).
    func mark(at end: ArrowEnd) -> EndMark? {
        guard let mark = look?.mark(atStart: end == .start), mark != .none, mark != .arrowhead else { return nil }
        return mark
    }
}

/// What a frame draws of an arrow drawn level or with a look, worked out with its geometry.
struct ArrowDrawing: @unchecked Sendable {
    /// One end's mark: its strokes, how far out along the line it reaches (world units), and whether the line is cut in it.
    struct Mark: @unchecked Sendable {
        let path: CGPath
        let reach: CGFloat
        let isCut: Bool
    }

    /// The visible body, less where a mark's circle cuts it.
    let body: CGPath
    /// The visible body whole: zoomed out where no mark that cuts it is drawn.
    let whole: CGPath
    /// Its heads' chevrons, at the ends drawn with one.
    let heads: CGPath
    /// The same heads closed, as a skeleton fills them.
    let triangles: CGPath
    /// Each marked end's mark.
    let ends: [Mark]
    /// Every mark's strokes together; empty with none.
    let marks: CGPath
    /// Its visible ends, and whether far out its skeleton is the straight line between them: a level curve (an end at a row) whose
    /// ends face each other. One that leaves and comes back by one side (a C between stacked tables) stays the curve, which a
    /// straight line would lay along the tables' shared edge (review U9-E2).
    let start: CGPoint
    let end: CGPoint
    let straightensFarOut: Bool
    /// Its heads closed, as that straight line takes them: along the line, not along the curve it no longer draws.
    let straightTriangles: CGPath

    init(_ geometry: ArrowGeometry, detail: ArrowDetail) {
        whole = geometry.bodyPath
        (start, end) = (geometry.start, geometry.end)
        let faces = geometry.levelBody.map { $0.tangent(at: 0).dot($0.tangent(at: 1)) > 0 } ?? false
        straightensFarOut = geometry.isLevel && faces
        let heads = CGMutablePath(), triangles = CGMutablePath()
        for head in geometry.arrowheads(strokeWidth: detail.width) {
            for path in [heads, triangles] {
                path.move(to: head.wing)
                path.addLine(to: head.tip)
                path.addLine(to: head.otherWing)
            }
            triangles.closeSubpath()
        }
        self.heads = heads
        self.triangles = triangles
        let straight = CGMutablePath()
        if straightensFarOut {
            let length = min(max(geometry.start.distance(to: geometry.end) / 5, detail.width), detail.width * 3)
            for end in [ArrowEnd.start, .end] where end == .start ? geometry.startArrowhead : geometry.endArrowhead {
                let tip = geometry.visiblePoint(at: end), base = tip.moved(toward: geometry.visiblePoint(at: end.opposite), by: length)
                straight.move(to: base.rotated(around: tip, by: .pi / 6))
                straight.addLine(to: tip)
                straight.addLine(to: base.rotated(around: tip, by: -.pi / 6))
                straight.closeSubpath()
            }
        }
        straightTriangles = straight
        let marks = CGMutablePath()
        var ends: [Mark] = []
        // The stretches of the line a circle sits on, as distances from its start: the line is not drawn inside it.
        var cuts: [ClosedRange<CGFloat>] = []
        let length = geometry.bodyLength, place = geometry.placing()
        for end in [ArrowEnd.start, .end] {
            guard let mark = detail.mark(at: end) else { continue }
            let path = CGMutablePath()
            // Out by the end's offset, where a fan staggers its marks past its neighbors'.
            let offset = end == .start ? geometry.markOffset.start : geometry.markOffset.end
            let circle = ArrowMarks.add(mark, along: { place($0 + offset, end) }, to: path)
            if circle != nil {
                let centre = min(ArrowMarks.circleCentre + offset, length), from = end == .start ? centre : length - centre
                cuts.append((from - ArrowMarks.circleRadius)...(from + ArrowMarks.circleRadius))
            }
            ends.append(Mark(path: path, reach: ArrowMarks.reach(of: mark), isCut: circle != nil))
            marks.addPath(path)
        }
        self.ends = ends
        self.marks = marks
        body = cuts.isEmpty ? whole : geometry.bodyPath(cuttingOut: cuts)
    }

    /// The marks drawn zoomed out at `zoom`, each once it reaches `ArrowStyle.skeletonMarkLength` view points along the line,
    /// and the body they're drawn on: cut where a circle drawn is, else whole.
    /// Below `ArrowStyle.straightSkeletonZoom` a level curve whose ends face each other is one straight line from its end to its end, with no marks or
    /// level reaches (UX walk 3 tables-4: three keys between two tables 75 apart knotted into a scribble at 10%), as other kinds'
    /// skeletons simplify further farther out.
    @MainActor
    func skeleton(atZoom zoom: CGFloat) -> (body: CGPath, marks: [CGPath], triangles: CGPath) {
        if straightensFarOut, zoom < ArrowStyle.straightSkeletonZoom {
            let line = CGMutablePath()
            line.move(to: start)
            line.addLine(to: end)
            return (line, [], straightTriangles)
        }
        let shown = ends.filter { $0.reach * zoom >= ArrowStyle.skeletonMarkLength }
        return (shown.contains(where: \.isCut) ? body : whole, shown.map(\.path), triangles)
    }
}

extension ShapeGeometry {
    /// An arrow's kept detail (`ArrowDetail`); nil for a plain arrow, which keeps none.
    var arrowDetail: ArrowDetail? { detail as? ArrowDetail }
}

extension ArrowDefinition {
    /// How the arrow's connection looks, from the plugins that own its meaning (`ConnectionLooks`), asked with its ends' shapes
    /// and parts; nil when none answers.
    func look(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> ConnectionLook? {
        let registry = context.registry
        guard !registry.contributions(to: ConnectionLooks.self).isEmpty else { return nil }
        // A connection being drawn has no channel yet: the one it will be released on, which its drag says (`ArrowTargeting`).
        let drawn = shape[ChannelProperty.self] == nil ? context.service(ArrowTargeting.self)?.provisionalChannels[shape.id] : nil
        return registry.connectionLook(of: AnyShapeRecord(shape), channel: drawn, from: shape.props.start.binding?.address, to: shape.props.end.binding?.address, in: context)
    }

    /// An arrow's geometry as its detail draws it: a relationship's end's line, a look's heads and width.
    func arrowGeometry(_ arrow: Arrow, detail: ArrowDetail?, in context: ShapeContext) -> ArrowGeometry {
        guard let detail else { return arrowGeometry(arrow, in: context) }
        let connectables = Connectables(shapes: context)
        return ArrowGeometry(arrow: detail.drawn(arrow), strokeWidth: detail.width, minBend: detail.minBend, markReach: detail.markReach,
                             spread: detail.spread ?? ArrowSpread()) { connectables[$0] }
    }

    /// How an arrow's bundle answer draws it (`ConnectionBundle`): its slot's bow, its fans, the rows it comes in at; nil for none.
    /// An arrow bound at both ends to shapes as wholes is one of a pair that `ArrowConnections.pairBend` bowed apart when it was
    /// made (the later one holds a bend of its own, whose sign a slot's bow could cancel), so it takes no slot's bow: its own bend
    /// is its slot.
    static func spread(of bundle: ConnectionBundle?, for arrow: Arrow) -> ArrowSpread? {
        guard let bundle, !bundle.isPlain else { return nil }
        var spread = ArrowSpread()
        // Decided by what the arrow holds, never by a nudge's or a move's precision (review R39: made precise by a move, it took a
        // slot's bow and jumped): bound at both ends to shapes as wholes, and either bowed a pair's step already (a later one of its
        // pair) or imprecise at both ends (the first, which `pairBend` left straight). One made at its ends' sides (a port's, precise
        // and straight) is no pair's: it takes its slot's bow, or two of them would be drawn on one line (review U9-C3).
        let whole = [arrow.start, arrow.end].allSatisfy { $0.binding.map { $0.part == nil } ?? false }
        let ratio = arrow.bend / ArrowStyle.pairBend
        let bowed = ratio != 0 && ratio == ratio.rounded() && abs(ratio) < 1_000
        let paired = whole && (bowed || [arrow.start, arrow.end].allSatisfy { $0.binding.map { !$0.isPrecise } ?? false })
        if !paired {
            spread.bend = CGFloat(bundle.slotOffset) * ArrowStyle.slotSpacing
            spread.slotShift = CGFloat(bundle.slotOffset) * ArrowStyle.slotEndShift
        }
        if let fan = bundle.fan(at: .start) { (spread.startFan, spread.startFanCount) = (CGFloat(fan.spread), fan.count) }
        if let fan = bundle.fan(at: .end) { (spread.endFan, spread.endFanCount) = (CGFloat(fan.spread), fan.count) }
        spread.startEntry = bundle.entries[.start]
        spread.endEntry = bundle.entries[.end]
        spread.run = bundle.run
        // How far out the farthest of its run's marks reach at each of its shapes, a nudge more where a fan may stand one out: what a
        // narrow gap's turns keep clear of.
        func reach(_ end: ConnectionBundle.End) -> CGFloat {
            guard let run = bundle.runMarks[end] else { return 0 }
            let farthest = run.marks.map(ArrowMarks.reach(of:)).max() ?? 0
            return farthest > 0 && run.nudged ? farthest + ArrowStyle.fanMarkNudge : farthest
        }
        (spread.startRunReach, spread.endRunReach) = (reach(.start), reach(.end))
        return spread == ArrowSpread() ? nil : spread
    }
}

extension ArrowStyle {
    /// Zoomed out, an end's marks are drawn once the longest reaches this many view points along the line; shorter, the line
    /// runs whole to the end.
    static let skeletonMarkLength: CGFloat = 3
    /// Below this zoom a level curve's skeleton is a straight line between its ends: where a key's bars (17.5 out) are under
    /// `skeletonMarkLength` view points and drawn no more, and a row is too thin to have bars of its own (the kit's 12% floor).
    static let straightSkeletonZoom: CGFloat = 0.15
}
