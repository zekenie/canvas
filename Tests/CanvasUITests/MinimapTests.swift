import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Geometry
import TestKit

/// A 100 × 100 flag off its host's top-right corner, clear of it (off the origin without one): its
/// geometry looks the host up, as an arrow's looks up the shapes it joins.
struct Flag: ShapeProps {
    static let kind: ShapeKind = "flag"
    static let properties = Properties<Flag> {
        Property("host", \.host)
    }
    var host: ShapeID?
}

struct FlagDefinition {}

extension FlagDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Flag>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Flag>, in context: ShapeContext) -> ShapeGeometry {
        let host = shape.props.host.flatMap { context.geometry(of: $0)?.bounds }
        let corner = host.map { CGPoint(x: $0.maxX, y: $0.minY) } ?? .zero
        return ShapeGeometry(outline: CGRect(x: corner.x + 100, y: corner.y - 200, width: 100, height: 100).polygon)
    }
}

/// An open line through its points, as an arrow or a drawn line is.
struct Stroke: ShapeProps {
    static let kind: ShapeKind = "stroke"
    static let properties = Properties<Stroke> {
        Property("points", \.points)
    }
    var points: [CGPoint]
}

extension Stroke {
    init() { self.init(points: []) }
}

struct StrokeDefinition {}

extension StrokeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Stroke>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Stroke>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: shape.props.points, isClosed: false)
    }
}

extension ToolID {
    static let probe: ToolID = "probe"
}

/// What the probe tool heard.
@MainActor final class PointerLog {
    var events: [String] = []
}

final class ProbeTool {
    let log: PointerLog
    init(log: PointerLog) { self.log = log }
}

extension ProbeTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) { log.events.append("down") }
    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) { log.events.append("moved") }
    func pointerExited(in editor: CanvasEditor) { log.events.append("exited") }
}

@MainActor func minimapEditor(document: CanvasDocument = CanvasDocument(), _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try minimapEditor(file: CanvasFile(root: document), more)
}

@MainActor func minimapEditor(file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), Contributor(id: "minimap-kinds") {
        $0.shape(FlagDefinition())
        $0.shape(StrokeDefinition())
    }] + more, file: file)
}

/// A canvas 800 × 600 with its minimap, in an unshown window in the light appearance: the minimap is
/// 200 × 150, at (12, 438).
@MainActor func minimapped(_ h: EditorHarness, size: CGSize = CGSize(width: 800, height: 600)) throws -> (window: NSWindow, canvas: CanvasView, minimap: MinimapView) {
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    let canvas = CanvasView(editor: h.editor)
    window.contentView = canvas
    canvas.showsMinimap = true
    return (window, canvas, try require(canvas.minimap))
}

/// Another minimap of the same board, the same size, over the first: what a new one draws.
@MainActor func freshMinimap(like minimap: MinimapView) -> MinimapView {
    let fresh = MinimapView(editor: minimap.editor)
    fresh.frame = minimap.frame
    minimap.superview?.addSubview(fresh)
    return fresh
}

/// Where a world point shows in the minimap, as tldraw's minimap puts it: the board and the part
/// the canvas shows together, fitted to the minimap less 6 points of padding, centered. Worked out
/// here afresh, as a check on the view's own.
@MainActor func onMinimap(_ world: CGPoint, _ minimap: MinimapView) -> CGPoint {
    let editor = minimap.editor
    let viewport = editor.camera.toWorld(CGRect(origin: .zero, size: editor.viewportSize))
    let area = minimap.bounds.insetBy(dx: 6, dy: 6)
    let content = editor.shapeBounds.union(viewport)
    var width = content.width, height = width * area.height / area.width
    if height < content.height {
        height = content.height
        width = height * area.width / area.height
    }
    let zoom = area.width / width
    return CGPoint(x: area.minX + (world.x - (content.midX - width / 2)) * zoom, y: area.minY + (world.y - (content.midY - height / 2)) * zoom)
}

