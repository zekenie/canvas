import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

/// A box that owns a board and draws its preview over all of itself, saying each time whether it
/// could (`drawn`): what the editor's side of previews is tested with.
struct Showcase: BoxShapeProps {
    static let kind: ShapeKind = "showcase"
    static let properties = Properties<Showcase> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
}

extension Showcase {
    init() { self.init(frame: .zero) }
}

@MainActor final class PreviewLog {
    var drawn: [Bool] = []
}

struct ShowcaseDefinition {
    let log: PreviewLog
}

extension ShowcaseDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Showcase>, in context: RenderContext) {
        log.drawn.append(context.drawBoardPreview(ofBoardOwnedBy: shape.id, in: shape.frame))
    }
}

extension ShowcaseDefinition: BoardOwning {}

@MainActor private func previewRegistry(log: PreviewLog = PreviewLog()) throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), Contributor(id: "showcases") { $0.shape(ShowcaseDefinition(log: log)) }])
}

private func box(_ rect: CGRect) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(Box(rect))) }

/// A root holding a pocket for each list of boxes, in order, its board holding them.
private func pocketFile(_ boards: [[CGRect]]) -> (file: CanvasFile, boards: [BoardID]) {
    let pockets = boards.indices.map { i in ShapeRecord(Pocket(CGRect(x: CGFloat(i) * 300, y: 0, width: 240, height: 160))) }
    var children: [ShapeID: CanvasDocument] = [:]
    for (pocket, rects) in zip(pockets, boards) { children[pocket.id] = CanvasDocument(shapes: rects.map(box)) }
    return (CanvasFile(root: CanvasDocument(shapes: pockets.map(AnyShapeRecord.init)), children: children), pockets.map { BoardID(owner: $0.id) })
}

/// `count` showcases, 40 points square, 50 apart in rows of `across` from (5, 5), each owning a
/// board of one box; and an editor of them drawing into a canvas that shows them all.
@MainActor private func showcases(_ count: Int, across: Int = 13, log: PreviewLog) throws -> (h: EditorHarness, owners: [ShapeID], size: CGSize) {
    let owners = (0..<count).map { i in
        ShapeRecord(Showcase(frame: CGRect(x: 5 + CGFloat(i % across) * 50, y: 5 + CGFloat(i / across) * 50, width: 40, height: 40)))
    }
    let file = CanvasFile(root: CanvasDocument(shapes: owners.map(AnyShapeRecord.init)),
                          children: Dictionary(uniqueKeysWithValues: owners.map { ($0.id, CanvasDocument(shapes: [box(CGRect(x: 0, y: 0, width: 10, height: 10))])) }))
    let registry = try previewRegistry(log: log)
    let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
    h.editor.boardPreviews.frameBudget = .seconds(60)
    return (h, owners.map(\.id), CGSize(width: across * 50 + 10, height: (count + across - 1) / across * 50 + 10))
}

/// Far enough off that a build finishes everything waiting.
private var later: ContinuousClock.Instant { .now + .seconds(60) }
/// Already past: a build does its one chunk.
private var past: ContinuousClock.Instant { .now - .seconds(1) }

/// A white sheet in gray, `size` points at `scale` pixels to a point, y down as a render's; what a
/// preview is drawn into to see its pixels.
@MainActor private final class Sheet {
    let cg: CGContext
    let scale: CGFloat

    init(_ size: CGSize = CGSize(width: 400, height: 400), scale: CGFloat = 1) throws {
        cg = try require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        self.scale = scale
        cg.setFillColor(gray: 1, alpha: 1)
        cg.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        cg.translateBy(x: 0, y: CGFloat(cg.height))
        cg.scaleBy(x: scale, y: -scale)
    }

    /// The pixel at a point, 0 painted and 255 clear.
    func value(at point: CGPoint) -> Int {
        let bytes = cg.data!.assumingMemoryBound(to: UInt8.self)
        return Int(bytes[Int(point.y * scale) * cg.bytesPerRow + Int(point.x * scale)])
    }

    /// How many pixels along `points` are neither painted nor clear: the blur across an edge.
    func blurred(_ points: [CGPoint]) -> Int { points.count { (8..<248).contains(value(at: $0)) } }

