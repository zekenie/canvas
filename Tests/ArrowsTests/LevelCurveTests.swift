import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import ContextMenus
import CoreGraphics
import Geometry
import Keyboard
import Mentions
import Selection
import TestKit

// An arrow with an end at a row is a level curve (`ArrowGeometry.Path.level`): a cubic leaving each row's side along the way
// out of it, half the way to the other end ahead, a C behind, entering a shape as a whole perpendicular to the side it meets;
// its bend moves its middle exactly by the bend; it is hit, brushed, labelled and cut along the curve, and zoomed out drawn as
// it. Its look (`ConnectionLooks`, here a fixture's: a key's marks read off the start row's name, 2.5 wide) gives its ends'
// marks, kept with its geometry, drawn, outlined, and worked out again by a change to the row with nothing written to the
// arrow. An arrow with no end at a row is drawn as it always was. Rosters (CanvasTesting) stand in for tables.

/// Two rosters, L (100, 100, 200 by 80) and R (500, 140, 200 by 80), rows 20 tall under a 10-unit head (L's rows' middles at
/// 120, 140, 160; R's at 160, 180, 200), whose rows ends bind; ports, and with `looks`, a fixture's look for an arrow that
/// starts at a roster's row: a crow's foot at its start (two bars for a row named "unique…"), two bars at its end (a bar and
/// a circle when the start row's name holds "null"), 2.5 wide.
@MainActor struct LevelBoard {
    let h: EditorHarness
    let left: ShapeID
    let right: ShapeID
    var leftRows: [RosterRow]
    let rightRows: [RosterRow]
    static let leftFrame = CGRect(x: 100, y: 100, width: 200, height: 80)
    static let rightFrame = CGRect(x: 500, y: 140, width: 200, height: 80)

    init(looks: Bool = false, more: [any CanvasPlugin] = []) throws {
        let rule = Contributor(id: "roster-rows") { registrar in registrar.arrowPartRule { $0.shape.kind == Roster.kind } }
        let look = Contributor(id: "looks") { registrar in
            registrar.connectionLook { query in
                guard let from = query.from, let part = from.part,
                      let roster = query.shapes.shape(from.shape)?.typed(as: Roster.self)?.props else { return nil }
                let name = roster.rows.first { $0.id == part }?.name ?? ""
                let start: EndMark = name.hasPrefix("unique") ? .one : .many, end: EndMark = name.contains("null") ? .zeroOrOne : .one
                // A row named "swap…" puts each end's mark at the other, so each mark is seen at each end.
                return name.hasPrefix("swap") ? ConnectionLook(start: end, end: start, lineWidth: 2.5) : ConnectionLook(start: start, end: end, lineWidth: 2.5)
            }
        }
        h = try EditorHarness(plugins: arrowsPlugins(before: [RostersPlugin()], more: [rule, PortsPlugin()] + (looks ? [look] : []) + more))
        leftRows = ["one", "two", "three"].map { RosterRow(name: $0) }
        rightRows = ["one", "two", "three"].map { RosterRow(name: $0) }
        left = h.add(Roster(Self.leftFrame, rows: leftRows))
        right = h.add(Roster(Self.rightFrame, rows: rightRows))
    }

    /// An end bound to row `index` of `shape`.
    func end(_ shape: ShapeID, _ index: Int) -> ArrowTerminal {
        let rows = shape == left ? leftRows : rightRows
        return .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: rows[index].id))
    }

    /// An end bound to `shape` as a whole, at its middle.
    func whole(_ shape: ShapeID) -> ArrowTerminal {
        .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
    }

    func arrow(_ id: ShapeID) -> Arrow? { h.editor.document[id]?.typed(as: Arrow.self)?.props }
    func geometry(_ id: ShapeID) throws -> ArrowGeometry { try require(h.editor.arrowGeometry(of: id)) }

    /// L's row `index` renamed, in a step of its own (no write to any arrow).
    mutating func rename(_ index: Int, to name: String) {
        leftRows[index].name = name
        let rows = leftRows
        h.editor.transact("Rename") { $0.update(left, as: Roster.self) { $0.props.rows = rows } }
    }
}

/// The level curve an arrow is drawn as; fails the test for one that isn't.
@MainActor private func curve(_ geometry: ArrowGeometry) throws -> Cubic {
    guard case .level(let cubic, _, _) = geometry.path else {
        expect(false, "not a level curve: \(geometry.path)")
        throw RequireFailed()
    }
    return cubic
}

private let size = CGSize(width: 800, height: 320)
private let scale: CGFloat = 2

