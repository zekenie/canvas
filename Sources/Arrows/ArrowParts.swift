import Canvas
import CoreGraphics
import Geometry
import Mentions
import Selection

// An arrow's handles by the keys (keyboard navigation's principles 1 and 10: a drag has a keyboard way).
// With the arrow selected, ⌥Tab goes into its parts (Selection's `ShapeParts`), in reading order: its start,
// its bend, its label, its end, each where it is drawn. Each takes the arrow keys as its drag would move it
// (one undo step while a key is held, as a nudge is), and Return or Space presses it:
// - An end: the arrows move it a world unit (⇧: ten). A free end moves; a bound one slides its anchor
//   across its shape, precise, and lets go where it leaves the shape, as a lone arrow's ends do when it is
//   moved (`CustomTranslation`). ⌥⌘ and an arrow bind it to the nearest shape that way (Selection's
//   `nearestShape`, the rule ⌥⌘ steps between shapes by) through `ArrowTargeting.bindTerminal`, imprecise,
//   as a quick drag released there does. Return toggles its head, as a double-click on it does.
// - An end bound to a row (a key's): ↑ ↓ step it to the row above or below on its shape ("Move Arrow End", one step while
//   held), announced by the row's name ("id in customers"); ← → change nothing, since its side follows the far end. ⌥⌘ and
//   an arrow bind it to the nearest shape that way, at the row nearest the end's height.
// - The bend: the arrows move it as its drag does, across the arrow (a level arrow bends with ↑ ↓, an
//   upright one with ← →); Return straightens the arrow.
// - The label: the arrows slide it along the body as its drag does (no snap to halfway, which would
//   hold it there); Return edits it, as a click on it does.
// tldraw has none of this: its arrow keys nudge the selection, and its handles are the pointer's alone.

/// What an arrow lists of itself as parts, and what each does.
@MainActor
enum ArrowParts {
    /// Which part: an end, the bend, or the label.
    enum Part: Hashable, Sendable {
        case handle(ArrowHandle)
        case label
    }

