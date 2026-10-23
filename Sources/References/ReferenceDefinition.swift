import AppKit
import Canvas
import Publishing

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct ReferenceDefinition {}

/// A capsule, the whole frame, so its outline is its edge (a rounded box, which the core stands off
/// its edge by arithmetic). Its look is `ReferenceLook`'s, from what it stands for now.
extension ReferenceDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Reference>, in context: RenderContext) {
        // The service once: a frame draws a thousand pills.
        let state = context.service(ReferenceState.self)
        let standing = condition(of: shape, state: state, in: context)
        let handsOff = context.isEditing && state?.isHandingOff(shape.id) == true
        let look = context.isEditing ? ReferenceLook(editing: standing, handsOff: handsOff)
            : ReferenceLook(standing, mismatch: state?.drawnMismatch(of: shape.id) != nil, place: state?.drawnPlace(of: shape.id))
        draw(look, in: shape.frame, editing: context.isEditing, context)
    }

    func indicatorPath(of shape: ShapeRecord<Reference>, in context: ShapeContext) -> CGPath {
        ReferenceStyle.capsule(shape.frame)
    }
}

/// Zoomed out, one square fill: no text, no rounding, no symbol, so rects batch. A pill that stands
/// for nothing is the lighter one. Looking at the target is a dictionary hit and a public check, never
/// its name (`ReferenceCondition.standsForNothing`).
extension ReferenceDefinition: CustomSkeleton {
    func renderSkeleton(_ shape: ShapeRecord<Reference>, in context: RenderContext) {
        let cg = context.cg
        let asks = shape.props.mode == .dynamic
        let nothing = ReferenceCondition.standsForNothing(shape.props, status: asks ? context.service(ReferenceState.self)?.answer(of: shape.id) : nil,
                                                          registry: context.shapes.registry, lookup: { context.shape(inFile: $0) })
        cg.setFillColor((nothing ? ReferenceStyle.skeletonMissingFill : ReferenceStyle.skeletonFill).cgColor)
        cg.fill(shape.frame)
    }
}

/// Never public: nothing could stand for one, and a reference stands for others.
extension ReferenceDefinition: NeverPublic {}

/// A pill placed and left empty is thrown away, as an empty text shape is in tldraw: nothing was
/// asked of it. One that stands for something, or has words, is kept.
extension ReferenceDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Reference>, context: EditContext<Reference>) -> EditingView {
        let editor = ReferenceEditor(reference: shape, context: context)
        return EditingView(view: editor, firstResponder: editor.textView)
    }

    func discardsWhenEditingEnds(_ props: Reference) -> Bool { props.mode == .empty }

    var editingStepName: String? { "Edit Reference" }
}

/// A reference made from properties (the command line's `draw`: a `query:`) is fitted as the writers
/// would have left it: as wide as what it says, 32 tall. A direct pill already wider than its label
/// asks, and not at the width it was placed at, was fitted by a pick with its note's board after the
/// name (`ReferenceEdits.pick`), a room props can't name and this can't know; it keeps that width.
extension ReferenceDefinition: DerivedProps {
    func derive(_ props: inout Reference) {
        let keeps = props.mode == .direct && props.frame.width > ReferenceEdits.width(of: props)
            && props.frame.width != ReferenceStyle.defaultWidth
        if keeps { props.frame.size.height = ReferenceStyle.height } else { ReferenceEdits.fit(&props) }
    }
}