/// The canvas in either appearance, `scale` pixels to a point.
@MainActor private func drawn(_ editor: CanvasEditor, dark: Bool = false) throws -> NSBitmapImageRep {
    let rep = try require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let cg = try require(NSGraphicsContext(bitmapImageRep: rep)).cgContext
    cg.translateBy(x: 0, y: size.height * scale)
    cg.scaleBy(x: scale, y: -scale)
    try require(NSAppearance(named: dark ? .darkAqua : .aqua)).performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// Whether the line's ink is where a world point is drawn (at `zoom`, the camera at the origin): near-black in the light,
/// near-white in the dark, where the canvas is the other.
@MainActor private func isInked(_ rep: NSBitmapImageRep, _ point: CGPoint, zoom: CGFloat = 1, dark: Bool = false) -> Bool {
    let p = pixel(rep, at: CGPoint(x: point.x * zoom, y: point.y * zoom), scale: scale)
    return dark ? p.prefix(3).allSatisfy { $0 > 160 } : p.prefix(3).allSatisfy { $0 < 100 }
}

@MainActor let levelCurveTests = Suite("Level curves", [
    test("a key between rows of two shapes is an S: each end out along its side's normal half the way, its middle halfway") {
        let b = try LevelBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let geometry = try b.geometry(id)
        expect(geometry.isLevel)
        let cubic = try curve(geometry)
        expectEqual(cubic, Cubic(CGPoint(x: 300, y: 140), CGPoint(x: 400, y: 140), CGPoint(x: 400, y: 200), CGPoint(x: 500, y: 200)))
        expectEqual(geometry.start, CGPoint(x: 300, y: 140), "a row end is on the row's side, no gap")
        expectEqual(geometry.end, CGPoint(x: 500, y: 200))
        expectClose(geometry.middle, CGPoint(x: 400, y: 170), within: 1e-9)
        expectClose(geometry.inward(at: .start), CGPoint(x: 1, y: 0), within: 1e-9)
        expectClose(geometry.inward(at: .end), CGPoint(x: -1, y: 0), within: 1e-9)
        // The kept outline stays three points, for silhouettes.
        expectEqual(b.h.editor.shapeContext.geometry(of: id)?.outline.count, 3)
    },
    test("a far end behind the side makes a C: never less than 24 out, else 6.25 times the root of how far behind") {
        let b = try LevelBoard()
        let tie = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.left, 2)))
        expectEqual(try curve(b.geometry(tie)), Cubic(CGPoint(x: 300, y: 120), CGPoint(x: 324, y: 120), CGPoint(x: 324, y: 160), CGPoint(x: 300, y: 160)))
        // A free end at (250, 300) faces the row's right side (it is right of the row's middle) and is 50 behind it.
        let free = b.h.add(Arrow(start: b.end(b.left, 1), end: .free(CGPoint(x: 250, y: 300))))
        let cubic = try curve(b.geometry(free))
        expectClose(cubic.control1, CGPoint(x: 300 + 6.25 * CGFloat(50).squareRoot(), y: 140), within: 1e-9)
        expectEqual(cubic.control2, CGPoint(x: 250, y: 300), "a free end has no side: the curve comes straight at it")
        // Ahead but near: 24 out at the least.
        let near = b.h.add(Arrow(start: b.end(b.left, 1), end: .free(CGPoint(x: 320, y: 300))))
        expectClose(try curve(b.geometry(near)).control1, CGPoint(x: 324, y: 140), within: 1e-9)
    },
    test("an end at a shape as a whole enters it square to the side it meets, a head's gap off along the curve; its handle stays the anchor") {
        let b = try LevelBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.whole(b.right)))
        let geometry = try b.geometry(id)
        let cubic = try curve(geometry)
        expectEqual(cubic.end, CGPoint(x: 500, y: 180), "the middle of R's left side")
        expectEqual(cubic.control2, CGPoint(x: 400, y: 180))
        expectEqual(geometry.endHandle, LevelBoard.rightFrame.center, "its handle is where it is aimed, as before")
        guard case .level(_, _, let endT) = geometry.path else { return expect(false, "level") }
        expectClose(cubic.measured().length - cubic.measured().length(at: endT), ArrowGeometry.boundGap + 1.75, within: 0.05)
        expectClose(geometry.end.y, 180, within: 0.5)
        // Its head points along the way into the side (its base a head's length back along the curve, which bends a little
        // there): its wings either side of the line in, its tip at the end.
        let head = try require(geometry.arrowheads(strokeWidth: 3.5).first)
        expectEqual(head.tip, geometry.end)
        expectClose(head.wing.x, head.otherWing.x, within: 1)
        expectClose((head.wing.y + head.otherWing.y) / 2, head.tip.y, within: 1)
        expect(head.wing.x < head.tip.x, "the wings behind the tip, going right into R's left side")
        // Above it, the end meets its top.
        b.h.editor.transact { $0.update(b.right, as: Roster.self) { $0.props.frame.origin = CGPoint(x: 150, y: 400) } }
        expectEqual(try curve(b.geometry(id)).end, CGPoint(x: 250, y: 400))
        expectEqual(try curve(b.geometry(id)).control2.x, 250, "straight up out of the top")
    },
    test("the bend moves the middle exactly by itself across the chord; the handle's drag puts the middle under the pointer; Return straightens") {
        let b = try LevelBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let plain = try b.geometry(id)
        expectClose(plain.bendOrigin, plain.middle, within: 1e-9)
        b.h.editor.transact { $0.update(id, as: Arrow.self) { $0.props.bend = 30 } }
        let bent = try b.geometry(id)
        expectClose(bent.middle - plain.middle, plain.bendAxis * 30, within: 1e-9)
        expectClose(bent.bendOrigin, plain.middle, within: 1e-9)
        expectEqual(bent.start, plain.start, "the ends stay on their sides")
        // The handle dragged: the middle follows the pointer across the chord.
        b.h.editor.selection = id
        let target = plain.middle + plain.bendAxis * -40
        b.h.move(to: bent.middle)
        b.h.press()
        b.h.drag(to: target)
        b.h.release()
        expectClose(try require(b.arrow(id)).bend, -40, within: 1e-6)
        expectClose(try b.geometry(id).middle, target, within: 1e-6)
        expectEqual(b.h.editor.undoHistory.undoName, "Bend Arrow")
        // Return on the Bend part: the plain level curve again.
        b.h.key(Chord.optionTab)
        while let part = b.h.editor.focusedPart?.title, part != "Bend" { b.h.key(Chord.optionTab) }
        b.h.key(Chord.return)
        expectEqual(b.h.editor.undoHistory.undoName, "Straighten Arrow")
        expectEqual(try b.geometry(id).middle, plain.middle)
        // ↑ on it bends it by the step's part across the chord, the middle moving by exactly that.
        b.h.key(Chord.up)
        let change = CGPoint(x: 0, y: -1).dot(plain.bendAxis)
        expectClose(try require(b.arrow(id)).bend, change, within: 1e-9)
        expectClose(try b.geometry(id).middle, plain.middle + plain.bendAxis * change, within: 1e-9)
        expectEqual(b.h.editor.undoHistory.undoName, "Bend Arrow")
    },
    test("it is hit and brushed along the curve, not along the chord") {
        let b = try LevelBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 2)))
        let cubic = try curve(b.geometry(id))
        let onCurve = cubic.point(at: 0.25), onChord = cubic.start + (cubic.end - cubic.start) * ((onCurve.x - cubic.start.x) / (cubic.end.x - cubic.start.x))
        expect(onCurve.distance(to: onChord) > 8, "the two are apart")
        expectEqual(b.h.editor.shape(at: onCurve), id)
        expectEqual(b.h.editor.shape(at: onChord), nil)
        expectEqual(brushed(b.h, from: onChord - CGPoint(x: 3, y: 3), to: onChord + CGPoint(x: 3, y: 3)), [])
        expectEqual(brushed(b.h, from: onCurve - CGPoint(x: 3, y: 3), to: onCurve + CGPoint(x: 3, y: 3)), [id])
    },
    test("a level arrow let go of its shapes (a key copied alone, a shape deleted) keeps its middle: an S or a C as an arc through it") {
        let b = try LevelBoard()
        let shape = { (id: ShapeID) in try require(b.h.editor.document[id]) }
        let context = b.h.editor.shapeContext
        let s = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2), bend: 20))
        let c = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.left, 2)))
        for id in [s, c] {
            let before = try b.geometry(id), middle = try require(before.levelBody).measured().point(atFraction: 0.5)
            // Copied alone: both ends let go, where they visibly are.
            let alone = try require(shape(id).remappingReferences({ _ in nil }, in: context)?.typed(as: Arrow.self)?.props)
            expectEqual(alone.start, .free(before.start))
            expectEqual(alone.end, .free(before.end))
            let copy = b.h.add(alone), after = try b.geometry(copy)
            expect(!after.isLevel, "no end at a row")
            // The arc's middle is on the chord's bisector: the nearest it comes to the curve's middle by length is across the
            // chord, within the little the curve's middle is off it.
            expectClose((after.middle - middle).dot(after.bendAxis), 0, within: 1e-6)
            expect(after.middle.distance(to: middle) < 2, "and near it: \(after.middle) for \(middle)")
            // One end let go: the other still at its row, the curve through the same middle.
            let half = try require(shape(id).remappingReferences({ $0 == b.left ? $0 : nil }, in: context)?.typed(as: Arrow.self)?.props)
            if id == s {
                expect(half.start.binding != nil && half.end.binding == nil)
                let kept = try b.geometry(b.h.add(half))
                expect(kept.isLevel, "still level at its row")
                expectClose((kept.middle - middle).dot(kept.bendAxis), 0, within: 1e-6)
            }
        }
    },
    test("its label sits on the curve halfway along it by length, and the curve is cut there") {
        let b = try LevelBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 2), text: "ok"))
        let body = ArrowBody(curve: try curve(b.geometry(id)))
        let label = try require(b.h.editor.arrowLabelFrame(of: id))
        expectClose(label.center, body.point(at: 0.5), within: 0.5)
        let rep = try drawn(b.h.editor)
        expect(isInked(rep, body.point(at: 0.15)), "the curve away from the label")
        // On the curve inside the label's padding, left of its words: nothing of the line, which is cut there.
        let inside = body.point(at: body.fraction(nearest: CGPoint(x: label.minX + 1.5, y: label.midY)))
        expect(label.insetBy(dx: 1, dy: 1).contains(inside), "the curve crosses the label's padding at \(inside): \(label)")
        expect(!isInked(rep, inside), "cut where the label is")
    },
    test("zoomed out, the skeleton is the curve, not the chord nor the arc through its three points") {
        let b = try LevelBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: .free(CGPoint(x: 450, y: 300))))
        let geometry = try b.geometry(id)
        let cubic = try curve(geometry)
        b.h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let rep = try drawn(b.h.editor)
        for t: CGFloat in [0.1, 0.3, 0.7, 0.9] { expect(isInked(rep, cubic.point(at: t), zoom: 0.3), "along the curve at \(t)") }
        let chordQuarter = cubic.start + (cubic.end - cubic.start) * 0.15
        expect(!isInked(rep, chordQuarter, zoom: 0.3), "not the chord")
        let arc = try require(Arc(from: geometry.start, through: geometry.middle, to: geometry.end))
        let off = arc.point(at: 0.15)
        expect(cubic.distance(to: off) > 6, "the arc is elsewhere there")
        expect(!isInked(rep, off, zoom: 0.3), "not the arc")
    },
    test("an arrow with no end at a row is drawn as it always was: straight or arced, nothing kept") {
        let b = try LevelBoard(looks: true)
        let whole = b.h.add(Arrow(start: b.whole(b.left), end: b.whole(b.right)))
        let geometry = try b.geometry(whole)
        if case .straight = geometry.path {} else { expect(false, "straight: \(geometry.path)") }
        expect(geometry.end.x < 500 - ArrowGeometry.boundGap, "clipped at the outline, a head's gap off, as tldraw's: \(geometry.end)")
        expect(b.h.editor.shapeContext.geometry(of: whole)?.detail == nil, "nothing kept")
        expectEqual(b.h.editor.arrowLook(of: whole), nil, "no look: the fixture's is for an arrow from a row")
        let bent = b.h.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 400, y: 300)), bend: 40))
        if case .curved = try b.geometry(bent).path {} else { expect(false, "arced") }
        expect(!(try b.geometry(bent)).isLevel)
    },
])

