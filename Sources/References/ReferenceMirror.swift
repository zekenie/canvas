import AppKit
import Canvas
import Geometry
import Mentions
import Palette
import Publishing
import Queries
import Selection

// A mirror: a reference's second look (the owner's design of 2026-11-08, issue 24, look A). The pill stays on top as its
// handle, and under it, in a mat of the original's color, the original is drawn again by its own kind, quieted, live, and
// typed into there. Nothing of the original is stored: the reference keeps its look and its scale, and the core draws and
// edits the original in its place (`ShowingShapes`, `RenderContext.drawShape(inFile:through:standingIn:)`,
// `editor.beginEditing(_:through:)`).

/// How a reference shows what it stands for: the pill, or the pill over a mirror of its original.
public enum ReferenceForm: String, Codable, Sendable, SchemaCases {
    case pill
    case mirror

    public var schemaTitle: String { self == .pill ? "Pill" : "Mirror" }
}

/// What a mirror is laid out by (`MirrorLayout.original`): the size its original is laid out at on its own board, in that
/// board's world units.
public struct MirrorBody: Hashable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    var size: CGSize { CGSize(width: width, height: height) }
}

/// The layout input a mirror reads: its original's laid-out size, provided by References and said again
/// (`editor.shapesDidChangeLayout`) whenever the original's size may have changed with no commit to the mirror.
public enum MirrorLayout {
    public static let original = LayoutInputKey<MirrorBody>("reference-mirror")
}

/// Where a mirror's parts are on its board: the pill (the reference's stored frame, where it always was), the mat that hangs
/// from the pill's middle, and the body in it, the original's laid-out size times the scale. The laid-out frame is the mat
/// with the pill's top half above it.
@MainActor
public struct MirrorPlan {
    public let pill: CGRect
    public let mat: CGRect
    public let body: CGRect
    public let scale: CGFloat

    public init(pill: CGRect, original: CGSize, scale: CGFloat) {
        let inset = ReferenceStyle.mirrorPillInset, pad = ReferenceStyle.mirrorPadding
        let size = CGSize(width: max(original.width, 0) * scale, height: max(original.height, 0) * scale)
        let width = max(size.width + 2 * pad, pill.width + 2 * inset)
        let top = pill.maxY + ReferenceStyle.mirrorGap
        mat = CGRect(x: pill.minX - inset, y: pill.midY, width: width, height: top + size.height + pad - pill.midY)
        body = CGRect(origin: CGPoint(x: mat.minX + pad, y: top), size: size)
        self.pill = pill
        self.scale = scale
    }

    /// The frame it's laid out in: the mat, and the pill over its top edge.
    public var frame: CGRect { CGRect(x: mat.minX, y: pill.minY, width: mat.width, height: mat.maxY - pill.minY) }

    /// The point of the stored box (the pill) that stays where it is as it takes the laid-out size, in unit coordinates of
    /// the box (`LaidOutBox.laidOutAnchor`): its left edge `mirrorPillInset` in from the frame's, its top the frame's. The
    /// frame is wider than the pill by twice the inset at least, so this is between 0 and a half.
    public var anchor: CGPoint { CGPoint(x: (pill.minX - mat.minX) / (mat.width - pill.width), y: 0) }

    /// From the original's world units (its laid-out frame, `original`, on its own board) into the mirror's board's.
    public func transform(from original: CGRect) -> CGAffineTransform {
        CGAffineTransform(translationX: body.minX, y: body.minY).scaledBy(x: scale, y: scale).translatedBy(x: -original.minX, y: -original.minY)
    }

    /// The scale a mirror is first made at: its original's own size, or less, so its body fits `ReferenceStyle.mirrorFirstFit`.
    public static func firstScale(for original: CGSize) -> CGFloat {
        let fit = ReferenceStyle.mirrorFirstFit
        guard original.width > 0, original.height > 0 else { return 1 }
        let scale = min(1, fit.width / original.width, fit.height / original.height)
        return min(max(scale, ReferenceStyle.mirrorScales.lowerBound), ReferenceStyle.mirrorScales.upperBound)
    }
}