    /// How many pixels along `points` are more painted than not: a line's width across it.
    func painted(_ points: [CGPoint]) -> Int { points.count { value(at: $0) < 128 } }

    /// Every pixel's middle from `start` to `end`, along a row or a column.
    func pixels(from start: CGPoint, to end: CGPoint) -> [CGPoint] {
        let step = 1 / scale, count = Int((max(end.x - start.x, end.y - start.y) * scale).rounded())
        return (0..<count).map { i in
            start.x == end.x ? CGPoint(x: start.x + step / 2, y: start.y + (CGFloat(i) + 0.5) * step)
                             : CGPoint(x: start.x + (CGFloat(i) + 0.5) * step, y: start.y + step / 2)
        }
    }
}

/// The rect to fit a preview into so it's drawn `scale` points to a world unit of its board, the
/// board's `point` at `at` on the sheet.
private func rect(drawing preview: BoardPreviews.Preview, at scale: CGFloat, putting point: CGPoint, at spot: CGPoint) -> CGRect {
    CGRect(x: spot.x - (point.x - preview.frame.minX) * scale, y: spot.y - (point.y - preview.frame.minY) * scale,
           width: preview.frame.width * scale, height: preview.frame.height * scale)
}

/// Whether the mask is white (a silhouette) at a world point of its board.
@MainActor private func isShape(_ preview: BoardPreviews.Preview, at point: CGPoint) throws -> Bool {
    let mask = try require(preview.mask)
    let data = try require(mask.dataProvider?.data as Data?)
    let scale = CGFloat(mask.width) / preview.frame.width
    let column = Int((point.x - preview.frame.minX) * scale), row = Int((point.y - preview.frame.minY) * scale)
    return data[row * mask.bytesPerRow + column * mask.bitsPerPixel / 8] > 128
}

