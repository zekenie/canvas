import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Selection
import TestKit

// A tab on a shape's top edge (`AdornmentPlacement.onTopEdge`): half above the edge and half below,
// 10 in from the corner, as long as its text; turned down the left edge on a tall, narrow shape where that
// shows more; the same size on screen at every zoom, and the one adornment a skeleton shows; tabs on
// different shapes give way, the outermost (then the larger) shape's first, by sliding along their edge.

/// A tab, as a frame's title is.
enum Banner {}
extension Banner: Adornment {
    static var placement: AdornmentPlacement { .onTopEdge }
}

private typealias Request = AdornmentLayout.TabRequest
private typealias Tab = AdornmentLayout.Tab

private func text(_ width: CGFloat) -> Item { Item(.onTopEdge, width: width, isText: true) }
private func request(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ item: Item) -> Request {
    Request(shape: CGRect(x: x, y: y, width: width, height: height), item: item)
}
private func flat(_ x: CGFloat, _ y: CGFloat, _ length: CGFloat) -> Tab {
    Tab(frame: CGRect(x: x, y: y, width: length, height: 18), isTurned: false)
}
private func turned(_ x: CGFloat, _ y: CGFloat, _ length: CGFloat) -> Tab {
    Tab(frame: CGRect(x: x, y: y, width: 18, height: length), isTurned: true)
}

/// The box's tab's frame in view points.
@MainActor private func tabRect(_ h: EditorHarness, _ id: ShapeID) -> CGRect? {
    h.editor.adornmentFrames(of: id).first { $0.adornment == .of(Banner.self) }.map { h.editor.camera.toView($0.rect) }
}