@MainActor let endMarkTests = Suite("End marks", [
    test("a crow's foot at the start and two bars at the end, at the line's width, in both appearances") {
        for dark in [false, true] {
            let b = try LevelBoard(looks: true)
            let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
            expectEqual(b.h.editor.arrowLook(of: id), ConnectionLook(start: .many, end: .one, lineWidth: 2.5))
            let rep = try drawn(b.h.editor, dark: dark)
            // A toe from (300, 148.5) to (313, 140), and its mirror.
            for toe in [CGPoint(x: 306.5, y: 144.25), CGPoint(x: 306.5, y: 135.75)] { expect(isInked(rep, toe, dark: dark), "a toe at \(toe), dark \(dark)") }
            expect(!isInked(rep, CGPoint(x: 306.5, y: 150), dark: dark), "nothing past the toes, dark \(dark)")
            // Bars 12 and 17.5 in from (500, 200), 9 either side.
            for bar in [CGPoint(x: 488, y: 206), CGPoint(x: 488, y: 194), CGPoint(x: 482.5, y: 206), CGPoint(x: 482.5, y: 194)] {
                expect(isInked(rep, bar, dark: dark), "a bar at \(bar), dark \(dark)")
            }
            expect(!isInked(rep, CGPoint(x: 485.25, y: 206), dark: dark), "between the bars, off the line, dark \(dark)")
            expect(!isInked(rep, CGPoint(x: 494, y: 206), dark: dark), "no head's wings, dark \(dark)")
        }
    },
    test("a bar and a hollow circle, the line cut inside it; two bars at the start for a unique row") {
        for dark in [false, true] {
            var b = try LevelBoard(looks: true)
            let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
            b.rename(1, to: "unique_null")
            expectEqual(b.h.editor.arrowLook(of: id), ConnectionLook(start: .one, end: .zeroOrOne, lineWidth: 2.5))
            let rep = try drawn(b.h.editor, dark: dark)
            expect(isInked(rep, CGPoint(x: 488, y: 206), dark: dark), "the bar, dark \(dark)")
            // The circle on the line 25 in from the end, radius 5: its ring drawn, its middle not (the line is cut inside it).
            let geometry = try b.geometry(id)
            let (centre, inward) = geometry.point(25, along: .end)
            expectClose(centre.distance(to: geometry.end), 25, within: 0.3)
            for way in [inward, inward * -1, inward.perpendicular, inward.perpendicular * -1] {
                expect(isInked(rep, centre + way * 5, dark: dark), "the ring at \(centre + way * 5), dark \(dark)")
            }
            expect(!isInked(rep, centre, dark: dark), "the line cut inside the circle, dark \(dark)")
            expect(!isInked(rep, geometry.point(22, along: .end).point, dark: dark), "on the line inside the circle, dark \(dark)")
            expect(isInked(rep, geometry.point(36, along: .end).point, dark: dark), "the line goes on past it, dark \(dark)")
            // Bars at the start, 12 and 17.5 out from (300, 140).
            for bar in [CGPoint(x: 312, y: 146), CGPoint(x: 317.5, y: 134)] { expect(isInked(rep, bar, dark: dark), "a start bar at \(bar), dark \(dark)") }
        }
    },
    test("each mark at the other end: a bar and a circle at the start, a crow's foot at the end") {
        var b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        b.rename(1, to: "swap_null")
        expectEqual(b.h.editor.arrowLook(of: id), ConnectionLook(start: .zeroOrOne, end: .many, lineWidth: 2.5))
        let geometry = try b.geometry(id), rep = try drawn(b.h.editor)
        let (centre, inward) = geometry.point(25, along: .start)
        expect(isInked(rep, centre + inward.perpendicular * 5) && isInked(rep, centre - inward.perpendicular * 5), "the circle's ring at the start")
        expect(!isInked(rep, centre), "the line cut inside it")
        expect(isInked(rep, geometry.point(12, along: .start).point + CGPoint(x: 0, y: 6)), "the bar at 12")
        // Toes from (500, 200 ± 8.5) to 13 in along the line.
        let meet = geometry.point(13, along: .end).point
        for toe in [CGPoint(x: 500, y: 208.5), CGPoint(x: 500, y: 191.5)] {
            expect(isInked(rep, (toe + meet) / 2), "a toe at the end, toward \(toe)")
        }
    },
    test("a marked end keeps its stored head unused: no gap, no head, and Return, Space, a double-click and the Shape menu leave it") {
        let b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.whole(b.right), startArrowhead: true, endArrowhead: true))
        let geometry = try b.geometry(id)
        expect(!geometry.endArrowhead && !geometry.startArrowhead, "drawn with none")
        expectEqual(geometry.end, CGPoint(x: 500, y: 180), "no head's gap at the end on a shape as a whole")
        expectEqual(try require(geometry.levelBody).end, geometry.end, "the line drawn runs to it")
        b.h.editor.selection = id
        let before = b.h.editor.undoHistory.undoName
        b.h.key(Chord.optionBackTab)
        expectEqual(b.h.editor.focusedPart?.title, "End")
        b.h.key(Chord.return)
        b.h.key(Chord.space)
        expectEqual(b.h.editor.undoHistory.undoName, before, "nothing to toggle")
        expect(try require(b.arrow(id)).endArrowhead, "the stored head kept")
        b.h.editor.selection = nil
        b.h.editor.selection = id
        b.h.click(at: geometry.endHandle, clickCount: 2)
        expect(try require(b.arrow(id)).endArrowhead, "a double-click on the end leaves it")
        expectEqual(b.h.editor.undoHistory.undoName, before)
        b.h.editor.selection = id
        let outline = try require(b.h.editor.menuForSelection(omitting: [])).outline
        expect(!outline.contains("Toggle Start Arrowhead") && !outline.contains("Toggle End Arrowhead"), "\(outline)")
    },
    test("the outline holds the marks, and the skeleton draws each end's once it reaches 3 view points along the line") {
        let b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let record = try require(b.h.editor.document[id])
        let outline = try require(b.h.editor.registry.indicatorPath(of: record, in: b.h.editor.shapeContext)).boundingBoxOfPath
        expect(outline.minY <= 131.5 + 0.01, "the crow's foot's upper toe: \(outline)")
        expect(outline.maxY >= 208.5, "the bar's lower end: \(outline)")
        // At 30% the crow's foot is 3.9 points long: drawn; at 20%, 2.6: the line runs to the end.
        b.h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        let shown = try drawn(b.h.editor)
        expect(isInked(shown, CGPoint(x: 304, y: 145.9), zoom: 0.3), "a toe at 30%")
        b.h.editor.camera = Camera(origin: .zero, zoom: 0.2)
        let hidden = try drawn(b.h.editor)
        expect(!isInked(hidden, CGPoint(x: 304, y: 145.9), zoom: 0.2), "the crow's foot, 2.6 points, not at 20%")
        expect(isInked(hidden, CGPoint(x: 484, y: 205), zoom: 0.2), "the far bars, 3.5 points out, still")
        expect(isInked(hidden, CGPoint(x: 330, y: 140), zoom: 0.2), "the line still")
    },
    test("a key between close rows of one table (a C) runs out past its marks before it turns, and its bend handle is where it is drawn") {
        // The marks reach 13 (a crow's foot), 17.5 (bars) and 30 (the circle) out; the turn is 6 beyond, the controls 4/3 of that.
        for (name, reach) in [("manager", 13.0), ("unique", 17.5), ("null", 30.0)] as [(String, CGFloat)] {
            var b = try LevelBoard(looks: true)
            let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.left, 1)))
            b.rename(0, to: name)
            let geometry = try b.geometry(id), cubic = try curve(geometry)
            let apex = cubic.flattened().map(\.x).max() ?? 0
            expect(apex >= 300 + reach + 6 - 0.01, "\(name): the turn \(apex - 300) out, past the mark's \(reach)")
            // The circle's centre, 25 out, is on the line.
            expect(cubic.distance(to: geometry.point(25, along: .start).point) < 0.2, "\(name): on the line")
            // Dragging the bend handle from where it is drawn puts the middle under the pointer.
            b.h.editor.selection = id
            let target = geometry.middle + geometry.bendAxis * 10
            b.h.move(to: geometry.middle)
            b.h.press()
            b.h.drag(to: target)
            b.h.release()
            expectClose(try b.geometry(id).middle, target, within: 1e-6)
        }
        // With no marks it is the plain C, 24 out.
        let plain = try LevelBoard()
        let id = plain.h.add(Arrow(start: plain.end(plain.left, 0), end: plain.end(plain.left, 1)))
        expectEqual(try curve(plain.geometry(id)).control1.x, 324)
    },
    test("an end with a mark reaches far enough that its mark lies level even with the other end far across, so two keys at one row end lay their bars on each other") {
        // Two keys from S's rows, 330 below L and draw's normal gap (80) past it, end at L's row 1 (both at its right side, (300, 140)).
        let b = try LevelBoard(looks: true)
        let rows = ["a_id", "b_id"].map { RosterRow(name: $0) }
        let far = b.h.add(Roster(CGRect(x: 380, y: 460, width: 200, height: 60), rows: rows))
        let end = { (index: Int) -> ArrowTerminal in
            .bound(ArrowBinding(shapeID: far, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: rows[index].id))
        }
        let keys = [b.h.add(Arrow(start: end(0), end: b.end(b.left, 1))), b.h.add(Arrow(start: end(1), end: b.end(b.left, 1)))]
        var inwards: [CGPoint] = [], bars: [CGPoint] = []
        for key in keys {
            let geometry = try b.geometry(key)
            expectEqual(geometry.end, CGPoint(x: 300, y: 140), "at L's row's right side")
            // Where the bars and their clearance stop, 17.5 + 6 in: still level (rise over run at most 0.2).
            let (_, inward) = geometry.point(23.5, along: .end)
            expect(abs(inward.y) <= 0.2 * abs(inward.x) + 1e-6, "level where the bars stop: \(inward)")
            inwards.append(inward)
            bars.append(geometry.point(17.5, along: .end).point)
        }
        expect(bars[0].distance(to: bars[1]) < 1, "the far bars of both keys on each other: \(bars)")
        expect(abs(inwards[0].y - inwards[1].y) < 0.1, "and square to the same line: \(inwards)")
        // Their crow's feet at S's rows lie level too.
        for key in keys {
            let (_, inward) = try b.geometry(key).point(19, along: .start)
            expect(abs(inward.y) <= 0.2 * abs(inward.x) + 1e-6, "the crow's foot level: \(inward)")
        }
    },
    test("a marked end's reach never takes the line past the sides it runs between: tables 30 apart stay tilted rather than overshot, and a C between two right sides stays small") {
        let b = try LevelBoard(looks: true)
        let rows = ["a_id"].map { RosterRow(name: $0) }
        // Facing sides 30 apart, 330 across: the line keeps between them.
        let near = b.h.add(Roster(CGRect(x: 330, y: 460, width: 200, height: 60), rows: rows))
        let side = { (shape: ShapeID, anchor: CGFloat) -> ArrowTerminal in
            .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: anchor, y: 0.5), isPrecise: true, isExact: true, part: rows[0].id))
        }
        let across = b.h.add(Arrow(start: side(near, 0), end: b.end(b.left, 1)))
        let xs = try curve(b.geometry(across)).flattened().map(\.x)
        expect((xs.min() ?? 0) >= 300 - 1 && (xs.max() ?? 0) <= 330 + 1, "between L's side (300) and the table's (330): \(xs.min() ?? 0) to \(xs.max() ?? 0)")
        // A C: another table whose right side is at L's, 320 below: the loop reaches out less than twice the clearing reach.
        let stacked = b.h.add(Roster(CGRect(x: 100, y: 460, width: 200, height: 60), rows: rows))
        let loop = b.h.add(Arrow(start: side(stacked, 1), end: b.end(b.left, 1)))
        let loopXs = try curve(b.geometry(loop)).flattened().map(\.x)
        let swing = max((loopXs.max() ?? 0) - 300, 100 - (loopXs.min() ?? 0))
        expect(swing <= 64, "the C swings out \(swing) past the tables' side, not wide")
    },
    test("keys between tables 75 apart run one way across, never back behind where they start, each mark on a level stub (UX walk 3 tables-1)") {
        // T's left side 75 right of L's (300), its rows lower: three keys, one with a bar and a circle at L.
        let b = try LevelBoard(looks: true)
        let rows = ["id_one", "null_id", "id_three"].map { RosterRow(name: $0) }
        let far = b.h.add(Roster(CGRect(x: 375, y: 230, width: 200, height: 70), rows: rows))
        let end = { (index: Int) -> ArrowTerminal in
            .bound(ArrowBinding(shapeID: far, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: rows[index].id))
        }
        let keys = [(0, 0), (1, 0), (2, 2)].map { b.h.add(Arrow(start: end($0.0), end: b.end(b.left, $0.1))) }
        for key in keys {
            let geometry = try b.geometry(key), line = try require(geometry.levelBody)
            let xs = line.flattened().map(\.x)
            expect(zip(xs, xs.dropFirst()).allSatisfy { $1 <= $0 + 1e-6 }, "one way across, from 375 to 300: \(xs.max() ?? 0) to \(xs.min() ?? 0)")
            expect((xs.max() ?? 0) <= 375 + 1e-6 && (xs.min() ?? 0) >= 300 - 1e-6, "between the sides")
            // The bars (12, 17.5) and the circle (25) on a level stretch, square to the row.
            for distance: CGFloat in [0, 12, 17.5] {
                expectClose(geometry.point(distance, along: .end).inward.y, 0, within: 1e-6)
                expectClose(geometry.point(distance, along: .start).inward.y, 0, within: 1e-6)
            }
        }
    },
    test("a C between stacked tables lays its bars on a level stub before it turns, never on the turn (UX walk 3 structure-2)") {
        let b = try LevelBoard(looks: true)
        let rows = ["a_id"].map { RosterRow(name: $0) }
        let stacked = b.h.add(Roster(CGRect(x: 100, y: 560, width: 200, height: 60), rows: rows))
        let key = b.h.add(Arrow(start: .bound(ArrowBinding(shapeID: stacked, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: rows[0].id)),
                                end: b.end(b.left, 1)))
        let geometry = try b.geometry(key)
        expectEqual(geometry.partSide(at: .end), .right)
        for distance: CGFloat in [12, 17.5, 23] {
            let (point, inward) = geometry.point(distance, along: .end)
            expectClose(inward, CGPoint(x: 1, y: 0), within: 1e-6)
            expectClose(point.y, 140, within: 1e-6)
        }
        let xs = try require(geometry.levelBody).flattened().map(\.x)
        expect((xs.max() ?? 0) - 300 <= 64, "the C stays small: \((xs.max() ?? 0) - 300) out")
    },
    test("inside a container both ends are in, a marked end's stub and curve stay inside its edge; a side with no room takes the other; the marks are kept (review R24)") {
        let b = try LevelBoard(looks: true, more: [CorralsPlugin()])
        let rows = ["a_id"].map { RosterRow(name: $0) }, upper = ["one"].map { RosterRow(name: $0) }
        @MainActor func key(in corral: CGRect, inset: CGFloat = 40) throws -> (ArrowGeometry, ShapeID) {
            let holder = b.h.add(Corral(corral))
            let top = b.h.add(Roster(CGRect(x: corral.minX + inset, y: corral.minY + 20, width: 120, height: 40), rows: upper))
            let bottom = b.h.add(Roster(CGRect(x: corral.minX + inset, y: corral.minY + 160, width: 120, height: 40), rows: rows))
            b.h.editor.transact { $0.setContainer(top, to: holder); $0.setContainer(bottom, to: holder) }
            func end(_ id: ShapeID, _ part: PartID) -> ArrowTerminal {
                .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: part))
            }
            let id = b.h.add(Arrow(start: end(bottom, rows[0].id), end: end(top, upper[0].id)))
            return (try b.geometry(id), id)
        }
        // Room to the right (240 to the edge): the stub whole, the bars level, the line inside.
        let roomy = CGRect(x: 1000, y: 0, width: 440, height: 240)
        let (wide, wideID) = try key(in: roomy)
        expectEqual(wide.partSide(at: .end), .right)
        expectClose(wide.point(17.5, along: .end).inward, CGPoint(x: 1, y: 0), within: 1e-6)
        let wideRight = try require(wide.levelBody).bounds.maxX
        expect(wideRight <= roomy.maxX - 8 + 0.01, "inside")
        expectEqual(b.h.editor.arrowLook(of: wideID)?.end, .one)
        // 30 to the right and 32 to the left (both under 60): kept on the right, cut to stay inside, the marks still drawn.
        let tight = CGRect(x: 2000, y: 0, width: 198, height: 240)
        let (cut, cutID) = try key(in: tight)
        expectEqual(cut.partSide(at: .end), .right)
        let cutRight = try require(cut.levelBody).bounds.maxX
        expect(cutRight <= tight.maxX - 8 + 0.01, "inside the tight one: \(cutRight)")
        expectClose(cut.point(12, along: .end).inward, CGPoint(x: 1, y: 0), within: 1e-6)
        expectEqual(b.h.editor.arrowLook(of: cutID)?.end, .one)
        // 20 to the right and 140 to the left: both ends take the left.
        let flipped = CGRect(x: 3000, y: 0, width: 296, height: 240)
        let (left, _) = try key(in: flipped, inset: 148)
        expectEqual(left.partSide(at: .start), .left)
        expectEqual(left.partSide(at: .end), .left)
        let leftmost = try require(left.levelBody).bounds.minX
        expect(leftmost >= flipped.minX + 8 - 0.01, "inside on the left: \(leftmost)")
    },
    test("VoiceOver says what the marks say after where the arrow runs: many to one, one to one, many to zero or one") {
        var b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        expectEqual(b.h.editor.accessibleDescription(of: id)?.label, "Arrow, from two in roster to three in roster, many to one")
        b.rename(1, to: "unique")
        expectEqual(b.h.editor.accessibleDescription(of: id)?.label, "Arrow, from unique in roster to three in roster, one to one")
        b.rename(1, to: "null")
        expectEqual(b.h.editor.accessibleDescription(of: id)?.label, "Arrow, from null in roster to three in roster, many to zero or one")
        // An arrow with no look says no more than where it runs.
        let plain = try LevelBoard()
        let bare = plain.h.add(Arrow(start: plain.end(plain.left, 1), end: plain.end(plain.right, 2)))
        expectEqual(plain.h.editor.accessibleDescription(of: bare)?.label, "Arrow, from two in roster to three in roster")
    },
    test("marks aren't hit: a pointer or a brush at a bar's end, off the line, finds nothing") {
        let b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        // The bars of the end at (500, 200) reach 9 either side of the line, 12 and 17.5 in: drawn (above), not hit.
        for bar in [CGPoint(x: 488, y: 209), CGPoint(x: 482.5, y: 191)] {
            expectEqual(b.h.editor.shape(at: bar), nil, "nothing at the bar's end \(bar)")
            expectEqual(brushed(b.h, from: bar - CGPoint(x: 1.5, y: 1.5), to: bar + CGPoint(x: 1.5, y: 1.5)), [], "a brush at \(bar)")
        }
        let line = try b.geometry(id).point(12, along: .end).point
        expectEqual(b.h.editor.shape(at: line), id, "the line itself is hit beside them")
    },
    test("a change to the row its start is at lays the marks out again, with nothing written to the arrow") {
        var b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let arrow = try require(b.arrow(id))
        expectEqual(b.h.editor.arrowLook(of: id)?.end, .one)
        b.rename(1, to: "nullable")
        expectEqual(b.h.editor.arrowLook(of: id)?.end, .zeroOrOne)
        expectEqual(b.arrow(id), arrow, "the arrow is as it was")
        expectEqual(b.h.editor.undoHistory.undoName, "Rename")
        b.h.editor.undo()
        expectEqual(b.h.editor.arrowLook(of: id)?.end, .one, "and back with its undo")
    },
])

