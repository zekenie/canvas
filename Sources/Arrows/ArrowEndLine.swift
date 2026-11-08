import Canvas
import CoreGraphics
import Geometry
import Types

// An arrow that is an end of a relationship type is half of a line through the type's pill: car ——[owner]——> person. Types says
// which arrows these are (`EndArrow.input`); this is how they are drawn, in both halves alike. A deviation from tldraw, only for
// such an arrow (plain arrows, and so every parity golden, are as they were):
//
// - no head at the pill (the stored head flags are left as they are);
// - no words: its label, its cut and its editing are left off, since its words name a row of the types it joins and the type's
//   card says them (they are kept, and `canvas draw` and `canvas query` read and write them as ever);
// - when the type has the one end on each side and their far ends are bound to two different shapes, each half is its part of the
//   circle through the far end of one, the pill's centre and the far end of the other (`ArrowThrough`), clipped at both shapes as
//   any arrow is, so a far type moved bends the line through the pill, which stays where it is, and a pill dragged off the line
//   bends it. Straight where the three are on a line. Otherwise (a side with several ends, a type related to itself, an end free
//   at its far end) each half keeps the bend it stores.
//
// Worked out when the arrow's geometry is, from the shapes it looks up (so a move of any of them works it out again), and kept in
// the geometry (`ShapeGeometry.detail`) for what draws, hit-tests and outlines.

/// How an end arrow is drawn: where its head is left off, and the bend it takes from the circle through the pill.
struct EndLine: Sendable, Equatable {
    /// The terminal at the relationship type's pill.
    let hubEnd: ArrowEnd
    /// The bend it is drawn with, when it is part of an arc through the pill; nil: the bend it stores.
    let bend: CGFloat?

    /// The arrow as it is drawn: no head at the pill and, in an arc, the bend, aimed at the pill's middle.
    func drawn(_ stored: Arrow) -> Arrow {
        var arrow = stored
        if hubEnd == .start { arrow.startArrowhead = false } else { arrow.endArrowhead = false }
        if let bend {
            arrow.bend = bend
            if var binding = arrow[hubEnd].binding {
                binding.isPrecise = false
                binding.isExact = false
                arrow[hubEnd] = .bound(binding)
            }
        }
        return arrow
    }

    /// Whether the arrow is drawn with a head at `end`.
    func hasHead(at end: ArrowEnd, of arrow: Arrow) -> Bool { end != hubEnd && arrow.hasArrowhead(at: end) }
}

extension ArrowDefinition {
    /// How an arrow that is an end of a relationship type is drawn; nil for any other.
    func endLine(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> EndLine? {
        guard let role = context.layoutInput(EndArrow.input, of: shape) else { return nil }
        let hubEnd: ArrowEnd = role.side == .from ? .end : .start
        let plain = EndLine(hubEnd: hubEnd, bend: nil)
        let arrow = shape.props
        // The partner is the other half, which runs into the same pill; each half's far end is bound to its own shape.
        guard let partnerID = role.partner, let partner = context.shape(partnerID)?.typed(as: Arrow.self)?.props,
              let hubBinding = arrow[hubEnd].binding, partner[hubEnd.opposite].binding?.shapeID == hubBinding.shapeID,
              let farBinding = arrow[hubEnd.opposite].binding, let partnerFar = partner[hubEnd].binding, farBinding.shapeID != partnerFar.shapeID else { return plain }
        let shapes = Connectables(shapes: context)
        guard let hub = shapes[hubBinding.shapeID], let far = shapes[farBinding.shapeID], let partnerShape = shapes[partnerFar.shapeID],
              let here = ArrowGeometry.anchor(of: arrow[hubEnd.opposite], in: far),
              let there = ArrowGeometry.anchor(of: partner[hubEnd], in: partnerShape) else { return plain }
        let centre = CGPoint(x: hub.bounds.midX, y: hub.bounds.midY)
        if ArrowThrough.isStraight(here, hub: centre, there) { return EndLine(hubEnd: hubEnd, bend: 0) }
        // The arrow's own start and end, as it runs.
        let (start, end) = hubEnd == .end ? (here, centre) : (centre, here)
        return EndLine(hubEnd: hubEnd, bend: ArrowThrough.bend(from: start, to: end, awayFrom: there))
    }

    /// The arrow as the geometry the editor keeps has it: for an end of a relationship type, its part of the line through the pill;
    /// for one with a look (`ArrowDetail`), its marked ends' heads and its width.
    func arrowGeometry(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> ArrowGeometry {
        arrowGeometry(shape.props, detail: context.geometry(of: shape.id)?.arrowDetail, in: context)
    }
}
