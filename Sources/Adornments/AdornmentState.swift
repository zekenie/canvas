import Canvas
import CoreGraphics
import Geometry
import Selection

/// Per editor: which adornments each kind's shapes may show, found once per kind (the registry is
/// frozen), and what each shape shows, its labels made once and kept until a commit names the shape
/// or `adornmentsDidChange` does. How they're laid out is their shape's level's
/// (`editor.drawsSkeleton(of:)`): in full, each label's face made (its text set and measured, its
/// symbol's image) and kept beside it; on a skeleton, zoomed out, blank, each as long as its text's
/// columns (`SkeletonText`), with nothing measured, and the faces kept go but the edited shape's,
/// which is drawn in full. Where they go is worked out when it's asked, from what's kept: it follows
/// the zoom, and geometry that follows other shapes, neither of which reaches a service. Drawing
/// and hit testing go through the same layout at the same level, so what answers the pointer is
/// what's drawn.
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
    /// Each shape's shown adornments (none, for most), laid out blank: its labels, whatever the
    /// level. Dropped for the shapes each commit names and `adornmentsDidChange` names.
    private var kept: [ShapeID: LaidOutAdornments] = [:]
    /// The same shapes' adornments that are laid out in full, their faces made and measured: those
    /// drawn or pointed at in full since the canvas last started drawing skeletons, when they all
    /// went (zoomed out, only the shape being edited, or last edited, has any).
    private var keptInFull: [ShapeID: LaidOutAdornments] = [:]
    /// The revision `kept` is up to date with. Read before this service has heard of a commit (by
    /// a service that hears first: Selection, looking for a button under a still pointer), what's
    /// asked for is made afresh and not kept, so it's never stale and nothing else is thrown away.
    private var heardRevision: Int
    #if DEBUG
    /// How many faces have been made: labels' text set and measured, symbols' images found.
    private(set) var facesMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        let contributions = editor.registry.contributions(to: ShapeAdornments.self)
        isEmpty = contributions.isEmpty
        hasButtons = contributions.contains { $0.value.click != nil }
        heardRevision = editor.revision
    }

    var keptCount: Int { kept.count }
    var keptInFullCount: Int { keptInFull.count }

    // MARK: What a shape shows

    /// The adornments a shape shows, in claim order (its kind's candidates whose labels say
    /// something: text that isn't blank, or a symbol), laid out `blank` (zoomed out) or in full;
    /// nil for none, and on a shape kept aside.
    func laidOut(_ record: AnyShapeRecord, blank: Bool) -> LaidOutAdornments? {
        guard !isEmpty, !record.isOpaque else { return nil }
        let candidates = candidates(for: record.kind)
        guard !candidates.isEmpty else { return nil }
        let isHeard = heardRevision == editor.revision
        if !blank, isHeard, let known = keptInFull[record.id] { return known }
        let labels: LaidOutAdornments
        if isHeard, let known = kept[record.id] {
            labels = known
        } else {
            let context = AdornmentContext(editor: editor)
            let made = candidates.compactMap { candidate in
                candidate.label(record, context).flatMap { ShownAdornment(candidate, label: $0) }
            }
            labels = LaidOutAdornments(shown: made, items: made.map { $0.item(width: $0.blankWidth) }, faces: [])
            if isHeard { kept[record.id] = labels }
        }
        guard !labels.shown.isEmpty else { return nil }
        if blank { return labels }
        let faces = labels.shown.map { AdornmentStyle.face(of: $0.label, in: $0.id.placement) }
        #if DEBUG
        facesMade += faces.count
        #endif
        let full = LaidOutAdornments(shown: labels.shown, items: zip(labels.shown, faces).map { $0.item(width: $1.width) }, faces: faces)
        if isHeard { keptInFull[record.id] = full }
        return full
    }

    /// These shapes' labels are made again when they're next asked for.
    func forget(_ ids: Set<ShapeID>) {
        for id in ids {
            kept[id] = nil
            keptInFull[id] = nil
        }
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

    /// Where a shape's adornments are now, in world units, at its level.
    func frames(of record: AnyShapeRecord) -> [AdornmentFrame] {
        guard let laidOut = laidOut(record, blank: editor.drawsSkeleton(of: record.id)),
              let bounds = Self.bounds(of: record.id, in: editor.shapeContext) else { return [] }
        let scale = AdornmentLayout.scale(atZoom: editor.camera.zoom)
        let slots = AdornmentLayout.slots(of: laidOut.items, width: bounds.width / scale)
        return zip(laidOut.shown, slots).compactMap { adornment, slot in
            slot.map { AdornmentFrame(adornment: adornment.id, label: adornment.label, rect: $0.worldRect(in: bounds, scale: scale)) }
        }
    }

    // MARK: Pointing

    /// The front-most adornment within `hitMargin` of a world point, of the shapes `include`
    /// accepts, where they are (not where a shake draws them), each shape's laid out at its level,
    /// as it's drawn: of one shape's, the nearest.
    func hit(at point: CGPoint, where include: (AnyShapeRecord) -> Bool) -> (shape: ShapeID, adornment: ShownAdornment)? {
        guard !isEmpty else { return nil }
        let scale = AdornmentLayout.scale(atZoom: editor.camera.zoom), shapes = editor.shapeContext
        for record in editor.paintOrder(in: AdornmentLayout.area(around: point, scale: scale)).reversed() where include(record) {
            guard let laidOut = laidOut(record, blank: editor.drawsSkeleton(of: record.id)),
                  let bounds = Self.bounds(of: record.id, in: shapes) else { continue }
            var nearest: (index: Int, distance: CGFloat)?
            for (index, slot) in AdornmentLayout.slots(of: laidOut.items, width: bounds.width / scale).enumerated() {
                guard let slot else { continue }
                let corner = slot.corner(in: bounds)
                let local = CGPoint(x: (point.x - corner.x) / scale, y: (point.y - corner.y) / scale)
                let distance = AdornmentLayout.distance(from: local, to: slot.frame)
                if distance <= AdornmentLayout.hitMargin, distance < nearest?.distance ?? .infinity { nearest = (index, distance) }
            }
            if let nearest { return (record.id, laidOut.shown[nearest.index]) }
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

    /// Another board is shown: what the board left's shapes showed goes, and the shown board's
    /// labels are made as they're asked for, as the first read of a board's makes them. Kept per board
    /// on purpose, it would cost more than it saves: labels are made only for the shapes a frame
    /// draws, so going back makes at most a frame's worth, and what a label reads beyond its shape
    /// (Locking's lock, open and fading) is let go of on a switch without a word to Adornments, so a
    /// label kept would come back stale.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        heardRevision = editor.revision
        kept = [:]
        keptInFull = [:]
    }

    /// The canvas started or stopped drawing skeletons: adornments are laid out the other way, blank
    /// or in full, so each text's is as long as it's drawn now. Zoomed out, the faces kept go (the
    /// labels stay, and are drawn blank; the shape being edited makes its faces again as it's
    /// drawn); zoomed in, the faces of what's in view are made again as it's drawn. What's under a
    /// still pointer, a button come or gone or a pill cut shorter, the select tool looks for again
    /// (Selection hears this too, first), and the layouts it reads answer at the new level whether
    /// this has heard it or not.
    func drawsSkeletonsDidChange(in editor: CanvasEditor) {
        if editor.drawsSkeletons { keptInFull = [:] }
    }
}

/// A shape's adornments, laid out at one level: each label, with how wide it's laid out (its face's
/// width in full, its estimate blank), and, in full, each one's face.
@MainActor
struct LaidOutAdornments {
    let shown: [ShownAdornment]
    let items: [AdornmentLayout.Item]
    /// Empty, laid out blank.
    let faces: [AdornmentStyle.Face]
}

/// One adornment as a shape shows it: its label, which says something (text that isn't blank, or a
/// symbol), how wide it's drawn blank, from its text's length, never measured, and how far its text
/// starts past its padding (a symbol before it).
@MainActor
struct ShownAdornment {
    let id: AdornmentID
    let label: AdornmentLabel
    let isClickable: Bool
    /// Text, which gives way at the row's left end; otherwise a symbol's disc.
    let isText: Bool
    let blankWidth: CGFloat
    let lead: CGFloat

    /// Nil for a label that shows nothing: blank text, or neither text nor a symbol.
    init?(_ contribution: AdornmentContribution, label: AdornmentLabel) {
        if let text = label.text {
            guard !text.isEmpty else { return nil }
        } else if label.systemImage == nil {
            return nil
        }
        id = contribution.adornment
        self.label = label
        isClickable = contribution.click != nil
        isText = label.text != nil
        blankWidth = AdornmentStyle.blankWidth(of: label, in: id.placement)
        lead = AdornmentStyle.lead(of: label, in: id.placement)
    }

    func item(width: CGFloat) -> AdornmentLayout.Item { AdornmentLayout.Item(id.placement, width: width, isText: isText, lead: lead) }

    /// Whether this, on `shape`, is `button` (the one hovered or pressed).
    func isButton(_ button: AdornmentButton?, on shape: ShapeID) -> Bool {
        guard let button else { return false }
        return button.adornment == id && button.shape == shape
    }
}
