import Canvas
import CoreGraphics
import Foundation
import FuzzyMatching
import Geometry

/// Where a shape's hits are drawn, from its bounds' top-left, world units: for each of its texts,
/// each hit's line rects, as its contribution laid them out for the bounds' size (and the zoom, for
/// one that `followsZoom`), and how each text's hits are marked. Kept while the bounds' size stays,
/// and where the geometry puts the shape's label, if it has one, from the bounds' top-left (a
/// label can move within bounds of one size as the shapes an arrow is bound to move, with no commit
/// naming the arrow).
@MainActor
struct LaidOutHits {
    let size: CGSize
    let zoom: CGFloat?
    let label: CGRect?
    let rects: [[[CGRect]]]
    let looks: [FindLook]

    func fits(_ geometry: ShapeGeometry, zoom: CGFloat) -> Bool {
        size == geometry.bounds.size && (self.zoom == nil || self.zoom == zoom) && Self.sameLabel(label, Self.label(of: geometry))
    }

    /// The geometry's label frame from its bounds' top-left, nil for none.
    static func label(of geometry: ShapeGeometry) -> CGRect? {
        geometry.label.map { $0.offsetBy(dx: -geometry.bounds.minX, dy: -geometry.bounds.minY) }
    }

    /// Whether two label frames are the same place, to within what a move's arithmetic loses.
    private static func sameLabel(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case (let a?, let b?):
            abs(a.minX - b.minX) < FindStyle.labelTolerance && abs(a.minY - b.minY) < FindStyle.labelTolerance
                && abs(a.width - b.width) < FindStyle.labelTolerance && abs(a.height - b.height) < FindStyle.labelTolerance
        default: false
        }
    }
}