/// A mouse event at a point in a view (its own coordinates), whatever the views above it.
@MainActor func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1,
                      modifiers: NSEvent.ModifierFlags = [], time: TimeInterval = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: time,
                       windowNumber: view.window!.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}

@MainActor func click(_ minimap: MinimapView, at point: CGPoint, clicks: Int = 1) {
    minimap.mouseDown(with: mouse(.leftMouseDown, at: point, in: minimap, clicks: clicks))
    minimap.mouseUp(with: mouse(.leftMouseUp, at: point, in: minimap, clicks: clicks))
}

func isNear(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }

/// The camera with the canvas's center at `point`, at zoom 1, for an 800 × 600 canvas.
func centered(on point: CGPoint) -> CGPoint { CGPoint(x: point.x - 400, y: point.y - 300) }

/// The view as its window draws it now (a frame of it), at 2× in calibrated RGB, whatever the screen.
@MainActor func drawn(_ view: NSView) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

/// The view once it has drawn all the frames it asked for.
@MainActor func finished(_ view: NSView, _ h: EditorHarness) -> NSBitmapImageRep {
    var rep = drawn(view)
    for _ in 0..<1000 where h.scheduler.pendingCount > 0 {
        h.wait(0)
        rep = drawn(view)
    }
    return rep
}

/// How many of two drawings' pixels differ, every pixel of them.
@MainActor func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh, a.bytesPerRow == b.bytesPerRow, a.bitsPerPixel == 32,
          b.bitsPerPixel == 32, let p = a.bitmapData, let q = b.bitmapData else { return max(a.pixelsWide * a.pixelsHigh, 1) }
    var count = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide where memcmp(p + y * a.bytesPerRow + x * 4, q + y * b.bytesPerRow + x * 4, 4) != 0 {
            count += 1
        }
    }
    return count
}

// In the light appearance: a silhouette is a mid gray (darker under the veil), the minimap's
// background near white (a shade darker under the veil), and what the canvas outlines the accent
// color, pinned to blue (main.swift).
func isSilhouette(_ p: [Int]) -> Bool { p[0] < 140 && abs(p[0] - p[2]) < 24 }
func isBlank(_ p: [Int]) -> Bool { p[0] > 200 && p[1] > 200 && p[2] > 200 }
func isAccent(_ p: [Int]) -> Bool { p[2] > p[0] + 60 }

