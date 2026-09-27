import Canvas
import CoreGraphics
import Geometry

/// Per editor: which adornments each kind's shapes may show, found once per kind (the registry is
/// frozen), and what each shape shows, its labels made and measured, kept until a commit names the
/// shape or `adornmentsDidChange` does. Where they go is worked out when it's asked, from what's
/// kept: it follows the zoom, and geometry that follows other shapes, neither of which reaches a
/// service.
@MainActor
final class AdornmentState {
    private unowned let editor: CanvasEditor
    /// No plugin places any: nothing is looked at.
    let isEmpty: Bool
    /// Some adornment is clickable. Without one, no point is looked at for a button.
    private let hasButtons: Bool
    /// Each kind's contributions in claim order: its own (and bridges'), then every-shape ones whose
    /// `where` lets it in, less those of a type it has its own of; sorted by order, then first
    /// appearance.
    private var candidates: [ShapeKind: [AdornmentContribution]] = [:]
    /// Each shape's shown adornments (none, for most), dropped for the shapes each commit names and
    /// `adornmentsDidChange` names.
    private var kept: [ShapeID: [ShownAdornment]] = [:]
    /// The revision `kept` is up to date with. Read before this service has heard of a commit (by
    /// a service that hears first: Selection, looking for a button under a still pointer), what's
    /// asked for is made afresh and not kept, so it's never stale and nothing else is thrown away.
    private var heardRevision: Int

    init(editor: CanvasEditor) {
        self.editor = editor
        let contributions = editor.registry.contributions(to: ShapeAdornments.self)
        isEmpty = contributions.isEmpty
        hasButtons = contributions.contains { $0.value.click != nil }
        heardRevision = editor.revision
    }

    var keptCount: Int { kept.count }

    // MARK: What a shape shows

    /// The adornments a shape shows, in claim order: its kind's candidates whose labels say
    /// something (text that isn't blank, or a symbol). None on a shape kept aside.
    func shown(on record: AnyShapeRecord) -> [ShownAdornment] {
        guard !isEmpty, !record.isOpaque else { return [] }
        let candidates = candidates(for: record.kind)
        guard !candidates.isEmpty else { return [] }
        let isHeard = heardRevision == editor.revision
        if isHeard, let known = kept[record.id] { return known }
        let context = AdornmentContext(editor: editor)
        let made = candidates.compactMap { candidate in
            candidate.label(record, context).flatMap { ShownAdornment(candidate, label: $0) }
        }
        if isHeard { kept[record.id] = made }
        return made
    }

    /// These shapes' labels are made again when they're next asked for.
    func forget(_ ids: Set<ShapeID>) {
        for id in ids { kept[id] = nil }
    }

    private func candidates(for kind: ShapeKind) -> [AdornmentContribution] {
        if let known = candidates[kind] { return known }
        let registry = editor.registry
        guard let definition = registry.definition(for: kind) else { return [] }
        let adornable = AdornableKind(kind: kind, definition: definition, registry: registry)
        // A kind's own come first, so each takes the place of an every-shape one of its type.
        var seen = Set<AdornmentID>()
        let found = registry.contributions(to: ShapeAdornments.self, for: kind)
            .filter { seen.insert($0.adornment).inserted && $0.appliesTo(adornable) }
            .enumerated().sorted { ($0.element.adornment.order, $0.offset) < ($1.element.adornment.order, $1.offset) }
            .map(\.element)
        candidates[kind] = found
        return found
    }

    // MARK: Where