    /// The arrow's parts, in no order (Selection reads them in reading order): its ends, its bend while it has
    /// one of its own (half of a line through a relationship type's pill has none: the pill bends it), its
    /// label while it says something. None for a read-only arrow, which has no handles either.
    static func parts(of shape: ShapeRecord<Arrow>, in editor: CanvasEditor) -> [ShapePart] {
        guard !editor.isReadOnly(shape.id) else { return [] }
        let definition = ArrowDefinition(), context = editor.shapeContext
        let id = shape.id
        let side = ArrowStyle.handlePartSize / editor.camera.zoom
        func rect(at point: CGPoint) -> CGRect { CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side) }
        // Where the handles are drawn (a half's end at a relationship type's pill is where its line meets the pill).
        let drawn = definition.handles(of: shape, in: context)
        var parts: [ShapePart] = []
        for end in [ArrowEnd.start, .end] {
            guard let point = drawn.first(where: { $0.handle == .terminal(end) })?.point else { continue }
            parts.append(ShapePart(id: Part.handle(.terminal(end)), title: end == .start ? ArrowStyle.startPart : ArrowStyle.endPart,
                                   role: .handle, rect: rect(at: point),
                                   press: { toggleHead(at: end, of: id, in: $0) },
                                   adjust: { adjustEnd(end, of: id, by: $1, in: $0) }))
        }
        if context.geometry(of: id)?.arrowDetail?.line?.bend == nil {
            let middle = definition.arrowGeometry(of: shape, in: context).middle
            parts.append(ShapePart(id: Part.handle(.middle), title: ArrowStyle.bendPart, role: .handle, rect: rect(at: middle),
                                   press: { straighten(id, in: $0) },
                                   adjust: { bend(id, by: $1, in: $0) }))
        }
        if shape.props.hasText, let label = definition.labelFrame(of: shape, in: context) {
            parts.append(ShapePart(id: Part.label, title: ArrowStyle.labelPart, role: .handle, rect: label,
                                   press: { _ = $0.beginEditing(id) },
                                   adjust: { slideLabel(of: id, by: $1, in: $0) }))
        }
        return parts
    }

    /// Return on an end: its head on or off, the double-click's step.
    static func toggleHead(at end: ArrowEnd, of id: ShapeID, in editor: CanvasEditor) {
        // A marked end (a key's, `marked-end`): its look says what it is drawn with, so there is no head to toggle, and Return and
        // Space do nothing.
        guard !ArrowDefinition.isMarked(end, of: id, in: editor.shapeContext) else { return }
        editor.transact("Toggle Arrowhead") { $0.update(id, as: Arrow.self) { $0.props.toggleArrowhead(at: end) } }
    }

    /// An arrow key on an end: moved by the step, or with ⌥⌘ bound to the nearest shape that way. Every
    /// arrow key is taken, so none nudges the arrow while an end has the keyboard.
    static func adjustEnd(_ end: ArrowEnd, of id: ShapeID, by step: PartStep, in editor: CanvasEditor) -> Bool {
        guard let targeting = editor.service(ArrowTargeting.self), let arrow = targeting.arrow(id) else { return true }
        let from = targeting.geometry(of: arrow).handlePoint(at: end)
        if step.toNearest {
            bindNearest(end, of: id, from: from, toward: step.adjacentDirection, targeting: targeting)
            return true
        }
        if let binding = arrow[end].binding, binding.part != nil {
            stepRow(end, of: id, binding, by: step, targeting: targeting)
            return true
        }
        let point = from + step.offset
        let filter = targeting.filter(for: id, end)
        targeting.updateArrow(id) { arrow in
            // Bound, it stays bound while the point is on its shape, precise, the anchor where the point is.
            if var binding = arrow[end].binding, let shape = targeting.connectable(at: point, accepting: filter), shape.id == binding.shapeID {
                binding.normalizedAnchor = normalizedAnchor(point, in: shape.bounds)
                binding.isPrecise = true
                arrow[end] = .bound(binding)
            } else {
                arrow[end] = .free(point)
            }
        }
        return true
    }

    /// ↑ ↓ on an end bound to a row: bound to the shown row above or below it on its shape, at its side as before (the side is
    /// worked out from the far end when drawn), and VoiceOver told which. ← →, no row that way, or the row the other end is at,
    /// leave it as it is.
    private static func stepRow(_ end: ArrowEnd, of id: ShapeID, _ binding: ArrowBinding, by step: PartStep, targeting: ArrowTargeting) {
        guard step.direction.y != 0, let part = binding.part, let shape = targeting.connectables[binding.shapeID] else { return }
        let shown = shape.parts.filter(\.isShown)
        guard let at = shown.firstIndex(where: { $0.id == part }) else { return }
        let next = at + (step.direction.y < 0 ? -1 : 1)
        guard shown.indices.contains(next) else { return }
        let row = shown[next]
        // Never onto the row the other end is at: a key is not a loop on one row (connect refuses it too).
        if targeting.arrow(id)?[end.opposite].binding?.address == PartAddress(binding.shapeID, part: row.id) { return }
        var moved = binding
        moved.part = row.id
        if shape.bounds.width > 0, shape.bounds.height > 0 {
            moved.normalizedAnchor = normalizedAnchor(CGPoint(x: binding.normalizedAnchor.x * shape.bounds.width + shape.bounds.minX, y: row.rect.midY),
                                                      in: shape.bounds)
        }
        targeting.updateArrow(id) { $0[end] = .bound(moved) }
        let editor = targeting.editor
        if let name = editor.accessibleName(of: moved.address) { editor.announce(name) }
    }

    /// ⌥⌘ and an arrow on an end: bound to the nearest shape that way from where the end aims, of those it may
    /// bind to, other than the one it is bound to, as a quick drag of it released on that shape's middle
    /// binds; and VoiceOver is told which. Nothing that way leaves it as it is.
    private static func bindNearest(_ end: ArrowEnd, of id: ShapeID, from point: CGPoint, toward direction: AdjacentDirection,
                                    targeting: ArrowTargeting) {
        let editor = targeting.editor, connectables = targeting.connectables
        guard let arrow = targeting.arrow(id) else { return }
        let current = arrow[end].binding?.shapeID, accepts = targeting.filter(for: id, end)
        guard let target = editor.nearestShape(to: point, toward: direction, among: { record in
            record.id != current && connectables[record.id] != nil && (accepts?(record) ?? true)
        }), let shape = connectables[target] else { return }
        // Onto a shape whose rows it binds, the row nearest the end's height; else its middle.
        let byRow = editor.document[target].flatMap { record in
            editor.document[id].map { editor.registry.arrowBindsPart($0, end, of: record, in: editor.shapeContext) }
        } ?? false
        targeting.bindTerminal(of: id, end, to: byRow ? CGPoint(x: shape.bounds.midX, y: point.y) : shape.bounds.center, isPrecise: false,
                               modifiers: [], onto: shape)
        // No drag is under way to outline what the end aims at.
        editor.hintedShapeID = nil
        let bound = targeting.arrow(id)?[end].binding
        if let name = bound.flatMap({ editor.accessibleName(of: $0.address) }) ?? editor.accessibleDescription(of: target)?.name { editor.announce(name) }
    }

    /// Return on the bend: the arrow straight.
    static func straighten(_ id: ShapeID, in editor: CanvasEditor) {
        editor.transact("Straighten Arrow") { $0.update(id, as: Arrow.self) { $0.props.bend = 0 } }
    }

    /// An arrow key on the bend: the handle moved by the step as its drag moves it, so the bend follows the
    /// step's part across the arrow. A key along the arrow is taken and bends it no more.
    static func bend(_ id: ShapeID, by step: PartStep, in editor: CanvasEditor) -> Bool {
        guard let targeting = editor.service(ArrowTargeting.self), let arrow = targeting.arrow(id) else { return true }
        let change = step.offset.dot(targeting.geometry(of: arrow).bendAxis)
        guard abs(change) > ArrowStyle.keyBendEpsilon else { return true }
        targeting.updateArrow(id, named: "Bend Arrow") { $0.bend += change }
        return true
    }

    /// An arrow key on the label: its middle moved by the step to the nearest point of the body, as its drag
    /// moves it (the step "Move Label"). From where it is kept, so ← undoes → exactly, unless it is drawn
    /// elsewhere (kept clear of an end), when from where it is drawn, as a drag of it goes.
    static func slideLabel(of id: ShapeID, by step: PartStep, in editor: CanvasEditor) -> Bool {
        guard let body = editor.arrowGeometry(of: id)?.body, body.length > 0, let label = editor.arrowLabelFrame(of: id),
              let arrow = editor.document[id]?.typed(as: Arrow.self)?.props else { return true }
        let drawn = body.fraction(nearest: label.center)
        let from = abs(drawn - arrow.labelPosition) * body.length <= ArrowStyle.labelKeySlack ? arrow.labelPosition : drawn
        let position = body.fraction(nearest: body.point(at: from) + step.offset)
        guard position != arrow.labelPosition else { return true }
        editor.transact("Move Label") { $0.update(id, as: Arrow.self) { $0.props.labelPosition = position } }
        return true
    }

    /// What VoiceOver says of an arrow besides its kind: where it runs ("from Checkout to Payment", by the
    /// names of the shapes its ends are bound to, as VoiceOver says them), and its label's words.
    static func accessibility(of shape: ShapeRecord<Arrow>, in editor: CanvasEditor) -> AccessibleTraits {
        // A row's end by the row's name, read with its shape's ("id in customers").
        func name(_ end: ArrowEnd) -> String? {
            shape.props[end].binding.flatMap { editor.accessibleName(of: $0.address) ?? editor.accessibleDescription(of: $0.shapeID)?.name }
        }
        let runs = ArrowStyle.accessibleRun(from: name(.start), to: name(.end))
        let text = shape.props.hasText ? editor.mentions?.plainText(shape.props.text) ?? shape.props.text.plainText() : nil
        return AccessibleTraits(labelParts: runs.map { [$0] } ?? [], value: text)
    }
}
