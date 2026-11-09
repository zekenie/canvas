import Adornments
import Canvas
import Connections
import CoreGraphics
import Geometry
import Mentions

// A row's connections to different places (one endpoint's writes to orders and reads from payments: Connections'
// `ConnectionBundle.parting`, LineRows' answer) keep their pills with their row (UX walk 4 evolve-1, walk 3 evolve-5). A pill
// slid to the row by a fan at its far end is stacked out from the row in the row's own band, past the pills before it in the
// stack (`parted`'s order), on a straight stub of its line that turns after it, its end moved along the row's side so each
// line leaves on its own; a pill laid along its line (halfway) moves out along it until clear of the others' lines (walk 3
// connect-4). Both read only the other connections' records and answers (their pills' faces, their ends), never their
// geometry, so no arrow's layout waits on another's label: pure functions of what the index records as read.

/// Where a parted connection leaves its row and, when its pill is slid to that row, where the pill stacks: the end it is at, the
/// end's move along the row's side, and the pill's middle out from the row with the straight stub it sits on (world units; nil
/// for a pill not slid there).
struct PartingStack: Equatable {
    let end: ConnectionBundle.End
    let shift: CGFloat
    let along: CGFloat?
    let stub: CGFloat
}

extension ArrowDefinition {
    /// An arrow's geometry with its detail as its bundle answer (`bundle`), look and end line say, and its parted pill's stack:
    /// the body a frame draws, before its label is laid.
    func laidOut(_ shape: ShapeRecord<Arrow>, bundle: ConnectionBundle?, in context: ShapeContext)
        -> (geometry: ArrowGeometry, detail: ArrowDetail?, line: EndLine?, stack: PartingStack?) {
        // An end of a relationship type is half of a line through its pill, with no head at it and no words (`EndLine`).
        let line = endLine(of: shape, in: context)
        // How its connection's meaning says it looks (its ends' marks, its width), asked here, kept, never per frame.
        let look = look(of: shape, in: context)
        var spread = Self.spread(of: bundle, for: shape.props)
        let mark = look?.mark(atStart: bundle?.parting?.end == .start)
        let marked = mark != nil && mark != EndMark.none && mark != .arrowhead
        let stack = line == nil ? bundle.flatMap { Self.partingStack(of: shape, bundle: $0, marked: marked, in: context) } : nil
        if let stack {
            var parted = spread ?? ArrowSpread()
            if stack.end == .start { (parted.startShift, parted.startStub) = (stack.shift, stack.stub) } else { (parted.endShift, parted.endStub) = (stack.shift, stack.stub) }
            spread = parted
        }
        let detail: ArrowDetail? = line == nil && look == nil && bundle == nil ? nil
            : ArrowDetail(line: line, look: look, width: look?.lineWidth ?? ArrowStyle.strokeWidth, spread: spread, bundle: bundle)
        return (arrowGeometry(shape.props, detail: detail, in: context), detail, line, stack)
    }

    /// How wide an arrow's label is at most, world units: its pill's widest face and the padding either side, and its words; 0 for
    /// one with neither. Read from its record and Adornments' answer, as `ArrowLabels.laid` sizes it unsqueezed.
    static func labelWidth(of arrow: ShapeRecord<Arrow>, in context: ShapeContext) -> CGFloat {
        let face = context.layoutInput(AdornmentLead.faces, of: arrow)?.sizes.first
        let words = arrow.props.hasText ? ArrowLabels.size(of: arrow.props.text, bodyBounds: .null, names: context.mentionNames(of: arrow.id)).width : nil
        guard face != nil || words != nil else { return 0 }
        let padding = ArrowStyle.labelPadding
        return face.map { padding + $0.width + (words.map { $0 - padding } ?? padding) } ?? words ?? 0
    }