    /// A shape's bounds, as its adornments go by: its geometry's. Nil for a shape without an
    /// outline (nothing drawn), which has none.
    static func bounds(of id: ShapeID, in shapes: ShapeContext) -> CGRect? {
        guard let geometry = shapes.geometry(of: id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { return nil }
        return geometry.bounds
    }

    /// Where a shape's adornments are now, in world units.
    func frames(of record: AnyShapeRecord) -> [AdornmentFrame] {
        let shown = shown(on: record)
        guard !shown.isEmpty, let bounds = Self.bounds(of: record.id, in: editor.shapeContext) else { return [] }
        let scale = AdornmentLayout.scale(atZoom: editor.camera.zoom)
        let slots = AdornmentLayout.slots(of: shown.map(\.item), width: bounds.width / scale)
        return zip(shown, slots).compactMap { adornment, slot in
            slot.map { AdornmentFrame(adornment: adornment.id, label: adornment.label, rect: $0.worldRect(in: bounds, scale: scale)) }
        }
    }

    // MARK: Pointing

    /// The front-most adornment within `hitMargin` of a world point, of the shapes `include`
    /// accepts, where they are (not where a shake draws them): of one shape's, the nearest.
    func hit(at point: CGPoint, where include: (AnyShapeRecord) -> Bool) -> (shape: ShapeID, adornment: ShownAdornment)? {
        guard !isEmpty else { return nil }
        let scale = AdornmentLayout.scale(atZoom: editor.camera.zoom), shapes = editor.shapeContext
        for record in editor.paintOrder(in: AdornmentLayout.area(around: point, scale: scale)).reversed() where include(record) {
            let shown = shown(on: record)
            guard !shown.isEmpty, let bounds = Self.bounds(of: record.id, in: shapes) else { continue }
            var nearest: (index: Int, distance: CGFloat)?
            for (index, slot) in AdornmentLayout.slots(of: shown.map(\.item), width: bounds.width / scale).enumerated() {
                guard let slot else { continue }
                let corner = slot.corner(in: bounds)
                let local = CGPoint(x: (point.x - corner.x) / scale, y: (point.y - corner.y) / scale)
                let distance = AdornmentLayout.distance(from: local, to: slot.frame)
                if distance <= AdornmentLayout.hitMargin, distance < nearest?.distance ?? .infinity { nearest = (index, distance) }
            }
            if let nearest { return (record.id, shown[nearest.index]) }
        }
        return nil
    }

    /// The front-most shape, of those `include` accepts, with an adornment under a world point: the
    /// shape a press, a hover or a right-click there is on (`DecorationHits`).
    func shape(at point: CGPoint, where include: (AnyShapeRecord) -> Bool) -> ShapeID? {
        hit(at: point, where: include)?.shape
    }

    /// The clickable adornment under a view point: what the select tool clicks there
    /// (`CanvasButtons`). Only when the front-most adornment there is one, so a front shape's pill
    /// over a back shape's lock takes the press, as it's drawn over it.
    func button(atViewPoint point: CGPoint) -> AdornmentButton? {
        guard hasButtons, let hit = hit(at: editor.camera.toWorld(point), where: { _ in true }), hit.adornment.isClickable else { return nil }
        return AdornmentButton(hit.adornment.id, on: hit.shape)
    }

    /// A click on a clickable adornment: its type's `click`.
    func click(_ button: AdornmentButton) {
        guard let record = editor.document[button.shape],
              let click = candidates(for: record.kind).first(where: { $0.adornment == button.adornment })?.click else { return }
        click(button.shape, editor)
    }
}

extension AdornmentState: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        heardRevision = editor.revision
        forget(changes.shapeIDs)
    }
}

/// One adornment as a shape shows it: its label, made ready to lay out and draw (its text set in
/// its place's font and measured, or its symbol's image), once per label.
@MainActor
struct ShownAdornment {
    let id: AdornmentID
    let label: AdornmentLabel
    let isClickable: Bool
    let face: AdornmentStyle.Face

    /// Nil for a label that shows nothing: blank text, or neither text nor a symbol.
    init?(_ contribution: AdornmentContribution, label: AdornmentLabel) {
        guard let face = AdornmentStyle.face(of: label, in: contribution.adornment.placement) else { return nil }
        id = contribution.adornment
        self.label = label
        isClickable = contribution.click != nil
        self.face = face
    }

    var item: AdornmentLayout.Item { AdornmentLayout.Item(id.placement, width: face.width, isText: face.isText) }
}