// The minimap in the canvas's corner: where it sits, what it draws and keeps drawn, and how it moves
// the canvas (after tldraw's).
@MainActor let minimapTests = Suite("Minimap", [
    test("it shows only when asked, in the canvas's bottom-left corner, a quarter of its width, in its proportions") {
        let h = try minimapEditor()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        expect(canvas.minimap == nil && canvas.subviews.isEmpty)
        canvas.showsMinimap = true
        let minimap = try require(canvas.minimap)
        expectEqual(minimap.frame, CGRect(x: 12, y: 438, width: 200, height: 150))
        window.setContentSize(CGSize(width: 480, height: 400))
        expectEqual(minimap.frame, CGRect(x: 12, y: 288, width: 120, height: 100), "no narrower than 120 points")
        window.setContentSize(CGSize(width: 1600, height: 1000))
        expectEqual(minimap.frame, CGRect(x: 12, y: 863, width: 200, height: 125), "no wider than 200 points")
        canvas.showsMinimap = false
        expect(canvas.minimap == nil && minimap.superview == nil)
    },
    test("it draws each shape as a silhouette where it is, the part the canvas shows outlined, the rest under a veil") {
        let h = try minimapEditor()
        let near = h.add(Box(CGRect(x: 100, y: 100, width: 300, height: 200)))
        _ = h.add(Disc(CGRect(x: 1500, y: 1100, width: 400, height: 300)))
        _ = h.add(Stroke(points: [CGPoint(x: 400, y: 900), CGPoint(x: 1400, y: 900)]))
        let (_, _, minimap) = try minimapped(h)
        let rep = finished(minimap, h)
        let at = { (world: CGPoint) in pixel(rep, at: onMinimap(world, minimap)) }
        expect(isSilhouette(at(CGPoint(x: 250, y: 200))), "the box, in view: \(at(CGPoint(x: 250, y: 200)))")
        let clear = at(CGPoint(x: 600, y: 450)), veiled = at(CGPoint(x: 1300, y: 300))
        expect(isBlank(clear) && isBlank(veiled) && veiled[0] < clear[0] - 8, "empty, in view: \(clear); out of view, under the veil: \(veiled)")
        expect(isSilhouette(at(CGPoint(x: 1700, y: 1250))), "the disc, out of view: \(at(CGPoint(x: 1700, y: 1250)))")
        expect(isSilhouette(at(CGPoint(x: 900, y: 900))), "the line: \(at(CGPoint(x: 900, y: 900)))")
        expect(isBlank(at(CGPoint(x: 1510, y: 1110))), "the disc's corner isn't in its silhouette: \(at(CGPoint(x: 1510, y: 1110)))")
        expect(!isBlank(at(CGPoint(x: 800, y: 300))), "the part in view is outlined: \(at(CGPoint(x: 800, y: 300)))")
        h.editor.hintedShapeID = near
        let hinted = pixel(finished(minimap, h), at: onMinimap(CGPoint(x: 250, y: 200), minimap))
        expect(isAccent(hinted), "a shape the canvas outlines is in the accent color: \(hinted)")
    },
    test("its picture keeps up with the board: after each change it's what a new minimap draws") {
        let h = try minimapEditor()
        // The board's corners stay put, so the picture keeps its frame and scale throughout.
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        _ = h.add(Box(CGRect(x: 2950, y: 2250, width: 50, height: 50)))
        let a = h.add(Box(CGRect(x: 400, y: 300, width: 300, height: 200)))
        let b = h.add(Disc(CGRect(x: 600, y: 400, width: 300, height: 300)))
        let flag = h.add(Flag(host: a))
        let line = h.add(Stroke(points: [CGPoint(x: 100, y: 1500), CGPoint(x: 900, y: 1700), CGPoint(x: 1500, y: 1500)]))
        // A board this small draws in a frame, but a busy machine can push a frame past its 4 ms
        // and split the drawing between frames, which moves a diagonal edge's pixels by a shade
        // (the line's): tiles drawn one by one don't antialias quite as a row of them at once. So
        // each picture has as long as it takes, as it has on an idle machine.
        let (_, _, kept) = try minimapped(h)
        kept.frameBudget = .seconds(60)
        _ = finished(kept, h)
        @MainActor func expectFresh(_ step: String) {
            let keptRep = finished(kept, h)
            let fresh = freshMinimap(like: kept)
            fresh.frameBudget = .seconds(60)
            defer { fresh.removeFromSuperview() }
            expectEqual(differingPixels(keptRep, finished(fresh, h)), 0, step)
        }
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 1800, y: 1200) } }
        expectFresh("moved, with the flag off its corner")
        h.editor.transact { $0.update(a, as: Box.self) { $0.frame.size = CGSize(width: 60, height: 900) } }
        expectFresh("resized")
        let c = h.add(Box(CGRect(x: 2000, y: 500, width: 500, height: 100)))
        expectFresh("added")
        h.editor.transact { $0.bringToFront(b) }
        expectFresh("restacked")
        h.editor.transact { $0.update(line, as: Stroke.self) { $0.props.points[1] = CGPoint(x: 900, y: 2200) } }
        expectFresh("a line reshaped")
        h.editor.transact { $0.delete([c, flag]) }
        expectFresh("deleted")
        h.editor.camera = Camera(origin: CGPoint(x: 1200, y: 900), zoom: 0.8)
        expectFresh("the camera moved")
        h.editor.hintedShapeID = b
        expectFresh("a shape outlined")
    },
    test("its picture keeps up with undo and redo: after each it's what a new minimap draws") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        _ = h.add(Box(CGRect(x: 2950, y: 2250, width: 50, height: 50)))
        let a = h.add(Box(CGRect(x: 400, y: 300, width: 300, height: 200)))
        let flag = h.add(Flag(host: a))
        let (_, _, kept) = try minimapped(h)
        _ = finished(kept, h)
        @MainActor func expectFresh(_ step: String) {
            let keptRep = finished(kept, h)
            let fresh = freshMinimap(like: kept)
            defer { fresh.removeFromSuperview() }
            expectEqual(differingPixels(keptRep, finished(fresh, h)), 0, step)
        }
        h.editor.transact("Move") { $0.update(a, as: Box.self) { $0.frame.origin = CGPoint(x: 1800, y: 1200) } }
        expectFresh("moved, with the flag off its corner")
        h.editor.undo()
        expectFresh("the move undone")
        h.editor.redo()
        expectFresh("the move redone")
        h.editor.transact { $0.delete([a, flag]) }
        expectFresh("deleted")
        h.editor.undo()
        expectFresh("the delete undone")
    },
    test("a board too big to draw in one frame is drawn over several, and ends up as one drawn at once") {
        var shapes: [AnyShapeRecord] = []
        for i in 0..<20_000 {
            shapes.append(AnyShapeRecord(ShapeRecord(Box(CGRect(x: (i % 150) * 40, y: (i / 150) * 40, width: 30, height: 30)))))
        }
        let h = try minimapEditor(document: CanvasDocument(shapes: shapes))
        let (_, _, kept) = try minimapped(h)
        _ = drawn(kept)
        expect(h.scheduler.pendingCount > 0, "a frame's worth drawn, it asks for another")
        let overFrames = finished(kept, h)
        let atOnce = freshMinimap(like: kept)
        atOnce.frameBudget = .seconds(60)
        let whole = drawn(atOnce)
        expectEqual(h.scheduler.pendingCount, 0, "drawn at once")
        expectEqual(differingPixels(overFrames, whole), 0)
    },
    test("what went stale first is drawn first, however much goes stale after it") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let gone = h.add(Box(CGRect(x: 2400, y: 1600, width: 400, height: 300)))
        let line = h.add(Stroke(points: [CGPoint(x: 0, y: 1900), CGPoint(x: 2800, y: 0)]))
        let (_, _, minimap) = try minimapped(h)
        _ = finished(minimap, h)
        minimap.frameBudget = .zero                     // a tile a frame
        h.editor.transact { $0.delete([gone]) }
        var rep = drawn(minimap)
        // Then, every frame, the line across the board moves, and every tile goes stale again.
        for frame in 1...20 {
            h.editor.transact { $0.update(line, as: Stroke.self) { $0.props.points[0].y = 1900 - CGFloat(frame % 2) } }
            h.wait(0)
            rep = drawn(minimap)
        }
        expect(h.scheduler.pendingCount > 0, "still catching up with the line")
        expect(isBlank(pixel(rep, at: onMinimap(CGPoint(x: 2600, y: 1750), minimap))), "the box deleted first is gone")
    },
    test("a picture drawn again when the board shrinks shows the old one until it's done, then what a new minimap draws") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Box(CGRect(x: 1600, y: 1200, width: 400, height: 300)))
        let far = h.add(Box(CGRect(x: 10_000, y: 7500, width: 100, height: 100)))
        let (_, _, kept) = try minimapped(h)
        _ = finished(kept, h)
        h.editor.transact { $0.delete([far]) }
        kept.frameBudget = .zero                        // a tile a frame
        let first = drawn(kept)
        expect(h.scheduler.pendingCount > 0)
        let corner = pixel(first, at: onMinimap(CGPoint(x: 1800, y: 1350), kept))
        expect(isSilhouette(corner), "the bottom-right box, from the old picture, before its tile is drawn: \(corner)")
        kept.frameBudget = .milliseconds(4)
        let done = finished(kept, h)
        let fresh = freshMinimap(like: kept)
        expectEqual(differingPixels(done, finished(fresh, h)), 0)
    },
    test("a picture scaled down when the board grows a lot still shows every shape where it is") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Box(CGRect(x: 1600, y: 1200, width: 400, height: 300)))
        let (_, _, minimap) = try minimapped(h)
        _ = finished(minimap, h)
        _ = h.add(Box(CGRect(x: 9000, y: 6000, width: 1000, height: 800)))
        let rep = finished(minimap, h)
        for spot in [CGPoint(x: 200, y: 150), CGPoint(x: 1800, y: 1350), CGPoint(x: 9500, y: 6400)] {
            expect(isSilhouette(pixel(rep, at: onMinimap(spot, minimap))), "a shape at \(spot)")
        }
        expect(isBlank(pixel(rep, at: onMinimap(CGPoint(x: 5000, y: 3500), minimap))), "nothing between")
    },
    test("in the dark appearance it draws the board again, as a new minimap would") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Stroke(points: [CGPoint(x: 400, y: 900), CGPoint(x: 1400, y: 900)]))
        let (window, _, kept) = try minimapped(h)
        let light = finished(kept, h)
        window.appearance = NSAppearance(named: .darkAqua)
        let dark = finished(kept, h)
        expect(differingPixels(light, dark) > 0)
        let fresh = freshMinimap(like: kept)
        expectEqual(differingPixels(dark, finished(fresh, h)), 0)
    },
    test("a click beside the part the canvas shows moves the canvas there, eased over 320 ms") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Box(CGRect(x: 1600, y: 1200, width: 400, height: 300)))
        let (_, _, minimap) = try minimapped(h)
        let target = CGPoint(x: 1500, y: 1000)
        click(minimap, at: onMinimap(target, minimap))
        h.wait(160)
        let halfway = h.editor.camera.origin
        expect(halfway.x > 0 && halfway.x < 1100 && halfway.y > 0 && halfway.y < 700, "on its way: \(halfway)")
        h.wait(160)
        expect(isNear(h.editor.camera.origin, centered(on: target)), "\(h.editor.camera.origin)")
        expectEqual(h.editor.camera.zoom, 1)
    },
    test("a drag from the part the canvas shows moves it as grabbed; from beside it, centers it on the pointer") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Box(CGRect(x: 1600, y: 1200, width: 400, height: 300)))
        let (_, _, minimap) = try minimapped(h)
        // (Half a viewport in from the board's edges, where tldraw's clamp starts to ease.)
        let grabbed = onMinimap(CGPoint(x: 600, y: 400), minimap)
        minimap.mouseDown(with: mouse(.leftMouseDown, at: grabbed, in: minimap))
        minimap.mouseDragged(with: mouse(.leftMouseDragged, at: onMinimap(CGPoint(x: 600.5, y: 400), minimap), in: minimap))
        expectEqual(h.editor.camera.origin, .zero, "a click's jitter moves nothing")
        minimap.mouseDragged(with: mouse(.leftMouseDragged, at: onMinimap(CGPoint(x: 1000, y: 800), minimap), in: minimap))
        expect(isNear(h.editor.camera.origin, CGPoint(x: 400, y: 400)), "moved as grabbed: \(h.editor.camera.origin)")
        minimap.mouseUp(with: mouse(.leftMouseUp, at: onMinimap(CGPoint(x: 1000, y: 800), minimap), in: minimap))

        h.editor.camera = Camera()
        let beside = CGPoint(x: 1500, y: 1000)
        minimap.mouseDown(with: mouse(.leftMouseDown, at: onMinimap(beside, minimap), in: minimap))
        h.wait(100)
        let goal = CGPoint(x: 1200, y: 1100)
        minimap.mouseDragged(with: mouse(.leftMouseDragged, at: onMinimap(goal, minimap), in: minimap))
        expect(isNear(h.editor.camera.origin, centered(on: goal)), "centered on the pointer: \(h.editor.camera.origin)")
        h.wait(400)
        expect(isNear(h.editor.camera.origin, centered(on: goal)), "the easing it started stopped")
        minimap.mouseDragged(with: mouse(.leftMouseDragged, at: onMinimap(CGPoint(x: 1300, y: 1150), minimap), in: minimap, modifiers: .shift))
        expect(isNear(h.editor.camera.origin, centered(on: CGPoint(x: 1300, y: 1000))), "⇧ keeps to the row it was pressed on: \(h.editor.camera.origin)")
    },
    test("a drag never takes the canvas far past the board") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Box(CGRect(x: 1600, y: 1200, width: 400, height: 300)))
        let (_, _, minimap) = try minimapped(h)
        minimap.mouseDown(with: mouse(.leftMouseDown, at: onMinimap(CGPoint(x: 400, y: 300), minimap), in: minimap))
        minimap.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: -500, y: -500), in: minimap))
        // The viewport's center stops half a viewport past the board's top-left corner.
        expect(isNear(h.editor.camera.origin, centered(on: CGPoint(x: -400, y: -300))), "\(h.editor.camera.origin)")
    },
    test("a double-click centers the canvas exactly where it was") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        _ = h.add(Box(CGRect(x: 1600, y: 1200, width: 400, height: 300)))
        let (_, _, minimap) = try minimapped(h)
        let spot = onMinimap(CGPoint(x: 200, y: 150), minimap)
        click(minimap, at: spot)
        h.wait(320)
        expectEqual(h.editor.camera.origin, .zero, "a click in the part the canvas shows moves nothing")
        click(minimap, at: spot, clicks: 2)
        h.wait(320)
        expect(isNear(h.editor.camera.origin, centered(on: CGPoint(x: 200, y: 150))), "\(h.editor.camera.origin)")
    },
    test("on an empty board a click does nothing, and a right-click never does, nor opens a menu") {
        let h = try minimapEditor([Contributor(id: "menus") { $0.menuForSecondaryClick { _, _ in NSMenu(title: "Shape") } }])
        let (_, canvas, minimap) = try minimapped(h)
        click(minimap, at: CGPoint(x: 150, y: 20))
        h.wait(400)
        expectEqual(h.editor.camera.origin, .zero)
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 2000, height: 1500)))
        let right = mouse(.rightMouseDown, at: CGPoint(x: 150, y: 20), in: minimap)
        minimap.rightMouseDown(with: right)
        h.wait(400)
        expectEqual(h.editor.camera.origin, .zero)
        expect(canvas.menu(for: right) == nil, "not the menu of what's under the minimap")
        expect(canvas.menu(for: mouse(.rightMouseDown, at: CGPoint(x: 400, y: 100), in: canvas)) != nil, "elsewhere, the canvas's")
    },
    test("over the minimap the pointer is off the canvas: the tool hears it leave, once, and nothing more until it's back") {
        let log = PointerLog()
        let h = try minimapEditor([Contributor(id: "probe") {
            $0.tool(ToolDescriptor(id: .probe, label: "Probe", systemImage: "circle")) { _ in ProbeTool(log: log) }
            $0.defaultTool(.probe)
        }])
        let (_, canvas, minimap) = try minimapped(h)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 100), in: canvas))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 100, y: 75), in: minimap, time: 1.1))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 105, y: 75), in: minimap, time: 1.2))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 100), in: canvas, time: 1.3))
        expectEqual(log.events, ["moved", "exited", "moved"])
    },
    test("a click on the minimap gives the canvas the keyboard, unless the shape being edited has it") {
        let h = try minimapEditor([CardsPlugin()])
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 700))
        let canvas = CanvasView(editor: h.editor)
        canvas.frame = CGRect(x: 0, y: 100, width: 800, height: 600)
        let field = NSTextField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
        container.addSubview(canvas)
        container.addSubview(field)
        window.contentView = container
        canvas.showsMinimap = true
        let minimap = try require(canvas.minimap)
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 1000, height: 800)))
        window.makeFirstResponder(field)
        click(minimap, at: CGPoint(x: 100, y: 75))
        expect(window.firstResponder === canvas)
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        let editing = try require(window.firstResponder as? NSView)
        expect(editing.isDescendant(of: canvas) && editing !== canvas)
        click(minimap, at: CGPoint(x: 100, y: 75))
        expect(window.firstResponder === editing, "the card keeps it")
        expectEqual(h.editor.editingShapeID, card)
    },
    test("on another board it starts a picture afresh, never from the board left's, and back there it shows the one it kept at once") {
        func box(_ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(Box(CGRect(x: x, y: y, width: 400, height: 300)))) }
        let p = ShapeID()
        // Both boards have shapes in the same corners; only the root has one in the middle.
        let root = CanvasDocument(shapes: [box(0, 0), box(800, 600), box(1600, 1200),
                                           AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 1700, y: 0, width: 300, height: 200))))])
        let h = try minimapEditor(file: CanvasFile(root: root, children: [p: CanvasDocument(shapes: [box(0, 0), box(1600, 1200)])]))
        let (_, _, minimap) = try minimapped(h)
        let onRoot = finished(minimap, h)
        expect(isSilhouette(pixel(onRoot, at: onMinimap(CGPoint(x: 1000, y: 750), minimap))), "the root's middle box")

        minimap.frameBudget = .zero                     // a tile a frame
        expect(h.enter(p))
        let first = drawn(minimap)
        expect(h.scheduler.pendingCount > 0, "drawn over several frames")
        let middle = pixel(first, at: onMinimap(CGPoint(x: 1000, y: 750), minimap))
        expect(isBlank(middle), "nothing of the root's picture shows on P's: \(middle)")
        minimap.frameBudget = .milliseconds(4)
        let done = finished(minimap, h)
        expect(isSilhouette(pixel(done, at: onMinimap(CGPoint(x: 200, y: 150), minimap))))
        let fresh = freshMinimap(like: minimap)
        expectEqual(differingPixels(done, finished(fresh, h)), 0, "P's picture is what a new minimap draws")
        fresh.removeFromSuperview()

        minimap.frameBudget = .zero
        expect(h.editor.showBoard(.root))
        let back = drawn(minimap)
        expectEqual(differingPixels(back, onRoot), 0, "the root's picture, kept, in its first frame back")
        let again = freshMinimap(like: minimap)
        expectEqual(differingPixels(back, finished(again, h)), 0)
        again.removeFromSuperview()

        // A change made there after coming back is drawn into the picture kept, as ever.
        _ = h.add(Box(CGRect(x: 1000, y: 100, width: 300, height: 300)))
        minimap.frameBudget = .milliseconds(4)
        let changed = finished(minimap, h)
        let third = freshMinimap(like: minimap)
        expectEqual(differingPixels(changed, finished(third, h)), 0)
        third.removeFromSuperview()
    },
    test("back on a board whose picture it kept but the editor no longer did, it starts afresh, not from the one kept") {
        func box(_ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(Box(CGRect(x: x, y: y, width: 400, height: 300)))) }
        let p = ShapeID()
        let pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 1700, y: 0, width: 300, height: 200))))
        let corners = [box(0, 0), box(1600, 1200)], inside = CanvasDocument(shapes: [box(0, 0), box(1600, 1200)])
        let h = try minimapEditor(file: CanvasFile(root: CanvasDocument(shapes: [corners[0], box(800, 600), corners[1], pocket]), children: [p: inside]))
        let (_, _, minimap) = try minimapped(h)
        expect(isSilhouette(pixel(finished(minimap, h), at: onMinimap(CGPoint(x: 1000, y: 750), minimap))), "the root's middle box")
        expect(h.enter(p))
        _ = finished(minimap, h)
        // Reverted without the middle box: every board is the file's anew, the root's index isn't kept.
        h.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: corners + [pocket]), children: [p: inside]))
        minimap.frameBudget = .zero                     // a tile a frame
        expect(h.editor.showBoard(.root))
        let first = drawn(minimap)
        let middle = pixel(first, at: onMinimap(CGPoint(x: 1000, y: 750), minimap))
        expect(isBlank(middle), "nothing of the picture kept shows: \(middle)")
        minimap.frameBudget = .milliseconds(4)
        let done = finished(minimap, h)
        let fresh = freshMinimap(like: minimap)
        expectEqual(differingPixels(done, finished(fresh, h)), 0)
        fresh.removeFromSuperview()
    },
    test("a board a deletion took, put back by undo, is drawn afresh, not from the picture it kept of the board") {
        func box(_ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(Box(CGRect(x: x, y: y, width: 400, height: 300)))) }
        let p = ShapeID()
        let pocket = AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 1700, y: 0, width: 300, height: 200))))
        let inside = CanvasDocument(shapes: [box(0, 0), box(800, 600), box(1600, 1200)])
        let h = try minimapEditor(file: CanvasFile(root: CanvasDocument(shapes: [box(0, 0), box(1600, 1200), pocket]), children: [p: inside]))
        let (_, _, minimap) = try minimapped(h)
        _ = finished(minimap, h)
        expect(h.enter(p))
        expect(isSilhouette(pixel(finished(minimap, h), at: onMinimap(CGPoint(x: 1000, y: 750), minimap))), "the pocket's middle box")
        expect(h.editor.showBoard(.root))
        _ = finished(minimap, h)
        h.editor.transact("Delete") { $0.delete([p]) }
        h.editor.undo()
        minimap.frameBudget = .zero                     // a tile a frame
        expect(h.enter(p))
        let first = drawn(minimap)
        let middle = pixel(first, at: onMinimap(CGPoint(x: 1000, y: 750), minimap))
        expect(isBlank(middle), "nothing of the picture kept shows: \(middle)")
        minimap.frameBudget = .milliseconds(4)
        let done = finished(minimap, h)
        let fresh = freshMinimap(like: minimap)
        expectEqual(differingPixels(done, finished(fresh, h)), 0)
        fresh.removeFromSuperview()
    },
    test("it keeps the pictures of the boards above the one shown longest, as the editor keeps their indexes") {
        func box(_ x: CGFloat, _ y: CGFloat) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(Box(CGRect(x: x, y: y, width: 400, height: 300)))) }
        // The root holds pocket P, whose board holds pockets Q0…Q8, each with a box on its board.
        let p = ShapeID(), qs = (0..<9).map { _ in ShapeID() }
        var children = [p: CanvasDocument(shapes: qs.enumerated().map { AnyShapeRecord(ShapeRecord(id: $1, Pocket(CGRect(x: $0 * 200, y: 0, width: 100, height: 100)))) })]
        for q in qs { children[q] = CanvasDocument(shapes: [box(0, 0)]) }
        let root = CanvasDocument(shapes: [box(0, 0), box(800, 600), AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 1700, y: 0, width: 300, height: 200))))])
        let h = try minimapEditor(file: CanvasFile(root: root, children: children))
        let (_, _, minimap) = try minimapped(h)
        let onRoot = finished(minimap, h)
        minimap.frameBudget = .zero
        expect(h.enter(p))
        _ = drawn(minimap)
        for q in qs {
            expect(h.enter(q))
            _ = drawn(minimap)
            expect(h.editor.showBoard(BoardID(owner: p)))
            _ = drawn(minimap)
        }
        expect(h.editor.showBoard(.root))
        expectEqual(differingPixels(drawn(minimap), onRoot), 0, "the root's picture, kept past nine boards below it, in its first frame back")
    },
    test("hidden and shown again, it draws the board as it is now") {
        let h = try minimapEditor()
        _ = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let moving = h.add(Box(CGRect(x: 1000, y: 800, width: 400, height: 300)))
        let (_, canvas, first) = try minimapped(h)
        _ = finished(first, h)
        canvas.showsMinimap = false
        h.editor.transact { $0.update(moving, as: Box.self) { $0.frame.origin = CGPoint(x: 500, y: 800) } }
        canvas.showsMinimap = true
        let minimap = try require(canvas.minimap)
        expect(minimap !== first)
        let rep = finished(minimap, h)
        expect(isSilhouette(pixel(rep, at: onMinimap(CGPoint(x: 700, y: 950), minimap))), "where it is")
        expect(isBlank(pixel(rep, at: onMinimap(CGPoint(x: 1100, y: 1000), minimap))), "not where it was")
    },
])