/// Where a double-click on a mirror landed: its pill, which re-points it as a pill's does, or its body, which opens what's
/// there (types into it, or opens its board), at the point pressed (the board shown's world units).
struct MirrorFace: Hashable, Sendable {
    enum Part: Hashable, Sendable {
        case pill
        case body(CGPoint)
    }

    let mirror: ShapeID
    let part: Part
}

// MARK: The kind

extension ReferenceDefinition: LaidOutBox {
    /// A mirror is laid out as its plan says: the pill and the mat under it; a pill (and a mirror showing nothing now) is its box.
    func laidOutSize(of shape: ShapeRecord<Reference>, in context: ShapeContext) -> CGSize {
        mirrorPlan(of: shape, in: context)?.frame.size ?? shape.frame.size
    }

    func laidOutAnchor(of shape: ShapeRecord<Reference>, in context: ShapeContext) -> CGPoint {
        mirrorPlan(of: shape, in: context)?.anchor ?? .zero
    }

    /// The plan of a mirror that shows something, from its layout input; nil for a pill and one that shows nothing.
    func mirrorPlan(of shape: ShapeRecord<Reference>, in context: ShapeContext) -> MirrorPlan? {
        guard shape.props.look == .mirror, let original = context.layoutInput(MirrorLayout.original, of: shape) else { return nil }
        return MirrorPlan(pill: shape.frame, original: original.size, scale: shape.props.scale)
    }
}

/// A mirror's handles scale it, in proportion: the scale the frame given leaves the body, along the ways it gives, the pill
/// where the frame's top left puts it. They never resize the original. A pill isn't resized: its width is its text's.
extension ReferenceDefinition: CustomSizing {
    func size(_ shape: inout ShapeRecord<Reference>, to frame: CGRect, giving: SizeAxes, in context: ShapeContext) {
        guard shape.props.look == .mirror, let original = context.layoutInput(MirrorLayout.original, of: shape),
              original.width > 0, original.height > 0 else { return }
        let pad = ReferenceStyle.mirrorPadding
        var scales: [CGFloat] = []
        if giving.contains(.width) { scales.append((frame.width - 2 * pad) / original.width) }
        if giving.contains(.height) {
            scales.append((frame.height - shape.frame.height - ReferenceStyle.mirrorGap - pad) / original.height)
        }
        guard let wanted = scales.max(), wanted.isFinite else { return }
        let range = ReferenceStyle.mirrorScales
        shape.props.scale = min(max(wanted, range.lowerBound), range.upperBound)
        shape.props.frame.origin = CGPoint(x: frame.minX + ReferenceStyle.mirrorPillInset, y: frame.minY)
    }

    func isResizable(_ shape: ShapeRecord<Reference>, in context: ShapeContext) -> Bool { Self.mat(of: shape, in: context) != nil }
}

/// What a mirror shows in its place, and where: the core draws, edits and finds it there.
extension ReferenceDefinition: ShowingShapes {
    func shownShape(of shape: ShapeRecord<Reference>, in context: ShapeContext) -> ShapeID? {
        guard shape.props.look == .mirror else { return nil }
        return context.service(ReferenceState.self)?.mirrorOriginal(of: shape.props, id: shape.id)
    }

    func shownTransform(of shape: ShapeRecord<Reference>, in context: ShapeContext) -> CGAffineTransform? {
        guard shape.props.look == .mirror, let state = context.service(ReferenceState.self),
              let (_, original) = state.mirrored(shape.props, id: shape.id) else { return nil }
        return MirrorPlan(pill: shape.frame, original: original.size, scale: shape.props.scale).transform(from: original)
    }
}

// MARK: Drawing