@MainActor let lookTests = Suite("An arrow's look", [
    test("a look's width is the line's: the registry says 2.5, and a tinted cover is as wide and a point more") {
        let tint = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let tinted = TintedOutlinesBox()
        let b = try LevelBoard(looks: true, more: [Contributor(id: "lights") { r in r.outlines { _ in Outlines(tinted: tinted.groups) } }])
        // From L's row 1 straight across to a free point: a level line along y = 140.
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: .free(CGPoint(x: 700, y: 140))))
        let record = try require(b.h.editor.document[id])
        expectEqual(b.h.editor.registry.lineWidth(of: record, in: b.h.editor.shapeContext), 2.5)
        tinted.groups = [TintedOutlines(color: tint, shapes: [id])]
        let view = CGSize(width: 320, height: 240)
        for (zoom, wide) in [(0.5, 2.25), (2, 6)] as [(CGFloat, CGFloat)] {
            b.h.editor.camera = Camera(origin: CGPoint(x: 400, y: 100), zoom: zoom)
            let rep = renderBitmap(b.h.editor, size: view)
            let column = 50 * zoom
            let thickness = (0..<Int(view.height)).reduce(CGFloat(0)) { total, y in
                let p = pixel(rep, at: CGPoint(x: column, y: CGFloat(y)))
                return total + CGFloat(max(0, p[0] - p[1])) / 255
            }
            expect(abs(thickness - wide) < 0.1, "\(wide) points across at \(zoom * 100)%: \(thickness)")
        }
        // A plain arrow keeps its own 3.5.
        let plain = b.h.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 300, y: 300))))
        expectEqual(b.h.editor.registry.lineWidth(of: try require(b.h.editor.document[plain]), in: b.h.editor.shapeContext), 3.5)
    },
])