@MainActor let tabLayoutTests = Suite("A tab's layout", [
    test("a tab is on the top edge, 10 in from the corner, half above it, as long as its text") {
        expectEqual(AdornmentLayout.tabs([request(0, 0, 200, 120, text(60))]), [flat(10, -9, 60)])
        expectEqual(AdornmentLayout.tabs([request(50, 40, 200, 120, text(60))]), [flat(60, 31, 60)], "wherever the shape is")
    },
    test("text gives way 4 short of the far end, and needs 30 points, or there's none") {
        expectEqual(AdornmentLayout.tabs([request(0, 0, 200, 120, text(300))]), [flat(10, -9, 186)])
        // Not twice as tall as wide, so never turned.
        expectEqual(AdornmentLayout.tabs([request(0, 0, 44, 80, text(300))]), [flat(10, -9, 30)])
        expectEqual(AdornmentLayout.tabs([request(0, 0, 43, 80, text(300))]), [nil])
        expectEqual(AdornmentLayout.tabs([request(0, 0, 43, 80, Item(.onTopEdge, width: 18, isText: false))]), [flat(10, -9, 18)],
                    "a symbol needs only its width")
    },
    test("a shape too short for the tab's inner half to lie on it has none") {
        expectEqual(AdornmentLayout.tabs([request(0, 0, 200, 11, text(60))]), [nil])
        expectEqual(AdornmentLayout.tabs([request(0, 0, 200, 12, text(60))]), [flat(10, -9, 60)])
    },
    test("on a shape twice as tall as it's wide, the tab turns down its left edge where that shows more of its text") {
        expectEqual(AdornmentLayout.tabs([request(0, 0, 40, 400, text(100))]), [turned(-9, 10, 100)], "no room flat")
        expectEqual(AdornmentLayout.tabs([request(0, 0, 100, 400, text(150))]), [turned(-9, 10, 150)], "cut short flat, whole turned")
        expectEqual(AdornmentLayout.tabs([request(0, 0, 100, 400, text(80))]), [flat(10, -9, 80)], "whole flat: it stays flat")
        expectEqual(AdornmentLayout.tabs([request(0, 0, 100, 199, text(150))]), [flat(10, -9, 86)], "not twice as tall: cut short flat")
        expectEqual(AdornmentLayout.tabs([request(0, 0, 40, 100, text(150))]), [turned(-9, 10, 86)], "cut short turned, where flat shows none")
    },
    test("a tab that meets one placed before it slides along its edge past it, or is left out with no room left") {
        // A shape in another's corner, as a frame in a frame: the outer one's tab is placed first.
        let outer = request(0, 0, 400, 300, text(60))
        expectEqual(AdornmentLayout.tabs([outer, request(0, 0, 200, 100, text(50))]), [flat(10, -9, 60), flat(74, -9, 50)])
        expectEqual(AdornmentLayout.tabs([outer, request(0, 0, 120, 100, text(50))]), [flat(10, -9, 60), flat(74, -9, 42)], "cut short")
        expectEqual(AdornmentLayout.tabs([outer, request(0, 0, 100, 100, text(50))]), [flat(10, -9, 60), nil], "no room")
        expectEqual(AdornmentLayout.tabs([outer, request(80, 0, 200, 100, text(50))]), [flat(10, -9, 60), flat(90, -9, 50)],
                    "clear by 4 points: where it starts")
        expectEqual(AdornmentLayout.tabs([outer, request(70, 30, 200, 100, text(50))]), [flat(10, -9, 60), flat(80, 21, 50)],
                    "on another line: where it starts")
        // Two columns in one: the inner one's turned tab slides down past the outer one's.
        expectEqual(AdornmentLayout.tabs([request(0, 0, 40, 400, text(100)), request(0, 0, 40, 300, text(100))]),
                    [turned(-9, 10, 100), turned(-9, 114, 100)])
    },
    test("however the shapes lie, no two tabs placed come within 4 points, and each lies on its shape's edge") {
        var random = SeededGenerator(seed: 1022)
        var placed = 0
        for _ in 0..<400 {
            let requests = (0..<Int.random(in: 1...8, using: &random)).map { _ in
                request(CGFloat(Int.random(in: 0...300, using: &random)), CGFloat(Int.random(in: 0...300, using: &random)),
                        CGFloat(Int.random(in: 10...400, using: &random)), CGFloat(Int.random(in: 10...400, using: &random)),
                        text(CGFloat(Int.random(in: 20...200, using: &random))))
            }
            let tabs = AdornmentLayout.tabs(requests)
            for (i, tab) in tabs.enumerated() {
                guard let tab else { continue }
                placed += 1
                let shape = requests[i].shape
                if tab.isTurned {
                    expect(tab.frame.midX == shape.minX && tab.frame.minY >= shape.minY + 10 && tab.frame.maxY <= shape.maxY - 4,
                           "\(tab) off \(shape)'s left edge")
                } else {
                    expect(tab.frame.midY == shape.minY && tab.frame.minX >= shape.minX + 10 && tab.frame.maxX <= shape.maxX - 4,
                           "\(tab) off \(shape)'s top edge")
                }
                for other in tabs[(i + 1)...].compactMap({ $0 }) {
                    expect(!other.frame.insetBy(dx: -3.99, dy: -3.99).intersects(tab.frame), "\(tab) and \(other) closer than 4")
                }
            }
        }
        expect(placed > 1000, "most are placed: \(placed)")
    },
    test("a shape's tab reaches 9 above its edge, and the row over it 31: lifted 4 clear of the tab") {
        expectEqual(AdornmentLayout.extent(of: [text(60)], in: 200), 9)
        expectEqual(AdornmentLayout.extent(of: [text(60), Item(.aboveTopRight, width: 18, isText: false)], in: 200), 31)
        expectEqual(AdornmentLayout.extent(of: [text(60)], in: 40), 0, "no room for it: no reach")
        expectEqual(AdornmentLayout.extent(of: [text(60)], in: 200, height: 11), 0, "too short for one: no reach")
        expectEqual(AdornmentLayout.extent(of: [text(100)], in: 40, height: 400), 0, "turned down the left edge: none above")
    },
    test("over a tab the row is 4 above it, and its left end starts where the tab does: a frame's type chips sit over its title") {
        let chip = Item(.aboveTopLeft, width: 40, isText: false), lock = Item(.aboveTopRight, width: 18, isText: false)
        let frames = AdornmentLayout.frames(of: [text(60), chip, lock], width: 200)
        expectEqual(frames[1], CGRect(x: 10, y: -31, width: 40, height: 18), "from the tab's inset, its bottom 4 above the tab's top (9 above the edge)")
        expectEqual(frames[2], CGRect(x: 182, y: -31, width: 18, height: 18), "the whole row lifted, its right end too")
        expectEqual(AdornmentLayout.frames(of: [chip, lock], width: 200), [CGRect(x: 0, y: -27, width: 40, height: 18), CGRect(x: 182, y: -27, width: 18, height: 18)],
                    "with no tab, the row as it was")
        let narrow = AdornmentLayout.frames(of: [text(60), Item(.aboveTopLeft, width: 60, isText: true)], width: 45)
        expectEqual(narrow[1], CGRect(x: 10, y: -31, width: 35, height: 18), "text at the left end gives way in the room after the inset")
    },
    test("a row that gives way to a container's tab starts its left end past it, its right end where it was, its text cut in the room left") {
        let title = Item(.aboveTopLeft, width: 80, isText: true), lock = Item(.aboveTopRight, width: 18, isText: false)
        let frames = AdornmentLayout.frames(of: [title, lock], width: 200, leftStart: 70)
        expectEqual(frames[0], CGRect(x: 70, y: -27, width: 80, height: 18), "from where it may start")
        expectEqual(frames[1], CGRect(x: 182, y: -27, width: 18, height: 18), "the right end where it was")
        expectEqual(AdornmentLayout.frames(of: [title, lock], width: 140, leftStart: 70)[0]?.width, 140 - 18 - 4 - 70, "cut in the room left")
        expectEqual(AdornmentLayout.frames(of: [title], width: 90, leftStart: 70)[0], nil, "no room for any of it: left out")
    },
    test("a point is on a tab as its rounded rect is drawn: its corners are a tab's, not a capsule's") {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 18)
        expect(AdornmentLayout.distance(from: CGPoint(x: 1.5, y: 1.5), to: frame, radius: 5) < 0, "inside a corner a capsule cuts off")
        expect(AdornmentLayout.distance(from: CGPoint(x: 1.5, y: 1.5), to: frame) > 0, "where the capsule's is outside")
        expectEqual(AdornmentLayout.distance(from: CGPoint(x: 50, y: -3), to: frame, radius: 5), 3)
        expectEqual(AdornmentLayout.distance(from: CGPoint(x: 50, y: 4), to: frame, radius: 5), -4)
        expectClose(AdornmentLayout.distance(from: CGPoint(x: -3, y: -4), to: frame, radius: 5), (8 * 8 + 9 * 9 as CGFloat).squareRoot() - 5, within: 1e-9)
    },
])