extension ReferenceDefinition {
    /// A mirror that shows its original: the mat in the original's color (the pill's fill and edge), the original drawn in
    /// it by its own kind, quieted while it isn't typed into, and the pill on top (drawn by the caller). False, drawing
    /// nothing, for one that shows nothing now, and one drawn through another (nothing is drawn through two): it's its pill.
    func drawMirror(_ shape: ShapeRecord<Reference>, colors: PillColors?, state: ReferenceState?, skeleton: Bool,
                    in context: RenderContext) -> Bool {
        guard shape.props.look == .mirror, context.shownThrough == nil, let state,
              let (id, original) = state.mirrored(shape.props, id: shape.id) else { return false }
        let plan = MirrorPlan(pill: shape.frame, original: original.size, scale: shape.props.scale)
        let cg = context.cg, surface = ReferenceStyle.surface
        let parts = colors?.parts(dark: surface.dark)
        let radius = ReferenceStyle.mirrorRadius
        let width = ReferenceStyle.borderWidth
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: plan.mat.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setFillColor(parts?.fill ?? surface.fill)
        if skeleton {
            cg.fillPath()
        } else {
            cg.setStrokeColor(parts?.edge ?? surface.border)
            cg.setLineWidth(width)
            cg.drawPath(using: .fillStroke)
        }
        cg.clip(to: plan.body)
        context.drawShape(inFile: id, through: plan.transform(from: original), standingIn: shape.id)
        if !context.isEditedThrough { Self.quiet(plan.body, in: cg, dark: surface.dark) }
        cg.restoreGState()
        return true
    }

    /// The one filter every kind's body is drawn through: its colors pulled toward gray, to `mirrorSaturation`, by a
    /// saturation blend over what's drawn (the mat under it is opaque, so the blend is exact), then a little toward the
    /// canvas. Two fills, whatever the original drew.
    static func quiet(_ rect: CGRect, in cg: CGContext, dark: Bool) {
        cg.saveGState()
        cg.setBlendMode(.saturation)
        cg.setFillColor(CGColor(gray: 0.5, alpha: 1 - ReferenceStyle.mirrorSaturation))
        cg.fill(rect)
        cg.setBlendMode(.normal)
        let canvas = Swatch.canvas[dark: dark]
        cg.setFillColor(CGColor(srgbRed: canvas.red, green: canvas.green, blue: canvas.blue, alpha: ReferenceStyle.mirrorTowardCanvas))
        cg.fill(rect)
        cg.restoreGState()
    }
}

// MARK: What a mirror shows

extension ReferenceState {
    /// The shape a reference with these props would show as a mirror: what it stands for while that is one shape there,
    /// public and named, with a box, on a board the app can show (a direct one's shape; a first-match query's first match,
    /// as answered); nil for an empty one, words, a query for every match, one that stands for nothing, and one whose
    /// original has no box to draw in a body (an arrow, and a row: a pill for a row, `ReferenceTarget.row`, stands for the row,
    /// not its shape, so it stays a pill, and is never a mirror of the whole shape, nor of one whose row is gone). The answer
    /// is read without observing it: a render and a layout ask it.
    func mirrorOriginal(of props: Reference, id: ShapeID) -> ShapeID? {
        let original: ShapeID
        if let target = props.target {
            guard target.row == nil else { return nil }
            original = target.id
        } else if props.query != nil, !props.all, case .answered(let matches)? = answer(of: id), matches.count > 0, let first = matches.ids.first {
            original = first
        } else {
            return nil
        }
        guard let record = editor.shape(inFile: original), record.box != nil,
              ReferenceCondition.canStand(for: record, registry: editor.registry) else { return nil }
        return original
    }

    /// What a mirror shows and the frame it's laid out in on its own board, nil while it shows nothing.
    func mirrored(_ props: Reference, id: ShapeID) -> (id: ShapeID, frame: CGRect)? {
        guard let original = mirrorOriginal(of: props, id: id), let frame = editor.frame(inFile: original),
              frame.width.isFinite, frame.height.isFinite else { return nil }
        return (original, frame)
    }

