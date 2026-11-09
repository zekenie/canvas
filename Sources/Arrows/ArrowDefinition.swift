import AppKit
import Canvas
import Colors
import Connections
import ContextMenus
import Geometry
import LanguageRules
import Mentions
import Publishing
import Selection
import Types

/// Arrows as a shape kind: no box; handles; their own translation; painted just above the
/// highest shape they're bound to. Each capability is its own extension.
@MainActor
struct ArrowDefinition {
    func arrowGeometry(_ arrow: Arrow, in context: ShapeContext) -> ArrowGeometry {
        let connectables = Connectables(shapes: context)
        return ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
    }
}

/// Nothing binds to an arrow, so a stand-in for one would mean nothing: an arrow is never public, and holds no `private`.
extension ArrowDefinition: NeverPublic {}

extension ArrowDefinition: ShapeDefinition {
    /// Draws in world coordinates; the caller has already applied the camera transform. With a
    /// label, the body (heads and all) is cut where it is, and its text is drawn there; while it's
    /// edited, the editing view draws the text, over the cut, an empty label's too.
    func render(_ shape: ShapeRecord<Arrow>, in context: RenderContext) {
        let kept = context.shapes.geometry(of: shape.id), detail = kept?.arrowDetail
        let cg = context.cg
        let colors = context.colors(of: shape)
        let width = detail?.width ?? ArrowStyle.strokeWidth
        cg.saveGState()
        if let drawing = detail?.drawing {
            // A level arrow, or one with a look: what its kept geometry drew, its body, heads and marks, worked out nothing again.
            let laid = context.isEditing ? ArrowLabels.laid(of: shape, on: arrowGeometry(of: shape, in: context.shapes), in: context.shapes, editing: true)
                                         : kept.flatMap(ArrowLabels.laid(from:))
            if let laid { clip(cg, around: laid.frame, reaching: drawing.whole.boundingBoxOfPath, width: width) }
            cg.addPath(drawing.body)
            cg.addPath(drawing.heads)
            cg.addPath(drawing.marks)
        } else {
            // As the kept geometry has it: an end of a relationship type is its part of the line through the pill (`EndLine`), worked out once.
            let geometry = arrowGeometry(shape.props, detail: detail, in: context.shapes)
            // The label as the kept geometry has it (asked of Adornments' layout input once, not each frame); while it is edited, as it is edited.
            let laid = context.isEditing ? ArrowLabels.laid(of: shape, on: geometry, in: context.shapes, editing: true)
                                         : kept.flatMap(ArrowLabels.laid(from:))
            if let laid { clip(cg, around: laid.frame, reaching: geometry.bodyPath.boundingBoxOfPath, width: width) }
            cg.addPath(geometry.bodyPath)
            cg.addPath(geometry.arrowheadsPath(strokeWidth: width))
        }
        cg.setStrokeColor(colors?.solid ?? ArrowStyle.color.cgColor)
        cg.setLineWidth(width)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
        cg.restoreGState()
        let laid = context.isEditing ? nil : kept.flatMap(ArrowLabels.laid(from:))
        // The pill that leads the label is Adornments' (drawn over the canvas, where it is clicked): the body is cut around it.
        if let laid, shape.props.hasText { context.drawMentionText(ArrowLabels.placement(of: shape.props.text, in: laid.text, ink: colors?.ink)) }
    }

    /// Clips to everything around the label's cut: what the body (`body`, its bounds) and its heads and marks reach, less the cut.
    private func clip(_ cg: CGContext, around label: CGRect, reaching body: CGRect, width: CGFloat) {
        let pad = max(width * 4, ArrowMarks.circleCentre + ArrowMarks.circleRadius + width)
        let reach = body.union(label).insetBy(dx: -pad, dy: -pad)
        cg.addRect(reach)
        cg.addPath(ArrowLabels.cut(label))
        cg.clip(using: .evenOdd)
    }