    /// Where a connection parting from a row with others (`ConnectionBundle.parting`) leaves it: moved along the row's side by
    /// where its far end is among theirs, top to bottom, `partingLineSpacing` apart (a marked end `fanMarkSpacing`, a bar's height
    /// and a gap, so two keys' bars at one row never merge), so each line leaves on its own. Its pill, slid to the row, stacks
    /// past the pills of those before it in the stack whose pills are slid there too, on a straight stub of its line that turns
    /// after it, so it stays level with its row (alone, at the row, as any slid pill is, on its stub). Nil for one alone there.
    static func partingStack(of shape: ShapeRecord<Arrow>, bundle: ConnectionBundle, marked: Bool, in context: ShapeContext) -> PartingStack? {
        guard let parting = bundle.parting, parting.count > 1 else { return nil }
        let spacing = marked ? ArrowStyle.fanMarkSpacing : ArrowStyle.partingLineSpacing
        let shift = (CGFloat(parting.index) - CGFloat(parting.count - 1) / 2) * spacing
        let own = labelWidth(of: shape, in: context)
        guard own > 0, slidToward(bundle, of: shape.props) == parting.end else { return PartingStack(end: parting.end, shift: shift, along: nil, stub: 0) }
        // The pills of those before it in the stack that are slid to the row too.
        var before: CGFloat = 0
        for id in bundle.parted {
            if id == shape.id { break }
            guard let record = context.shape(id), let other = record.typed(as: Arrow.self),
                  let answer = context.layoutInput(ConnectionBundle.input, of: record), answer.lead == nil,
                  answer.parting?.end == parting.end, slidToward(answer, of: other.props) == parting.end else { continue }
            let width = labelWidth(of: other, in: context)
            if width > 0 { before += width + ArrowStyle.partingLabelGap }
        }
        let along = ArrowStyle.labelClearance + before + own / 2
        return PartingStack(end: parting.end, shift: shift, along: along, stub: along + own / 2 + ArrowStyle.labelClearance)
    }

    /// A label laid along its line (`laid`, at `position`) moved out along it, away from the row it parts from with others, until no
    /// other parted line comes within `partingLineClearance` of it; nil where it needs no move, is no parted one, or the person
    /// placed it. Never past the far end's clearance (the label's range).
    func clearOfParted(_ laid: ArrowLabels.Laid, of shape: ShapeRecord<Arrow>, bundle: ConnectionBundle, on geometry: ArrowGeometry,
                       from position: CGFloat?, in context: ShapeContext) -> (position: CGFloat, laid: ArrowLabels.Laid)? {
        guard let parting = bundle.parting, bundle.parted.count > 1, position != nil || shape.props.labelPosition == ArrowLabelLayout.defaultPosition else { return nil }
        let length = geometry.bodyLength
        guard length > 0 else { return nil }
        var others: [ArrowGeometry] = []
        for id in bundle.parted where id != shape.id {
            guard let record = context.shape(id), let other = record.typed(as: Arrow.self) else { continue }
            let answer = context.layoutInput(ConnectionBundle.input, of: record)
            if answer?.lead != nil { continue }
            others.append(laidOut(other, bundle: answer, in: context).geometry)
        }
        func clear(_ frame: CGRect) -> Bool {
            let grown = frame.insetBy(dx: -ArrowStyle.partingLineClearance, dy: -ArrowStyle.partingLineClearance)
            return !others.contains { $0.bodyPath.boundingBoxOfPath.intersects(grown) && $0.crosses(grown.polygon) }
        }
        let shown = laid.lead ?? laid.frame
        guard !clear(shown) else { return nil }
        let step = ArrowStyle.partingLabelNudge / length * (parting.end == .start ? 1 : -1)
        // From where it is laid (a position its range held in, near an end, is where the range put it).
        var at = geometry.body.fraction(nearest: CGPoint(x: laid.frame.midX, y: laid.frame.midY))
        while (step > 0 ? at < 1 : at > 0) {
            at += step
            guard let moved = ArrowLabels.laid(of: shape, on: geometry, in: context, position: at) else { return nil }
            // Held by its range at the far end: as far as it goes.
            if moved == laid { return nil }
            if clear(moved.lead ?? moved.frame) { return (at, moved) }
        }
        return nil
    }
}