    /// What a mirror is laid out by: its original's laid-out size, as the reading sees the file. Mid-transaction, an
    /// original the transaction changed is read at its stored size (it's laid out again once it's committed, when this is
    /// asked again); nil for a pill and a mirror that shows nothing.
    func mirrorBody(of shape: ShapeRecord<Reference>, reading: LayoutReading) -> MirrorBody? {
        guard shape.props.look == .mirror, let original = mirrorOriginal(of: shape.props, id: shape.id) else { return nil }
        if reading.isCommitted { mirrorShows[shape.id] = original }
        if !reading.isCommitted, reading.isChanged(original) {
            return reading.shape(inFile: original)?.box.map { MirrorBody($0.size) }
        }
        return editor.frame(inFile: original).map { MirrorBody($0.size) }
    }

    // MARK: Expand and Collapse

    /// Whether Expand would make a mirror of one of these: a reference shown as a pill that stands for one shape it can draw.
    func canExpand(_ ids: [ShapeID]) -> Bool {
        ids.contains { id in
            guard let props = editor.document[id]?.typed(as: Reference.self)?.props, props.look == .pill else { return false }
            return mirrorOriginal(of: props, id: id) != nil
        }
    }

    /// Whether these are all references, for the menus' items: Expand is offered for references (dimmed where none can be
    /// a mirror), Collapse once one is a mirror.
    func areReferences(_ ids: [ShapeID]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { editor.document[$0]?.kind == Reference.kind }
    }

    func canCollapse(_ ids: [ShapeID]) -> Bool {
        ids.contains { editor.document[$0]?.typed(as: Reference.self)?.props.look == .mirror }
    }

    /// Makes mirrors of the pills among these that can be one, in one step, "Expand Reference": the pill stays where it is
    /// and the body hangs below it, at its original's size, or less so it fits `mirrorFirstFit`. A read-only one is refused
    /// (it shakes) while the rest change.
    func expand(_ ids: [ShapeID]) {
        var scales: [ShapeID: CGFloat] = [:]
        for id in ids {
            guard let props = editor.document[id]?.typed(as: Reference.self)?.props, props.look == .pill,
                  let (_, original) = mirrored(props, id: id) else { continue }
            scales[id] = MirrorPlan.firstScale(for: original.size)
        }
        guard !scales.isEmpty else { return }
        editor.transact(ReferenceStyle.expandStep) { transaction in
            for (id, scale) in scales {
                transaction.update(id, as: Reference.self) {
                    $0.props.look = .mirror
                    $0.props.scale = scale
                }
            }
        }
    }

    /// Makes pills of the mirrors among these, in one step, "Collapse Reference": the body goes, and the pill, its arrows and
    /// where it is stay. It keeps its scale for when it's expanded by a script; Expand starts afresh.
    func collapse(_ ids: [ShapeID]) {
        let mirrors = ids.filter { editor.document[$0]?.typed(as: Reference.self)?.props.look == .mirror }
        guard !mirrors.isEmpty else { return }
        editor.transact(ReferenceStyle.collapseStep) { transaction in
            for id in mirrors { transaction.update(id, as: Reference.self) { $0.props.look = .pill } }
        }
    }

    // MARK: Opening a mirror

    /// What's under a point of a mirror, for a double-click: its pill, or its body (what it shows there). Nil off the
    /// mirror, for a pill, and for a mirror that shows nothing (a double-click edits it as a pill's does).
    func mirrorFace(of record: AnyShapeRecord, at point: CGPoint) -> MirrorFace? {
        guard let shape = record.typed(as: Reference.self), shape.props.look == .mirror,
              mirrorOriginal(of: shape.props, id: shape.id) != nil else { return nil }
        if ReferenceStyle.capsule(shape.frame).contains(point) { return MirrorFace(mirror: shape.id, part: .pill) }
        guard let frame = editor.shapeContext.frame(of: record), frame.contains(point) else { return nil }
        return MirrorFace(mirror: shape.id, part: .body(point))
    }