/// The hits, over the shapes, while Find is open (nothing, and no look at the board, while it's
/// closed). In full, each hit in view where its shape draws it, the current one deeper and lined;
/// a frame lays out at most `FindStyle.layoutBudget` of shapes it hasn't before (each kept while
/// its size, and the query, stay), tinting the rest meanwhile and asking for another frame.
/// Zoomed out, where shapes are skeletons with no text, each shape with hits is tinted (or where
/// its contribution says its text is said: a title's cover), in one fill per look, a shape a pixel
/// across its pixel. A hit under a shape in front shows through it.
struct FindOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        let editor = context.editor
        guard let find = editor.find, find.isActive, find.total > 0 else { return }
        let zoom = context.zoom, cg = context.cg
        let reach = context.worldDrawingReach + (FindStyle.ringGap + FindStyle.ringCurrentWidth + FindStyle.pad) / zoom
        let shapes = editor.paintOrder(in: context.visibleRect.insetBy(dx: -reach, dy: -reach))
        let currentHit = find.currentHit
        let clock = ContinuousClock()
        let deadline = clock.now + FindStyle.layoutBudget
        var laidOutOne = false
        var waiting = false
        var tints = Tints(pixel: 1 / max(abs(cg.userSpaceToDeviceSpaceTransform.a), 0.0001))
        var marks = Marks()
        for record in shapes where find.hasHits(record.id) {
            let id = record.id
            guard let geometry = context.shapes.geometry(of: id), !geometry.bounds.isNull else { continue }
            let bounds = geometry.bounds
            let offset = context.worldDrawingOffset(of: id)
            let isCurrent = currentHit?.shape == id
            guard !context.drawsSkeleton(of: id) else {
                tints.add(Self.zoomedOut(record, find: find, editor: editor, bounds: bounds), offset: offset, isCurrent: isCurrent)
                continue
            }
            var laid = find.laidOut[id]
            if laid?.fits(geometry, zoom: zoom) != true {
                // The first shape a frame lays out always is, so every frame gets further.
                guard !laidOutOne || clock.now < deadline else {
                    waiting = true
                    tints.add([bounds], offset: offset, isCurrent: isCurrent)
                    continue
                }
                laid = Self.layOut(record, find: find, editor: editor, geometry: geometry)
                find.laidOut[id] = laid
                laidOutOne = true
            }
            guard let laid else { continue }
            let origin = CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y)
            for (text, hits) in laid.rects.enumerated() {
                for (index, lines) in hits.enumerated() {
                    let current = isCurrent && currentHit?.hit.text == text && currentHit?.hit.range == find.hits(of: id)[safe: text]?[safe: index]?.range
                    for line in lines { marks.add(line.offsetBy(dx: origin.x, dy: origin.y), look: laid.looks[text], isCurrent: current) }
                }
            }
        }
        tints.draw(in: cg, zoom: zoom)
        marks.draw(in: cg, zoom: zoom)
        if waiting, !find.awaitsFrame {
            find.awaitsFrame = true
            _ = editor.scheduler.schedule(after: .zero) { [weak editor] in
                editor?.find?.awaitsFrame = false
                editor?.setNeedsDisplay()
            }
        }
    }

    /// Where a skeleton's hits are said: where each text with hits is said zoomed out (its
    /// contribution's `zoomedOut`: a title's cover), else the shape's bounds.
    @MainActor
    static func zoomedOut(_ record: AnyShapeRecord, find: FindState, editor: CanvasEditor, bounds: CGRect) -> [CGRect] {
        guard let entry = find.index.entries[record.id] else { return [bounds] }
        let hits = find.hits(of: record.id), context = FindContext(editor: editor)
        var rects: [CGRect] = []
        for (i, text) in entry.texts.enumerated() where !(hits[safe: i]?.isEmpty ?? true) {
            if let said = find.index.contribution(text.source, of: record.kind)?.zoomedOut?(record, text.field, context) {
                rects.append(said)
            } else {
                return [bounds]
            }
        }
        return rects.isEmpty ? [bounds] : rects
    }

    /// Each text's hits laid out by its contribution, from the shape's bounds' top-left.
    @MainActor
    static func layOut(_ record: AnyShapeRecord, find: FindState, editor: CanvasEditor, geometry: ShapeGeometry) -> LaidOutHits? {
        guard let entry = find.index.entries[record.id] else { return nil }
        let hits = find.hits(of: record.id), context = FindContext(editor: editor)
        var rects: [[[CGRect]]] = [], looks: [FindLook] = [], followsZoom = false
        for (i, text) in entry.texts.enumerated() {
            let found = hits[safe: i] ?? []
            let contribution = find.index.contribution(text.source, of: record.kind)
            looks.append(contribution?.look ?? .marker)
            guard !found.isEmpty, let contribution else {
                rects.append(found.map { _ in [] })
                continue
            }
            followsZoom = followsZoom || contribution.followsZoom
            var laid = contribution.rects(record, text.field, found.map(\.range), context)
            if laid.count < found.count { laid += Array(repeating: [], count: found.count - laid.count) }
            rects.append(Array(laid.prefix(found.count)))
        }
        return LaidOutHits(size: geometry.bounds.size, zoom: followsZoom ? editor.camera.zoom : nil, label: LaidOutHits.label(of: geometry),
                           rects: rects, looks: looks)
    }

    /// Where a hit is drawn, world units, where its shape is: its line rects; nil if it isn't
    /// laid out (no bounds, no index entry).
    @MainActor
    static func rects(of hit: FindHit, in record: AnyShapeRecord, state: FindState, editor: CanvasEditor) -> [CGRect]? {
        guard let geometry = editor.shapeContext.geometry(of: record.id), !geometry.bounds.isNull else { return nil }
        let bounds = geometry.bounds
        var laid = state.laidOut[record.id]
        if laid?.fits(geometry, zoom: editor.camera.zoom) != true {
            laid = layOut(record, find: state, editor: editor, geometry: geometry)
            state.laidOut[record.id] = laid
        }
        guard let laid, let index = state.hits(of: record.id)[safe: hit.text]?.firstIndex(where: { $0.range == hit.range }),
              let lines = laid.rects[safe: hit.text]?[safe: index], !lines.isEmpty else { return nil }
        return lines.map { $0.offsetBy(dx: bounds.minX, dy: bounds.minY) }
    }
}

/// Zoomed-out tints (and the shapes a frame had no time to lay out), one light wash over every
/// shape with hits, so what's said on it (a title's cover) still reads; the current one lined round
/// as well, not washed deeper. A shape a device pixel across or less is its pixel, once however many
/// share it (the current one's in the line's color).
@MainActor
private struct Tints {
    let pixel: CGFloat
    private let hits = CGMutablePath()
    private var current: [CGRect] = []
    private var pixels: Set<[Int]> = []
    private var currentPixels: Set<[Int]> = []

    init(pixel: CGFloat) { self.pixel = pixel }

    mutating func add(_ rects: [CGRect], offset: CGPoint, isCurrent: Bool) {
        for rect in rects {
            let shown = rect.offsetBy(dx: offset.x, dy: offset.y)
            if shown.width < pixel * FindStyle.pixelForm && shown.height < pixel * FindStyle.pixelForm {
                let spot = [Int((shown.midX / pixel).rounded(.down)), Int((shown.midY / pixel).rounded(.down))]
                if isCurrent { currentPixels.insert(spot) } else { pixels.insert(spot) }
            } else {
                hits.addRect(shown)
                if isCurrent { current.append(shown) }
            }
        }
    }