    /// Open: arrows never bind to arrows. Its label is part of it (`label`), and its bounds hold
    /// it, as tldraw's geometry does.
    func geometry(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> ShapeGeometry {
        // An end of a relationship type is half of a line through its pill, with no head at it and no words (`EndLine`).
        let line = endLine(of: shape, in: context)
        // How its connection's meaning says it looks (its ends' marks, its width), asked here, kept, never per frame.
        let look = look(of: shape, in: context)
        var detail: ArrowDetail? = line == nil && look == nil ? nil
            : ArrowDetail(line: line, look: look, width: look?.lineWidth ?? ArrowStyle.strokeWidth)
        let geometry = arrowGeometry(shape.props, detail: detail, in: context)
        // A level arrow, or one with a look, keeps what a frame draws (a plain one keeps nothing, and is drawn as ever).
        if look != nil || geometry.isLevel {
            var kept = detail ?? ArrowDetail(line: nil, look: nil, width: ArrowStyle.strokeWidth)
            kept.drawing = ArrowDrawing(geometry, detail: kept)
            detail = kept
        }
        var bounds = geometry.bodyPath.boundingBoxOfPath
        let laid = line == nil ? ArrowLabels.laid(of: shape, on: geometry, in: context) : nil
        if let laid { bounds = bounds.union(laid.frame) }
        return ShapeGeometry(outline: [geometry.start, geometry.middle, geometry.end], bounds: bounds, isClosed: false, label: laid?.frame,
                             labelLead: laid?.lead, detail: detail)
    }

    /// Where its label is, as its geometry has it (kept, so measured once): its text's, and the pill that leads it.
    func labelFrame(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> CGRect? {
        context.geometry(of: shape.id)?.label
    }

    /// On the body, or anywhere on its label (tldraw's filled label rectangle).
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Arrow>, in context: ShapeContext) -> Bool {
        let margin = ArrowStyle.hitMargin / context.zoom + ArrowStyle.strokeWidth / 2
        if arrowGeometry(of: shape, in: context).distance(to: point) <= margin { return true }
        return labelFrame(of: shape, in: context)?.contains(point) ?? false
    }

    /// How far `hitTest` reaches past the body (its geometry's bounds): half the stroke, and the margin.
    var hitMargin: HitMargin { HitMargin(world: ArrowStyle.strokeWidth / 2, view: ArrowStyle.hitMargin) }

    /// The body and its heads; with a label, the body less the label's cut, and the cut's outline
    /// (tldraw's indicator).
    func indicatorPath(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> CGPath {
        let detail = context.geometry(of: shape.id)?.arrowDetail
        // A level arrow's, or one with a look's, as it is kept: its marks are outlined too (as tldraw's indicator holds its heads).
        let geometry = detail?.drawing == nil ? arrowGeometry(of: shape, in: context) : nil
        let body = detail?.drawing?.body ?? geometry?.bodyPath ?? CGMutablePath()
        let path = CGMutablePath()
        if let label = labelFrame(of: shape, in: context) {
            let cut = ArrowLabels.cut(label)
            path.addPath(body.lineSubtracting(cut))
            path.addPath(cut)
        } else {
            path.addPath(body)
        }
        if let drawing = detail?.drawing {
            path.addPath(drawing.heads)
            path.addPath(drawing.marks)
        } else if let geometry {
            path.addPath(geometry.arrowheadsPath(strokeWidth: ArrowStyle.strokeWidth))
        }
        return path
    }
}

extension ArrowDefinition {
    /// Whether an arrow's end is drawn as its look says (a key's mark), its stored head unused: nothing to toggle there.
    static func isMarked(_ end: ArrowEnd, of id: ShapeID, in context: ShapeContext) -> Bool {
        context.geometry(of: id)?.arrowDetail?.isMarked(end) ?? false
    }
}

extension ArrowDefinition: StrokedShape {
    /// The stroke `render` draws the body and its heads with, whatever the arrow's props: what a
    /// tinted outline of an arrow covers (`Outlines.tinted`), so the line doesn't show along its middle.
    func lineWidth(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> CGFloat {
        context.geometry(of: shape.id)?.arrowDetail?.width ?? ArrowStyle.strokeWidth
    }
}

extension ArrowDefinition: BrushHitTesting {
    /// Exact, against the visible body: a brush in the hollow of a bent arrow's bounds doesn't
    /// select it (arrows are open, as in tldraw), nor does one over only the hidden stub inside a
    /// bound shape. A brush that reaches its label selects it too, as tldraw's filled label does.
    func brushHitTest(_ brush: CGRect, on shape: ShapeRecord<Arrow>, in context: ShapeContext) -> Bool {
        let geometry = arrowGeometry(of: shape, in: context)
        if geometry.crosses(brush.polygon) { return true }
        return labelFrame(of: shape, in: context)?.intersects(brush) ?? false
    }
}

extension ArrowDefinition: HandleProviding {
    /// The bend handle hides when it would crowd an end.
    func handles(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> [HandleLocation<ArrowHandle>] {
        let geometry = arrowGeometry(of: shape, in: context)
        let camera = context.camera
        let middle = camera.toView(geometry.middle)
        // Half of an arc through a relationship type's pill has no bend of its own: the pill is dragged to bend it.
        var isMiddleClear = context.geometry(of: shape.id)?.arrowDetail?.line?.bend == nil && [geometry.startHandle, geometry.endHandle].allSatisfy {
            camera.toView($0).distance(to: middle) >= ArrowStyle.middleHandleMinDistance
        }
        // Not over the pill that leads its label, which is Adornments' and is pressed (a deviation from tldraw, only for an arrow
        // with a pill): the handle would sit on its name.
        if isMiddleClear, let lead = context.geometry(of: shape.id)?.labelLead,
           lead.insetBy(dx: -ArrowStyle.leadHandleClearance / camera.zoom, dy: -ArrowStyle.leadHandleClearance / camera.zoom).contains(geometry.middle) {
            isMiddleClear = false
        }
        let visible: [ArrowHandle] = [.terminal(.start), .terminal(.end)] + (isMiddleClear ? [.middle] : [])
        // A half of the line through a relationship type's pill: its end at the pill is where the line meets the pill, not the pill's
        // middle, where the handle would cover the type's name.
        let hubEnd = context.geometry(of: shape.id)?.arrowDetail?.line?.hubEnd
        return visible.map { handle in
            if case .terminal(let end) = handle, end == hubEnd { return HandleLocation(handle, at: geometry.visiblePoint(at: end)) }
            return HandleLocation(handle, at: geometry.point(for: handle))
        }
    }

    /// A double-click on an end toggles its head; on the bend handle, it edits the label, as a
    /// double-click on the arrow does (tldraw's: a handle's double-click that changes nothing edits).
    func pressHandle(_ handle: ArrowHandle, of shape: ShapeRecord<Arrow>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress {
        if pointer.clickCount == 2, case .terminal(let end) = handle {
            // A marked end has no head to toggle (the look says what it is drawn with): the double-click does nothing there.
            if !ArrowDefinition.isMarked(end, of: shape.id, in: editor.shapeContext) {
                editor.transact("Toggle Arrowhead") { $0.update(shape.id, as: Arrow.self) { $0.props.toggleArrowhead(at: end) } }
            }
            return .consumed
        }
        if pointer.clickCount == 2, handle == .middle {
            // As a double-click on the arrow is (an end of a relationship type opens the card instead of editing words it has none of).
            editor.open(shape.id, at: pointer.world, clickCount: pointer.clickCount)
            return .consumed
        }
        // Pressing a bound end outlines the shape it's bound to.
        if case .terminal(let end) = handle, let binding = shape.props[end].binding {
            editor.hintedShapeID = binding.shapeID
            editor.hintedPart = binding.part
        }
        return .drag
    }

    func dragSession(for handle: ArrowHandle, of shape: ShapeRecord<Arrow>, from origin: CGPoint, in editor: CanvasEditor) -> any Session {
        let targeting = editor.service(ArrowTargeting.self)!
        let arrow = shape.props
        var isPrecise = false
        if case .terminal(let end) = handle, let binding = arrow[end].binding {
            isPrecise = binding.isPrecise
        }
        // From where the handle is drawn: a half's end at a relationship type's pill is where its line meets the pill (`handles(of:)`).
        var point = targeting.geometry(of: arrow, id: shape.id).point(for: handle)
        if case .terminal(let end) = handle, let line = editor.shapeContext.geometry(of: shape.id)?.arrowDetail?.line, line.hubEnd == end {
            point = arrowGeometry(of: shape, in: editor.shapeContext).visiblePoint(at: end)
        }
        let drag = ArrowHandleDragSession(arrowID: shape.id, handle: handle,
                                          handleOffset: point - origin,
                                          isPrecise: isPrecise, targeting: targeting)
        if case .terminal(let end) = handle, arrow[end].binding != nil, !isPrecise {
            drag.startDragPreciseTimer()
        }
        return drag
    }
}

extension ArrowDefinition: CustomTranslation {
    /// tldraw's arrow onTranslateStart and onTranslate:
    /// - Moving with a shape it's bound to, every binding stays (an end bound to a shape left
    ///   behind stretches) and free ends move by the delta.
    /// - Moving without any of its shapes (alone, or with unrelated shapes), bound ends are made
    ///   precise where they are, committed before the first move. Each end stays bound, its anchor
    ///   sliding with the pointer, while that point is on its shape; off it, the end lets go, and
    ///   it binds again if the point comes back.
    /// Deliberate, pre-existing deviation: the ends probe at the full delta (tldraw: delta × 0.5),
    /// as the POC's transcript pins. And one of this app's: an end bound to a part (a row) stays bound to it, where it is,
    /// however the arrow moves alone, since its side point is on the shape's edge and any move outward would free it.
    func beginTranslation(of shape: ShapeRecord<Arrow>, movingWith moving: Set<ShapeID>,
                          in transaction: inout Transaction) -> ShapeTranslation<Arrow> {
        // Ends bound to a part stay as they are; the rest go by tldraw's rules.
        let ends = [ArrowEnd.start, .end].filter { shape.props[$0].binding?.part == nil }
        var arrow = shape.props
        let movesWithItsShapes = [ArrowEnd.start, .end].contains { end in arrow[end].binding.map { moving.contains($0.shapeID) } ?? false }
        if movesWithItsShapes {
            let start = arrow
            return ShapeTranslation { delta, shape, _ in
                for end in ends {
                    if case .free(let point) = start[end] { shape.props[end] = .free(point + delta) }
                }
            }
        }
        let connectables = Connectables(shapes: transaction.shapes)
        let geometry = ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
        var bindings: [ArrowEnd: ArrowBinding] = [:]
        for end in ends {
            guard var binding = arrow[end].binding, let bounds = connectables[binding.shapeID]?.bounds else { continue }
            binding.normalizedAnchor = normalizedAnchor(geometry.handlePoint(at: end), in: bounds)
            binding.isPrecise = true
            arrow[end] = .bound(binding)
            bindings[end] = binding
        }
        transaction.update(shape.id, as: Arrow.self) { $0.props = arrow }
        let startHandle = geometry.startHandle, endHandle = geometry.endHandle
        // Each end sees only what the plugins' rules let it bind to (tldraw's onTranslate, which
        // looks for the shape under an end through its canBind filter).
        let rules = transaction.shapes.registry.contributions(to: ArrowBindingRules.self).map(\.value)
        let record = transaction.shapes.shape(shape.id), registry = transaction.shapes.registry, shapes = transaction.shapes
        func accepts(_ end: ArrowEnd) -> ((AnyShapeRecord) -> Bool)? {
            guard !rules.isEmpty, let record else { return nil }
            return { candidate in ArrowBindingQuery(arrow: record, end: end, shape: candidate, registry: registry, shapes: shapes).isAllowed(by: rules) }
        }
        let filters = [ArrowEnd.start: accepts(.start), .end: accepts(.end)]
        return ShapeTranslation { delta, shape, shapes in
            let connectables = Connectables(shapes: shapes)
            for (end, handle, binding) in [(ArrowEnd.start, startHandle, bindings[.start]), (.end, endHandle, bindings[.end])]
            where ends.contains(end) {
                let point = handle + delta
                if var binding, let target = connectables.shape(at: point, accepting: filters[end] ?? nil), target.id == binding.shapeID {
                    binding.normalizedAnchor = normalizedAnchor(point, in: target.bounds)
                    shape.props[end] = .bound(binding)
                } else {
                    shape.props[end] = .free(point)
                }
            }
        }
    }
}

extension ArrowDefinition: PaintOrderAnchored {
    /// Just above the highest shape it's bound to, so it's never hidden behind its own shapes; an arrow with an end at a row
    /// (a key, writes, reads, calls) just below the lowest (`paintsBelowAnchor`), however it was made, so a card it passes
    /// covers it and no line strikes through a table's text. Its ends sit at the rows' sides, outside the cards, so its
    /// marks and heads still show, unless a container of one end (a database, a frame) is painted after the lower end: that
    /// container's surface would hide the arrow, its end and its mark, so the arrow is just above the container instead,
    /// still under the cards in it. A departure from tldraw, whose new arrows go on top.
    func paintAnchor(of shape: ShapeRecord<Arrow>, in document: CanvasDocument) -> ShapeID? {
        Self.placing(shape.props, in: document)?.shape
    }

    func paintsBelowAnchor(_ shape: ShapeRecord<Arrow>, in document: CanvasDocument) -> Bool {
        Self.placing(shape.props, in: document)?.below ?? false
    }

    /// The shape an arrow is painted against, and whether just below it. From the arrow's props and the order and
    /// containment of the document alone.
    private static func placing(_ arrow: Arrow, in document: CanvasDocument) -> (shape: ShapeID, below: Bool)? {
        let ends = [arrow.start, arrow.end].compactMap { terminal in
            terminal.binding.flatMap { binding in document.index(of: binding.shapeID).map { (index: $0, id: binding.shapeID) } }
        }
        guard let lowest = ends.min(by: { $0.index < $1.index }), let highest = ends.max(by: { $0.index < $1.index }) else { return nil }
        guard arrow.start.binding?.part != nil || arrow.end.binding?.part != nil else { return (highest.id, false) }
        // The innermost container of an end painted after the lowest shape (a member is above its container, so only the
        // higher end can have one): the arrow goes just above it.
        var covering: (index: Int, id: ShapeID)?
        var container = document[highest.id]?.container
        var steps = 0
        while let held = container, steps < 64, let index = document.index(of: held) {
            if index > lowest.index, index > (covering?.index ?? -1) { covering = (index, held) }
            container = document[held]?.container
            steps += 1
        }
        if let covering { return (covering.id, false) }
        return (lowest.id, true)
    }
}

extension Arrow {
    /// The arrow with `ends` let go of the shapes they're bound to: each end stays where it
    /// visibly is, and the arrow keeps its curve.
    @MainActor
    func releasing(_ ends: Set<ArrowEnd>, markReach: (start: CGFloat, end: CGFloat) = (0, 0), connectables: Connectables) -> Arrow {
        let geometry = ArrowGeometry(arrow: self, strokeWidth: ArrowStyle.strokeWidth, markReach: markReach) { connectables[$0] }
        var arrow = self
        if let bend = geometry.bendKeepingCurve(movingHandlesToVisibleEndsAt: ends) {
            arrow.bend = bend
        }
        for end in ends {
            arrow[end] = .free(geometry.visiblePoint(at: end))
        }
        if let body = geometry.levelBody {
            // A level curve can't be kept by a bend of the new arrow (let go at both ends it is an arc or a line; at one, a
            // curve whose free end has no way out), so the arrow keeps the nearest it can: its middle, by length.
            arrow.bend = 0
            let freed = ArrowGeometry(arrow: arrow, strokeWidth: ArrowStyle.strokeWidth) { connectables[$0] }
            arrow.bend = (body.measured().point(atFraction: 0.5) - freed.bendOrigin).dot(freed.bendAxis)
        }
        return arrow
    }
}

extension ArrowDefinition: ShapeReferencing {
    /// An end bound to a shape `map` renames stays bound, to that one: a copy of an arrow is bound
    /// to the copies of its shapes. An end bound to a shape `map` drops lets go of it where it's
    /// drawn, and the arrow keeps its curve: deleting the shape does this (inside the deleting
    /// transaction, while the shape still exists), and so does copying the arrow without it, as
    /// tldraw's copy does. Nil when such a shape isn't in `context`, so where its end is drawn
    /// can't be told.
    func remappingReferences(of shape: ShapeRecord<Arrow>, _ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> Arrow? {
        let connectables = Connectables(shapes: context)
        var released: Set<ArrowEnd> = []
        var remapped: [ArrowEnd: ShapeID] = [:]
        for end in [ArrowEnd.start, .end] {
            guard let binding = shape.props[end].binding else { continue }
            if let id = map(binding.shapeID) {
                remapped[end] = id
            } else if connectables[binding.shapeID] != nil {
                released.insert(end)
            } else {
                return nil
            }
        }
        var arrow = released.isEmpty ? shape.props : shape.props.releasing(released, markReach: context.geometry(of: shape.id)?.arrowDetail?.markReach ?? (0, 0), connectables: connectables)
        for (end, id) in remapped {
            guard var binding = arrow[end].binding else { continue }
            binding.shapeID = id
            arrow[end] = .bound(binding)
        }
        return arrow
    }

    /// The parts its ends are bound to (rows), each with its shape.
    func boundParts(of shape: ShapeRecord<Arrow>) -> [PartAddress] {
        [shape.props.start, shape.props.end].compactMap { terminal in terminal.binding.flatMap { $0.part == nil ? nil : $0.address } }
    }

    /// Each end bound to a part `move` sends elsewhere is bound there: another part (precise and exact, as a part end is,
    /// its stored anchor kept as where it last was), or a shape as a whole (its middle, as a port's drag binds one). Nil
    /// when nothing moved.
    func movingParts(of shape: ShapeRecord<Arrow>, _ move: (PartAddress) -> PartAddress) -> Arrow? {
        var arrow = shape.props
        for end in [ArrowEnd.start, .end] {
            guard var binding = arrow[end].binding, binding.part != nil else { continue }
            let moved = move(binding.address)
            guard moved != binding.address else { continue }
            binding.shapeID = moved.shape
            binding.part = moved.part
            if moved.part == nil {
                binding.normalizedAnchor = CGPoint(x: 0.5, y: 0.5)
                binding.isPrecise = false
                binding.isExact = false
            }
            arrow[end] = .bound(binding)
        }
        return arrow == shape.props ? nil : arrow
    }
}

/// For a selected arrow bound to shapes: a faint dashed stub from each anchor to where the arrow
/// visibly ends, with a dot at an imprecise anchor (the shape's center) or a cross at a precise
/// one. Exact ends get neither, since the arrow runs right up to the anchor.
struct BindingHintsOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor
        // The arrow being drawn or re-aimed (the selection, but for one drawn for another plugin's
        // gesture, which leaves the selection alone), else the selected one.
        let drag = editor.session as? ArrowHandleDragSession
        guard editor.currentToolID == .select || drag != nil,
              let id = drag?.arrowID ?? editor.selection,
              let arrow = editor.document[id]?.typed(as: Arrow.self)?.props else { return }
        let geometry = ArrowDefinition().arrowGeometry(arrow, detail: overlay.shapes.geometry(of: id)?.arrowDetail, in: overlay.shapes)
        let zoom = overlay.zoom
        let lineWidth = ArrowStyle.bindingHintWidth / zoom
        let context = overlay.cg

        context.saveGState()
        context.setAlpha(ArrowStyle.bindingHintOpacity)
        context.setStrokeColor(ArrowStyle.bindingHintColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for end in [ArrowEnd.start, .end] {
            guard let binding = arrow[end].binding, !binding.isExact else { continue }
            let handle = geometry.handlePoint(at: end)
            let markerRadius = (binding.isPrecise ? ArrowStyle.bindingCrossSize / 2 : ArrowStyle.bindingDotRadius) / zoom

            if let stub = geometry.bindingStub(at: end, inset: markerRadius) {
                context.saveGState()
                // Dashes get too small to read when zoomed far out.
                if zoom >= 0.2 {
                    context.setLineDash(phase: 0, lengths: [2 * lineWidth, 2 * lineWidth])
                }
                context.addPath(stub)
                context.strokePath()
                context.restoreGState()
            }

            if binding.isPrecise {
                // A cross, turned to line up with the arrow's path.
                let direction = geometry.directionFromHandle(at: end)
                let half = ArrowStyle.bindingCrossSize / 2 / zoom
                let a = direction.rotated(around: .zero, by: .pi / 4) * half
                let b = direction.rotated(around: .zero, by: -.pi / 4) * half
                context.move(to: handle - a)
                context.addLine(to: handle + a)
                context.move(to: handle - b)
                context.addLine(to: handle + b)
            } else {
                context.addEllipse(in: CGRect(
                    x: handle.x - markerRadius, y: handle.y - markerRadius,
                    width: markerRadius * 2, height: markerRadius * 2
                ))
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}

public struct ArrowsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .arrows }
    public func register(into registrar: inout PluginRegistrar) {
        // What an end's drag reads of the keys (`ArrowTargeting`), for the Keyboard Shortcuts window.
        registrar.keyHint("⌥ Drag an Arrow's End", "Bind It Exactly", while: .pointer)
        registrar.keyHint("⌘ or ⌃ Drag an Arrow's End", "Leave It Unbound", while: .pointer)
        registrar.keyHint("⇧ Drag an Arrow's End", "Snap Its Angle", while: .pointer)
        registrar.shape(ArrowDefinition()) { arrow in
            // No tool places one (a port's drag draws it, through `ArrowPortsPlugin`), so it names itself.
            arrow.label("Arrow", systemImage: ArrowStyle.symbol)
            arrow.arrowRow()
            // Its label is mention text, centered on its body: pills, and the slash commands its editor hosts.
            // Its frame is measured by the names its mentions show now: a rename lays it out again.
            arrow.mentionLayout { $0.props.text }
            arrow.mentionText { arrow, shapes in
                guard arrow.props.hasText, let label = shapes.geometry(of: arrow.id).flatMap(ArrowLabels.textFrame(of:)) else { return [] }
                return [ArrowLabels.placement(of: arrow.props.text, in: label)]
            }
            // It may have a color of its own (`ColorsPlugin`): its line, heads and label; with none it is
            // `ArrowStyle.color`, as it was.
            arrow.colorable()
            arrow.checkedByRules()
            // And types: its label says what it is (`/is-a`), where it's drawn, and fits to nothing but
            // itself.
            arrow.typeWords(\.text, drawnIn: { arrow, shapes in
                guard arrow.props.hasText, let label = shapes.geometry(of: arrow.id).flatMap(ArrowLabels.textFrame(of:)) else { return nil }
                return ArrowLabels.placement(of: arrow.props.text, in: label)
            })
            arrow.typeable()
            arrow.relating()                                   // and may be the end of a relationship type
            // An arrow that is an end of a relationship type has no words drawn (`EndLine`): a double-click or Return opens the type's card at
            // the row name it gives, where any other arrow edits its label.
            arrow.opens("Open", where: { shape, editor in editor.relationships?.end(shape.id) != nil }) { shape, editor in
                guard let hub = editor.relationships?.end(shape.id)?.type else { return }
                editor.definitionCards?.open(hub, focus: .endName(shape.id))
            }
            // Its ends, bend and label are parts (⌥Tab), each taking the arrow keys as its drag moves it (`ArrowParts`).
            arrow.shapeParts(named: "ArrowHandles") { editor, shape in ArrowParts.parts(of: shape, in: editor) }
            // VoiceOver: "Arrow, from Checkout to Payment", its label's words its value.
            arrow.accessibility { shape, editor in ArrowParts.accessibility(of: shape, in: editor) }
            // Each head on or off from the Shape menu, as a double-click on its end does (no pointer needed).
            // Left out for an end its look marks (a key's), which has no head to toggle.
            arrow.contextMenu {
                MenuItem(ArrowStyle.toggleStartHead, shownIn: { !ArrowDefinition.isMarked(.start, of: $0, in: $1.shapeContext) }) { $0.toggleArrowhead(at: .start) }
                MenuItem(ArrowStyle.toggleEndHead, shownIn: { !ArrowDefinition.isMarked(.end, of: $0, in: $1.shapeContext) }) { $0.toggleArrowhead(at: .end) }
            }
        }
        registrar.service { ArrowTargeting(editor: $0) }
        registrar.service { ArrowRowNesting(editor: $0) }
        registrar.overlay(BindingHintsOverlay())
        // Arrows let go of shapes as they're deleted through `ShapeReferencing`, which the core asks.
    }
}

extension CanvasEditor {
    /// An arrow's resolved geometry, for tests and tools.
    public func arrowGeometry(of id: ShapeID) -> ArrowGeometry? {
        guard let arrow = document[id]?.typed(as: Arrow.self) else { return nil }
        return ArrowDefinition().arrowGeometry(of: arrow, in: shapeContext)
    }

    /// How an arrow looks as its kept geometry has it (its ends' marks, its width: `ConnectionLooks`), nil for one no plugin
    /// gives a look; for tests and what reads an arrow.
    public func arrowLook(of id: ShapeID) -> ConnectionLook? {
        shapeContext.geometry(of: id)?.arrowDetail?.look
    }

    /// Where an arrow's label is, in world units: nil while it says nothing.
    public func arrowLabelFrame(of id: ShapeID) -> CGRect? {
        guard let arrow = document[id]?.typed(as: Arrow.self) else { return nil }
        return ArrowDefinition().labelFrame(of: arrow, in: shapeContext)
    }
}