// What an owner draws of the board it holds (`RenderContext.drawBoardPreview`): the core's previews,
// built a chunk at a time, kept by board and revision.
@MainActor let previewTests = Suite("Previews", [
    test("a board's preview is asked for, then built: its shapes' silhouettes, fitted into 256 pixels, and kept as its revision was") {
        let (file, boards) = pocketFile([[CGRect(x: 0, y: 0, width: 100, height: 100), CGRect(x: 300, y: 0, width: 100, height: 100)]])
        let previews = BoardPreviews(registry: try previewRegistry())
        let key = BoardPreviews.Key(board: boards[0], revision: file.revision(of: boards[0]))
        expect(previews.preview(of: boards[0], in: file) == nil, "none yet")
        expectEqual(previews.waiting, [key])
        expect(previews.build(in: file, until: later), "built")
        expect(!previews.isPending)
        let preview = try require(previews.preview(of: boards[0], in: file))
        expectEqual(preview.key, key)
        let mask = try require(preview.mask)
        expect(mask.width <= 256 && mask.height <= 256 && max(mask.width, mask.height) >= 250, "\(mask.width) × \(mask.height)")
        expect(abs(CGFloat(mask.width) / CGFloat(mask.height) - 4) < 0.3, "the board's proportions: \(mask.width) × \(mask.height)")
        expect(preview.frame.contains(CGRect(x: 0, y: 0, width: 400, height: 100)), "\(preview.frame)")
        expect(try isShape(preview, at: CGPoint(x: 50, y: 50)), "the first box")
        expect(try isShape(preview, at: CGPoint(x: 350, y: 50)), "the second")
        expect(try !isShape(preview, at: CGPoint(x: 200, y: 50)), "nothing between them")
        expectEqual(previews.keptKeys, [key])
        expect(previews.preview(of: boards[0], in: file) != nil, "kept")
        expect(!previews.isPending, "and not asked for again")
    },
    test("drawn no larger than its maximum scale, a board of little is small in the middle of the rect; without one, it fills it") {
        let (file, boards) = pocketFile([[CGRect(x: 0, y: 0, width: 100, height: 100)]])
        let previews = BoardPreviews(registry: try previewRegistry())
        _ = previews.preview(of: boards[0], in: file)
        previews.build(in: file, until: later)
        let preview = try require(previews.preview(of: boards[0], in: file))
        // The preview drawn into a 400-point square: whether each of `points` is painted.
        @MainActor func painted(maxScale: CGFloat, at points: [CGPoint]) throws -> [Bool] {
            let cg = try require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            cg.setFillColor(gray: 1, alpha: 1)
            cg.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            expect(preview.draw(in: cg, fitting: CGRect(x: 0, y: 0, width: 400, height: 400), maxScale: maxScale, color: CGColor(gray: 0, alpha: 1)))
            let image = try require(cg.makeImage()), data = try require(image.dataProvider?.data as Data?)
            return points.map { data[Int($0.y) * image.bytesPerRow + Int($0.x)] < 128 }
        }
        let middle = CGPoint(x: 200, y: 200), near = CGPoint(x: 60, y: 60), far = CGPoint(x: 340, y: 340)
        expectEqual(try painted(maxScale: .infinity, at: [middle, near, far]), [true, true, true], "fitted: the box fills the square")
        // At half, the 100-point box is 50 points across, centered.
        expectEqual(try painted(maxScale: 0.5, at: [middle, CGPoint(x: 180, y: 180), CGPoint(x: 220, y: 220), near, far]),
                    [true, true, true, false, false])
        expectEqual(try painted(maxScale: 10, at: [near, far]), [true, true], "a cap past the fit changes nothing")
    },
    test("a board's preview draws a box laid out larger than it stores at its stored box") {
        let gauge = ShapeRecord(StretchGauge(CGRect(x: 300, y: 0, width: 10, height: 10), width: 400, height: 400))
        let stretch = ShapeRecord(Stretch(CGRect(x: 0, y: 0, width: 100, height: 100), gauge: gauge.id))
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 240, height: 160)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(gauge), AnyShapeRecord(stretch)])])
        let board = BoardID(owner: pocket.id)
        let log = StretchLog()
        let previews = BoardPreviews(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), StretchesPlugin(log: log)]))
        _ = previews.preview(of: board, in: file)
        previews.build(in: file, until: later)
        let preview = try require(previews.preview(of: board, in: file))
        expect(try isShape(preview, at: CGPoint(x: 50, y: 50)), "its stored box")
        expect(try !isShape(preview, at: CGPoint(x: 200, y: 50)), "not the part it would grow into")
        expect(preview.frame.height < 150, "the board is as tall as stored: \(preview.frame)")
        expectEqual(log.sizes.count, 0, "nothing was asked how big it is")
    },
    test("a board's preview draws a box laid out smaller than it stores at its stored box, as it does one laid out larger, and asks nobody") {
        let gauge = ShapeRecord(StretchGauge(CGRect(x: 300, y: 0, width: 10, height: 10), width: 20, height: 20))
        let stretch = ShapeRecord(Stretch(CGRect(x: 0, y: 0, width: 100, height: 100), gauge: gauge.id))
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 240, height: 160)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(gauge), AnyShapeRecord(stretch)])])
        let board = BoardID(owner: pocket.id)
        let log = StretchLog()
        let previews = BoardPreviews(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), StretchesPlugin(log: log, shrinking: true)]))
        _ = previews.preview(of: board, in: file)
        previews.build(in: file, until: later)
        let preview = try require(previews.preview(of: board, in: file))
        expect(try isShape(preview, at: CGPoint(x: 50, y: 50)), "its stored box, past the 20 it is laid out at")
        expectEqual(log.sizes.count, 0, "nothing was asked how big it is")
    },
    test("a container's silhouette is its outline, stroked, so what it holds shows on it") {
        let corral = ShapeRecord(Corral(CGRect(x: 0, y: 0, width: 400, height: 200)))
        let held = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 250, y: 50, width: 100, height: 100)))).copy(as: ShapeID(), container: corral.id)
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 240, height: 160)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(corral), held])])
        let board = BoardID(owner: pocket.id)
        let previews = BoardPreviews(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), CorralsPlugin()]))
        _ = previews.preview(of: board, in: file)
        previews.build(in: file, until: later)
        let preview = try require(previews.preview(of: board, in: file))
        expect(try isShape(preview, at: CGPoint(x: 300, y: 100)), "what it holds")
        expect(try !isShape(preview, at: CGPoint(x: 100, y: 100)), "its inside, clear")
        expect(try isShape(preview, at: CGPoint(x: 1, y: 100)), "its edge")
        expect(try isShape(preview, at: CGPoint(x: 200, y: 199)), "all round")
    },
    test("drawn larger than its mask, the shapes are paths: an edge as sharp at 8× as at 1×, and a line 1.5 device pixels wide") {
        // Two boxes and a link between their middles, along y = 50.
        let first = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 100, height: 100))), second = ShapeRecord(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let link = ShapeRecord(Link(from: first.id, to: second.id))
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 240, height: 160)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(first), AnyShapeRecord(second), AnyShapeRecord(link)])])
        let board = BoardID(owner: pocket.id)
        let previews = BoardPreviews(registry: try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), LinksPlugin()]))
        _ = previews.preview(of: board, in: file)
        previews.build(in: file, until: later)
        let preview = try require(previews.preview(of: board, in: file))
        expect(try require(preview.mask).width <= 256, "a mask of 400 world units: under a pixel each")
        // At 8×, the first box's right edge (100, 40) in the sheet's middle: the edge down x = 200,
        // the link along y = 280 from x = 200 on.
        let fitted = rect(drawing: preview, at: 8, putting: CGPoint(x: 100, y: 40), at: CGPoint(x: 200, y: 200))
        let edge = { (sheet: Sheet) in sheet.blurred(sheet.pixels(from: CGPoint(x: 180, y: 200), to: CGPoint(x: 220, y: 200))) }
        let line = { (sheet: Sheet) in sheet.painted(sheet.pixels(from: CGPoint(x: 300, y: 260), to: CGPoint(x: 300, y: 300))) }
        let paths = try Sheet()
        expect(preview.draw(in: paths.cg, fitting: fitted, color: CGColor(gray: 0, alpha: 1)))
        expect(edge(paths) <= 1, "the edge, a pixel at most between the box and the clear: \(edge(paths))")
        expect((1...2).contains(line(paths)), "the line, 1.5 pixels: \(line(paths))")
        expectEqual(paths.value(at: CGPoint(x: 150, y: 200)), 0, "inside the box, painted")
        expectEqual(paths.value(at: CGPoint(x: 250, y: 200)), 255, "outside, clear")
        // The mask at the same size, for the control: its pixels 12 points across.
        let mask = try Sheet()
        var none = 0
        expect(preview.draw(in: mask.cg, fitting: fitted, color: CGColor(gray: 0, alpha: 1), pathShapes: &none))
        expect(edge(mask) >= 4, "the mask enlarged blurs the edge: \(edge(mask))")
        expect(line(mask) >= 8, "and thickens the line: \(line(mask))")
        // On a 2× screen, the line is 1.5 of its pixels, not of its points.
        let retina = try Sheet(scale: 2)
        expect(preview.draw(in: retina.cg, fitting: fitted, color: CGColor(gray: 0, alpha: 1)))
        expect((1...2).contains(line(retina)), "the line on a 2× screen, 1.5 device pixels: \(line(retina))")
        expect(edge(retina) <= 1, "the edge as sharp: \(edge(retina))")
    },
    test("as paths, only the shapes in view count, and a frame draws so many: past them, the mask; the next frame, paths again") {
        // A hundred boxes, 50 across and 100 apart: a grid of 2 × 2 cells of 25.
        let many = (0..<100).map { i in CGRect(x: CGFloat(i % 10) * 100, y: CGFloat(i / 10) * 100, width: 50, height: 50) }
        let (file, boards) = pocketFile([many])
        let previews = BoardPreviews(registry: try previewRegistry())
        _ = previews.preview(of: boards[0], in: file)
        previews.build(in: file, until: later)
        let preview = try require(previews.preview(of: boards[0], in: file))
        previews.pathShapes = 30
        // The first box's right edge, (50, 25), at 8× in the sheet's middle: only the top-left cell in view.
        let corner = rect(drawing: preview, at: 8, putting: CGPoint(x: 50, y: 25), at: CGPoint(x: 200, y: 200))
        // Its edge across the middle row: sharp drawn as paths, blurred as the mask.
        @MainActor func sharp(_ fitted: CGRect, edgeAt x: CGFloat = 200) throws -> Bool {
            let sheet = try Sheet()
            expect(previews.draw(preview, in: sheet.cg, fitting: fitted, color: CGColor(gray: 0, alpha: 1)))
            return sheet.blurred(sheet.pixels(from: CGPoint(x: x - 20, y: 200), to: CGPoint(x: x + 20, y: 200))) <= 1
        }
        expect(try sharp(corner), "25 shapes in view: paths")
        expect(try !sharp(corner), "again in the same frame, 5 left: the mask")
        previews.endFrame()
        expect(try sharp(corner), "the next frame: paths")
        previews.endFrame()
        // Between the cells, (475, 25) at 4×: the box at 400 to 450 on the left, 500 to 550 on the right.
        let between = rect(drawing: preview, at: 4, putting: CGPoint(x: 475, y: 25), at: CGPoint(x: 200, y: 200))
        expect(try !sharp(between, edgeAt: 100), "two cells in view, 50 shapes: the mask")
        previews.pathShapes = 60
        expect(try sharp(between, edgeAt: 100), "with room for 60: paths")
    },
    test("an empty board has none, and asks for none") {
        let (file, boards) = pocketFile([[]])
        let previews = BoardPreviews(registry: try previewRegistry())
        expect(previews.preview(of: boards[0], in: file) == nil)
        expect(!previews.isPending)
        expect(!previews.build(in: file, until: later))
        expect(previews.keptKeys.isEmpty)
    },
    test("a board changed since its preview was built is never shown as it was: its revision is the key") {
        let (file, boards) = pocketFile([[CGRect(x: 0, y: 0, width: 100, height: 100)]])
        let previews = BoardPreviews(registry: try previewRegistry())
        _ = previews.preview(of: boards[0], in: file)
        previews.build(in: file, until: later)
        let old = try require(previews.preview(of: boards[0], in: file))
        var edited = file
        edited.set(CanvasDocument(shapes: [box(CGRect(x: 500, y: 500, width: 10, height: 10))]), for: boards[0])
        expect(previews.preview(of: boards[0], in: edited) == nil, "not the old one")
        expect(!previews.keptKeys.contains(old.key), "which is dropped")
        expectEqual(previews.waiting, [BoardPreviews.Key(board: boards[0], revision: edited.revision(of: boards[0]))])
        // Asked for, then changed again before it's built: dropped unbuilt.
        var again = edited
        again.set(CanvasDocument(shapes: [box(CGRect(x: 0, y: 0, width: 10, height: 10))]), for: boards[0])
        expect(!previews.build(in: again, until: later), "nothing built for a revision that's gone")
        expect(!previews.isPending)
        expect(previews.preview(of: boards[0], in: again) == nil)
        previews.build(in: again, until: later)
        expectEqual(try require(previews.preview(of: boards[0], in: again)).key.revision, again.revision(of: boards[0]))
        // Emptied, it has none again.
        var emptied = again
        emptied.set(CanvasDocument(), for: boards[0])
        expect(previews.preview(of: boards[0], in: emptied) == nil)
        expect(previews.keptKeys.isEmpty && !previews.isPending)
    },
    test("after an undo the board has a new revision, so the preview built before the edit isn't taken back") {
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 240, height: 160)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [box(CGRect(x: 0, y: 0, width: 100, height: 100))])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], file: file)
        let board = BoardID(owner: pocket.id), previews = h.editor.boardPreviews
        _ = previews.preview(of: board, in: h.editor.file)
        previews.build(in: h.editor.file, until: later)
        let before = try require(previews.preview(of: board, in: h.editor.file))
        expect(h.enter(pocket.id))
        h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.undo()
        expect(h.editor.showBoard(.root))
        expectEqual(h.editor.file[board], file[board], "the board as it was")
        expect(h.editor.file.revision(of: board) != before.key.revision)
        expect(previews.preview(of: board, in: h.editor.file) == nil, "built again, not taken back")
    },
    test("a file put in place keeps the previews of the boards it didn't change, and drops the others'") {
        let square = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let (file, boards) = pocketFile([square, square])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin()], file: file)
        let previews = h.editor.boardPreviews
        for board in boards { _ = previews.preview(of: board, in: h.editor.file) }
        previews.build(in: h.editor.file, until: later)
        var reloaded = file
        reloaded.set(CanvasDocument(shapes: [box(CGRect(x: 0, y: 0, width: 50, height: 50))]), for: boards[1])
        h.editor.replaceFile(with: reloaded)
        expect(previews.preview(of: boards[0], in: h.editor.file) != nil, "the board as it was: its preview kept")
        expect(previews.preview(of: boards[1], in: h.editor.file) == nil, "the board changed: built again")
    },
    test("kept up to their number, the one drawn longest ago going first") {
        let square = [CGRect(x: 0, y: 0, width: 100, height: 100)]
        let (file, boards) = pocketFile([square, square, square])
        let previews = BoardPreviews(registry: try previewRegistry(), capacity: 2)
        let key = { (i: Int) in BoardPreviews.Key(board: boards[i], revision: file.revision(of: boards[i])) }
        for i in 0..<2 {
            _ = previews.preview(of: boards[i], in: file)
            previews.build(in: file, until: later)
        }
        expectEqual(previews.keptKeys, [key(0), key(1)])
        expect(previews.preview(of: boards[0], in: file) != nil, "the first drawn again")
        expectEqual(previews.keptKeys, [key(1), key(0)])
        _ = previews.preview(of: boards[2], in: file)
        previews.build(in: file, until: later)
        expectEqual(previews.keptKeys, [key(0), key(2)], "the second, drawn longest ago, went")
        expect(previews.preview(of: boards[1], in: file) == nil, "and is asked for again")
    },
    test("built a chunk at a time: with no time left, a frame builds one chunk; the one asked for first is built first") {
        let many = (0..<100).map { i in CGRect(x: CGFloat(i % 10) * 20, y: CGFloat(i / 10) * 20, width: 10, height: 10) }
        let (file, boards) = pocketFile([many, many])
        let previews = BoardPreviews(registry: try previewRegistry())
        _ = previews.preview(of: boards[0], in: file)
        _ = previews.preview(of: boards[1], in: file)
        var frames = 0
        while previews.preview(of: boards[0], in: file) == nil, frames < 100 {
            expectEqual(previews.waiting.first?.board, boards[0], "the first asked for, first")
            previews.build(in: file, until: past)
            frames += 1
        }
        // 16 shapes a frame: their geometry in 7 frames, then their silhouettes in 7.
        expectEqual(frames, 14, "frames to build 100 shapes")
        expect(previews.preview(of: boards[1], in: file) == nil, "the second waits its turn")
        expect(try isShape(try require(previews.preview(of: boards[0], in: file)), at: CGPoint(x: 185, y: 185)), "the last box")
        expect(previews.build(in: file, until: later), "with time enough, a frame builds the rest")
        expect(previews.preview(of: boards[1], in: file) != nil)
    },
    test("more owners in view than previews are kept: those drawn stay, the one left over shows none, and no frame is asked for after") {
        let log = PreviewLog()
        let (h, owners, size) = try showcases(65, log: log)
        expectEqual(h.editor.boardPreviews.capacity, 64, "one more owner than are kept")
        var frames: [[Bool]] = []
        for _ in 0..<8 {
            log.drawn = []
            _ = renderBitmap(h.editor, size: size)
            frames.append(log.drawn)
            h.wait(0)
        }
        expect(frames.allSatisfy { $0.count == owners.count }, "every owner drawn in every frame")
        for i in owners.indices {
            let drawn = frames.map { $0[i] }
            expect(!zip(drawn, drawn.dropFirst()).contains { $0 && !$1 }, "owner \(i) went back from its preview to none: \(drawn)")
        }
        let last = try require(frames.last)
        expectEqual(last.filter { $0 }.count, 64, "as many as are kept")
        expect(!h.editor.boardPreviews.isPending, "nothing waits: \(h.editor.boardPreviews.waiting.count)")
        expectEqual(h.scheduler.pendingCount, 0, "no frame asked for")
    },
    test("a preview too small on screen asks for nothing: an owner under 16 points either way, or zoomed out") {
        let log = PreviewLog()
        let owner = ShapeRecord(Showcase(frame: CGRect(x: 20, y: 20, width: 200, height: 12)))
        let big = ShapeRecord(Showcase(frame: CGRect(x: 20, y: 60, width: 100, height: 100)))
        let inside = { CanvasDocument(shapes: [box(CGRect(x: 0, y: 0, width: 10, height: 10))]) }
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(owner), AnyShapeRecord(big)]),
                              children: [owner.id: inside(), big.id: inside()])
        let registry = try previewRegistry(log: log)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
        // Drawn in full at 10%: the render's own ask, too small on screen, is the point (as
        // skeletons, owners wouldn't render at all).
        h.editor.skeletonZoom = 0
        h.editor.camera = Camera(zoom: 0.1)
        _ = renderBitmap(h.editor, size: CGSize(width: 240, height: 180))
        expectEqual(log.drawn, [false, false])
        expect(!h.editor.boardPreviews.isPending, "at 10%, neither is asked for")
        expectEqual(h.scheduler.pendingCount, 0)
        h.editor.camera = Camera()
        _ = renderBitmap(h.editor, size: CGSize(width: 240, height: 180))
        expectEqual(h.editor.boardPreviews.waiting.map(\.board), [BoardID(owner: big.id)], "at 100%, only the big one")
    },
    test("what no frame drew stops waiting: an owner scrolled away, or on a board left, builds nothing and asks for no frames") {
        let log = PreviewLog()
        let (h, owners, size) = try showcases(2, log: log)
        h.editor.boardPreviews.frameBudget = .zero
        _ = renderBitmap(h.editor, size: size)
        expectEqual(h.editor.boardPreviews.waiting.count, 2)
        h.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000))
        _ = renderBitmap(h.editor, size: size)
        expect(!h.editor.boardPreviews.isPending, "scrolled away")
        h.wait(0)
        expectEqual(h.scheduler.pendingCount, 0, "no more frames")
        h.editor.camera = Camera()
        _ = renderBitmap(h.editor, size: size)
        expectEqual(h.editor.boardPreviews.waiting.count, 2, "back in view, asked for again")
        expect(h.editor.showBoard(BoardID(owner: owners[0])))
        expect(!h.editor.boardPreviews.isPending, "on another board, nothing waits")
        h.wait(0)
        _ = renderBitmap(h.editor, size: size)
        expect(!h.editor.boardPreviews.isPending)
        expectEqual(h.scheduler.pendingCount, 0)
    },
    test("the editor builds previews as it draws, asks for frames until they're done, and draws one fitted into the owner's rect") {
        let log = PreviewLog()
        let owner = ShapeRecord(Showcase(frame: CGRect(x: 20, y: 20, width: 200, height: 100)))
        // A board twice as wide as tall, in a rect twice as wide as tall: a square in its top-left quarter.
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(owner)]),
                              children: [owner.id: CanvasDocument(shapes: [box(CGRect(x: 0, y: 0, width: 50, height: 50)),
                                                                           box(CGRect(x: 199, y: 99, width: 1, height: 1))])])
        let registry = try previewRegistry(log: log)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file, scheduler: $0) }
        let size = CGSize(width: 240, height: 140)
        let first = renderBitmap(h.editor, size: size)
        expectEqual(log.drawn, [false], "not built yet")
        expect(h.scheduler.pendingCount > 0, "another frame asked for")
        h.editor.boardPreviews.frameBudget = .seconds(60)
        h.wait(0)
        let second = renderBitmap(h.editor, size: size)
        expectEqual(log.drawn, [false, true])
        expectEqual(h.scheduler.pendingCount, 0, "none asked for once they're done")
        let silhouette = pixel(second, at: CGPoint(x: 40, y: 40))
        expect(silhouette != pixel(first, at: CGPoint(x: 40, y: 40)), "the square drawn: \(silhouette)")
        expect(abs(silhouette[0] - silhouette[2]) < 20 && silhouette[0] < 200, "in one muted gray: \(silhouette)")
        expectEqual(pixel(second, at: CGPoint(x: 160, y: 60)), pixel(first, at: CGPoint(x: 160, y: 60)), "nothing on the right")
        expectEqual(pixel(second, at: CGPoint(x: 40, y: 100)), pixel(first, at: CGPoint(x: 40, y: 100)), "nor below the square: it's the right way up")
        expectEqual(changedPixels(first, second, in: CGRect(x: 0, y: 0, width: 240, height: 18)), 0, "nothing outside the rect")
    },
])