    /// Opens what a mirror shows where it was pressed (`point`, the board shown's world units; none from Return, for the
    /// original itself): a shape that owns a board shows its board, one step back; one that's edited in place is edited
    /// there through the mirror (its own editor over the body, writing it where it is; a read-only one, or a read-only
    /// mirror, is refused and the mirror shakes); a container is gone into nowhere: a press on what it holds opens that.
    func open(mirror: ShapeID, at point: CGPoint?, clickCount: Int = 1) {
        guard let (root, _) = editor.shown(through: mirror) else { return }
        let hit = point.flatMap { editor.shownShape(at: $0, in: mirror) }
        let id = hit?.id ?? root
        guard let record = editor.shape(inFile: id), !record.isOpaque else { return }
        if editor.registry.boardOwningKinds.contains(record.kind) {
            editor.navigate { _ = editor.showBoard(BoardID(owner: id)) }
        } else if editor.registry.definition(for: record.kind) is any Editable {
            editor.beginEditing(id, through: mirror, at: point, clickCount: clickCount)
        }
    }

    /// Whether `open(mirror:at:)` does something with a mirror: it shows something that opens or is edited (Return's rule).
    func opens(mirror shape: ShapeRecord<Reference>) -> Bool {
        guard shape.props.look == .mirror, let original = mirrorOriginal(of: shape.props, id: shape.id),
              let record = editor.shape(inFile: original) else { return false }
        return editor.registry.boardOwningKinds.contains(record.kind) || editor.registry.definition(for: record.kind) is any Editable
    }

    // MARK: Following the original

    /// The mirrors whose originals are among `ids`, as they last showed them or show them now: those whose layout follows
    /// what changed there.
    func mirrors(showing ids: Set<ShapeID>) -> Set<ShapeID> {
        guard !mirrorIDs.isEmpty, !ids.isEmpty else { return [] }
        var found: Set<ShapeID> = []
        for mirror in mirrorIDs where !ids.contains(mirror) {
            if let shown = mirrorShows[mirror], ids.contains(shown) {
                found.insert(mirror)
            } else if let props = editor.shape(inFile: mirror)?.typed(as: Reference.self)?.props,
                      let now = mirrorOriginal(of: props, id: mirror), ids.contains(now) {
                found.insert(mirror)
            }
        }
        return found
    }

    /// Lays out again the mirrors of the shapes a commit changed other than by moving (an original grown, gone, back, gone
    /// private), and keeps which references are mirrors (`touched`, as `referencesTouched(by:)` says them).
    func hearMirrors(_ changes: ChangeSet, touched: [ShapeID: AnyShapeRecord?]) {
        for (id, record) in touched {
            if record?.typed(as: Reference.self)?.props.look == .mirror { mirrorIDs.insert(id) } else {
                mirrorIDs.remove(id)
                mirrorShows[id] = nil
            }
        }
        guard !mirrorIDs.isEmpty else { return }
        var changed: Set<ShapeID> = []
        for id in changes.added { changed.insert(id) }
        for id in changes.changed where !changes.moved.contains(id) { changed.insert(id) }
        for id in changes.removed { changed.insert(id) }
        for id in changes.elsewhere { changed.insert(id) }
        layOutMirrors(showing: changed)
    }

    /// Lays out again the mirrors that show any of `ids` (announced: the core keeps a mirror's size until told).
    func layOutMirrors(showing ids: Set<ShapeID>) {
        let mirrors = mirrors(showing: ids)
        guard !mirrors.isEmpty else { return }
        for mirror in mirrors { mirrorShows[mirror] = nil }
        editor.shapesDidChangeLayout(mirrors)
    }

    /// The mirrors among `ids` (answers that changed), laid out again: a first match's mirror follows the answer.
    func layOutMirrors(among ids: Set<ShapeID>) {
        let mirrors = ids.intersection(mirrorIDs)
        guard !mirrors.isEmpty else { return }
        for mirror in mirrors { mirrorShows[mirror] = nil }
        editor.shapesDidChangeLayout(mirrors)
    }
}