    func draw(in cg: CGContext, zoom: CGFloat) {
        for spot in pixels { hits.addRect(CGRect(x: CGFloat(spot[0]) * pixel, y: CGFloat(spot[1]) * pixel, width: pixel, height: pixel)) }
        if !hits.isEmpty {
            cg.addPath(hits)
            cg.setFillColor(FindStyle.zoomedOutHit)
            cg.fillPath()
        }
        if !currentPixels.isEmpty {
            for spot in currentPixels { cg.addRect(CGRect(x: CGFloat(spot[0]) * pixel, y: CGFloat(spot[1]) * pixel, width: pixel, height: pixel)) }
            cg.setFillColor(FindStyle.currentLine)
            cg.fillPath()
        }
        guard !current.isEmpty else { return }
        let width = FindStyle.zoomedOutLineWidth / zoom, out = (FindStyle.zoomedOutLineGap + FindStyle.zoomedOutLineWidth / 2) / zoom
        cg.addRects(current.map { $0.insetBy(dx: -out, dy: -out) })
        cg.setStrokeColor(FindStyle.currentLine)
        cg.setLineWidth(width)
        cg.strokePath()
    }
}

/// Hits in full, a path per look and whether current: marked, washed or ringed.
@MainActor
private struct Marks {
    private var marker: [CGRect] = [], markerCurrent: [CGRect] = []
    private var wash: [CGRect] = [], washCurrent: [CGRect] = []
    private var ring: [CGRect] = [], ringCurrent: [CGRect] = []

    mutating func add(_ rect: CGRect, look: FindLook, isCurrent: Bool) {
        switch (look, isCurrent) {
        case (.marker, false): marker.append(rect)
        case (.marker, true): markerCurrent.append(rect)
        case (.wash, false): wash.append(rect)
        case (.wash, true): washCurrent.append(rect)
        case (.ring, false): ring.append(rect)
        case (.ring, true): ringCurrent.append(rect)
        }
    }

    func draw(in cg: CGContext, zoom: CGFloat) {
        let pad = FindStyle.pad / zoom, corner = FindStyle.corner / zoom
        func rounded(_ rects: [CGRect], grownBy grow: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for rect in rects {
                let shown = rect.insetBy(dx: -grow, dy: 0)
                path.addRoundedRect(in: shown, cornerWidth: min(corner, shown.width / 2), cornerHeight: min(corner, shown.height / 2))
            }
            return path
        }
        // Every hit a plain rect, one path a look (Core Graphics fills rects together for a fraction
        // of each alone, where curves cost more); the current one rounded, on top.
        func fill(_ rects: [CGRect], _ color: CGColor) {
            guard !rects.isEmpty else { return }
            cg.addRects(rects.map { $0.insetBy(dx: -pad, dy: 0) })
            cg.setFillColor(color)
            cg.fillPath()
        }
        func fillRounded(_ rects: [CGRect], _ color: CGColor) {
            guard !rects.isEmpty else { return }
            cg.addPath(rounded(rects, grownBy: pad))
            cg.setFillColor(color)
            cg.fillPath()
        }
        if !marker.isEmpty || !markerCurrent.isEmpty {
            cg.saveGState()
            cg.setBlendMode(.multiply)
            fill(marker, FindStyle.hit)
            fillRounded(markerCurrent, FindStyle.current)
            cg.restoreGState()
        }
        fill(wash, FindStyle.washHit)
        fillRounded(washCurrent, FindStyle.washCurrent)
        // The current hit's line, round its marker or wash.
        let lined = markerCurrent + washCurrent
        if !lined.isEmpty {
            cg.addPath(rounded(lined, grownBy: pad))
            cg.setStrokeColor(FindStyle.currentLine)
            cg.setLineWidth(FindStyle.currentLineWidth / zoom)
            cg.strokePath()
        }
        for (rects, color, width) in [(ring, FindStyle.hit, FindStyle.ringWidth), (ringCurrent, FindStyle.current, FindStyle.ringCurrentWidth)]
        where !rects.isEmpty {
            let path = CGMutablePath()
            for rect in rects {
                let out = (FindStyle.ringGap + width / 2) / zoom
                let shown = rect.insetBy(dx: -out, dy: -out)
                path.addRoundedRect(in: shown, cornerWidth: shown.height / 2, cornerHeight: shown.height / 2)
            }
            cg.addPath(path)
            cg.setStrokeColor(color)
            cg.setLineWidth(width / zoom)
            cg.strokePath()
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