@MainActor let tabTests = Suite("A tab on a board", [
    test("a tab is drawn on the top edge in its frame, the same size on screen at every zoom, and nowhere else") {
        for zoom in [1, 0.35, 0.3, 0.1, 0.02] as [CGFloat] {
            let (plain, adorned, h) = try renders([everyShape(Banner.self) { _ in AdornmentLabel("Lobby") }], zoom: zoom) {
                $0.add(Box(world(boxFrame, atZoom: zoom)))
            }
            let box = h.editor.document.shapes[0].id
            let frame = try require(tabRect(h, box), "a tab at \(zoom)")
            expect(abs(frame.minX - 110) < 0.01 && abs(frame.minY - 91) < 0.01 && abs(frame.height - 18) < 0.01,
                   "10 in and 9 above the corner, 18 tall, at \(zoom): \(frame)")
            let drawn = changedPixels(plain, adorned, in: frame.insetBy(dx: -1, dy: -1).integral)
            expect(drawn > 100, "drawn at \(zoom): \(drawn)")
            expectEqual(changedPixels(plain, adorned, in: wholeView) - drawn, 0, "nowhere else at \(zoom)")
        }
    },
    test("zoomed out, a shape shows its tab and nothing else; at 35%, everything") {
        let h = try adornedHarness([everyShape(Banner.self) { _ in AdornmentLabel("Lobby") }, everyShape(Caption.self, id: "captions") { _ in AdornmentLabel("Hall") },
                                    everyShape(Pin.self, id: "pins") { _ in pinLabel }])
        var shown: [[AdornmentID]] = []
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        for zoom in [0.3, 0.35, 0.1] as [CGFloat] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            shown.append(h.editor.adornmentFrames(of: box).map(\.adornment))
        }
        expectEqual(shown, [[.of(Banner.self)], [.of(Banner.self), .of(Caption.self), .of(Pin.self)], [.of(Banner.self)]])
    },
    test("zoomed out, a placeholder's tab isn't shown: it names nothing") {
        let h = try adornedHarness([everyShape(Banner.self) { _ in AdornmentLabel(placeholder: "Frame") }])
        let box = h.add(Box(world(boxFrame, atZoom: 0.3)))
        h.editor.camera = Camera(origin: .zero, zoom: 0.3)
        expectEqual(h.editor.adornmentFrames(of: box).count, 0, "at 30%")
        h.editor.camera = Camera(origin: .zero, zoom: 0.35)
        expectEqual(h.editor.adornmentFrames(of: box).count, 1, "at 35%")
    },
    test("a press on a tab is on its shape, zoomed out too, where it's drawn and nowhere past it") {
        for zoom in [1, 0.3, 0.05] as [CGFloat] {
            let h = try adornedHarness([everyShape(Banner.self) { _ in AdornmentLabel("Lobby") }])
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let box = h.add(Box(world(boxFrame, atZoom: zoom)))
            let frame = try require(tabRect(h, box))
            // Above the box's edge, on the tab: the box, which isn't there.
            let onTab = h.editor.camera.toWorld(CGPoint(x: frame.midX, y: frame.minY + 3))
            expectEqual(h.editor.selectableShape(at: onTab), box, "on its tab at \(zoom)")
            let past = h.editor.camera.toWorld(CGPoint(x: frame.maxX + 8, y: frame.minY + 3))
            expectEqual(h.editor.selectableShape(at: past), nil, "past it at \(zoom)")
        }
    },
    test("tabs on two shapes give way: the larger's first, the smaller's slid past it; on a column, turned") {
        let h = try adornedHarness([everyShape(Banner.self) { shape in AdornmentLabel(shape.box!.width > 300 ? "Outer" : "Inner") }])
        let outer = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let inner = h.add(Box(CGRect(x: 0, y: 0, width: 200, height: 100)))
        let outerTab = try require(tabRect(h, outer)), innerTab = try require(tabRect(h, inner))
        expectEqual(outerTab.minX, 10)
        expectEqual(innerTab.minX, outerTab.maxX + 4, "slid past the outer one's")
        let column = h.add(Box(CGRect(x: 500, y: 0, width: 40, height: 400)))
        let columnTab = try require(tabRect(h, column))
        expect(columnTab.height > columnTab.width && columnTab.midX == 500, "turned down its left edge: \(columnTab)")
    },
    test("an untitled shape's placeholder gives way to a title: a titled shape in its corner keeps the corner") {
        let h = try adornedHarness([everyShape(Banner.self) { shape in
            shape.box!.width > 300 ? AdornmentLabel(placeholder: "Frame") : AdornmentLabel("Inner")
        }])
        let outer = h.add(Box(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let inner = h.add(Box(CGRect(x: 0, y: 0, width: 200, height: 100)))
        let innerTab = try require(tabRect(h, inner)), outerTab = try require(tabRect(h, outer))
        expectEqual(innerTab.minX, 10, "the title first, in the corner")
        expectEqual(outerTab.minX, innerTab.maxX + 4, "the placeholder slid past it")
    },
    test("zoomed out, labels are made only for the shapes with a tab, and nothing for the rest") {
        let calls = Calls()
        let h = try adornedHarness([countedCaptions(calls), everyShape(Banner.self, where: { $0.kind == Box.kind }) { _ in AdornmentLabel("Lobby") }])
        h.editor.transact { transaction in
            for column in 0..<50 { transaction.insert(ShapeRecord(Disc(CGRect(x: column * 100, y: 0, width: 80, height: 60)))) }
            transaction.insert(ShapeRecord(Box(CGRect(x: 0, y: 200, width: 400, height: 300))))
        }
        h.editor.camera = Camera(origin: .zero, zoom: 0.1)
        _ = render(h)
        expectEqual(calls.counts.count, 0, "no caption made zoomed out")
        expectEqual(h.editor.adornmentsKept, 1, "only the box's labels kept")
    },
])
