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
                return ConnectionLook(start: name.hasPrefix("unique") ? .one : .many, end: name.contains("null") ? .zeroOrOne : .one, lineWidth: 2.5)
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
    test("a marked end keeps its stored head unused: no gap, no head, and Return, Space, a double-click and the Shape menu leave it") {
        let b = try LevelBoard(looks: true)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.whole(b.right), startArrowhead: true, endArrowhead: true))
        let geometry = try b.geometry(id)
        expect(!geometry.endArrowhead && !geometry.startArrowhead, "drawn with none")
        expectEqual(try curve(geometry).end, geometry.end, "no head's gap at the end on a shape as a whole")
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
