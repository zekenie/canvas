import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// The pill is 18 points tall and 9 above its shape's top edge, so from 27 to 9 points above it.
// A shape's shadow reaches 6 points out, and the pill's edges are antialiased, so the pill is
// checked in its band 25 to 13 points above the edge.

/// Something at the right end of the pill's row from a plugin Titles doesn't know, as a lock is.
enum CornerDisc {}

extension CornerDisc: Adornment {
    static var placement: AdornmentPlacement { .aboveTopRight }
}

@MainActor let pillTests = Suite("Title pills", [
    test("a titled shape shows its title in a pill just above its top-left corner, outside it") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame))          // its top-left corner at (60, 100)
        let untitled = render(editor)
        editor.rename(id, "Lobby")
        let titled = render(editor)
        expect(changedPixels(untitled, titled, in: CGRect(x: 60, y: 75, width: 36, height: 12)) > 300, "the pill")
        expectEqual(changedPixels(untitled, titled, in: plaqueFrame), 0, "nothing on the shape")
        expectEqual(changedPixels(untitled, titled, in: CGRect(x: 0, y: 60, width: 60, height: 60)), 0, "nothing left of it")
        expectEqual(changedPixels(untitled, titled, in: CGRect(x: 60, y: 55, width: 200, height: 17)), 0, "nothing higher")
    },
    test("the pill fits its title, up to the shape's right edge with nothing at the row's other end, where a longer title ends in an ellipsis") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 60, y: 100, width: 120, height: 80)))   // its right edge at 180
        let untitled = render(editor)
        editor.rename(id, "Hi")
        let short = render(editor)
        expect(changedPixels(untitled, short, in: CGRect(x: 60, y: 75, width: 20, height: 12)) > 150, "a short pill")
        expectEqual(changedPixels(untitled, short, in: CGRect(x: 100, y: 73, width: 100, height: 18)), 0, "only as long as its title")
        editor.rename(id, "A name much longer than the plaque is wide")
        let long = render(editor)
        expect(changedPixels(untitled, long, in: CGRect(x: 160, y: 75, width: 19, height: 12)) > 100, "up to the right edge")
        expectEqual(changedPixels(untitled, long, in: CGRect(x: 181, y: 65, width: 100, height: 30)), 0, "and no further")
    },
    test("a long title's pill stops 4 points short of what the row's right end holds, whoever put it there") {
        let discs = Contributor(id: "corner-discs") { $0.adornmentForEveryShape(CornerDisc.self) { _, _ in AdornmentLabel(systemImage: "circle.fill") } }
        let editor = try titleEditor([discs])
        let empty = render(editor)
        let id = editor.add(Plaque(CGRect(x: 60, y: 100, width: 120, height: 80)))   // its right edge at 180, the disc from 162
        let untitled = render(editor)
        expect(changedPixels(empty, untitled, in: CGRect(x: 165, y: 76, width: 12, height: 12)) > 50, "the disc, titled or not")
        editor.rename(id, "A name much longer than the plaque is wide")
        let long = render(editor)
        // The disc's 18 points, and 4 before it, are left out: the pill ends at 158.
        expect(changedPixels(untitled, long, in: CGRect(x: 140, y: 75, width: 17, height: 12)) > 100, "up to the disc")
        expectEqual(changedPixels(untitled, long, in: CGRect(x: 159, y: 65, width: 121, height: 30)), 0, "and no further")
    },
    test("a title of several lines shows on one") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame), named: "Front\ndesk")
        let twoLines = render(editor)
        editor.rename(id, "Front desk")
        expectEqual(changedPixels(twoLines, render(editor), in: CGRect(x: 0, y: 0, width: 400, height: 300)), 0)
    },
    test("no pill on an untitled or blank-titled shape, a kind opted in without one, or a shape too narrow for one") {
        let editor = try titleEditor([Contributor(id: "disc-titles") { $0.title(Disc.self, pill: false) { _ in "Disc" } }])
        let empty = render(editor)
        editor.add(Plaque(CGRect(x: 20, y: 60, width: 100, height: 60)))
        editor.add(Plaque(CGRect(x: 140, y: 60, width: 100, height: 60)), named: "  ")
        editor.add(Disc(CGRect(x: 260, y: 60, width: 100, height: 60)))
        editor.add(Plaque(CGRect(x: 20, y: 200, width: 24, height: 60)), named: "Narrow")
        let shapes = render(editor)
        for x in [20, 140, 260] {
            expectEqual(changedPixels(empty, shapes, in: CGRect(x: x, y: 35, width: 100, height: 12)), 0, "above the shape at \(x)")
        }
        expectEqual(changedPixels(empty, shapes, in: CGRect(x: 20, y: 175, width: 24, height: 12)), 0, "above the narrow one")
    },
    test("a kind that asks has its symbol, its tool's, before its title in the pill, longer by the symbol's place; others have none, nor does a kind with no symbol") {
        let marked = Contributor(id: "card-titles") { $0.title(Card.self, symbolInPill: true) { $0.props.text } }
        let bare = Contributor(id: "disc-titles") { $0.title(Disc.self, symbolInPill: true) { _ in "Disc" } }
        let editor = try titleEditor([CardsPlugin(), marked, bare])
        let plaque = editor.add(Plaque(plaqueFrame), named: "Lobby")
        let card = editor.add(Card(CGRect(x: 60, y: 300, width: 200, height: 80), text: "Lobby"))
        let disc = editor.add(Disc(CGRect(x: 300, y: 100, width: 100, height: 60)))
        @MainActor func pill(_ id: ShapeID) -> AdornmentFrame? { editor.adornmentFrames(of: id).first }
        expectEqual(pill(plaque)?.label, AdornmentLabel("Lobby"), "a kind that doesn't ask")
        expectEqual(pill(card)?.label, AdornmentLabel("Lobby", systemImage: "rectangle"), "the card tool's symbol")
        expectEqual(pill(disc)?.label, AdornmentLabel("Disc"), "a kind with no symbol: its title alone")
        expectEqual((pill(card)?.rect.width ?? 0) - (pill(plaque)?.rect.width ?? 0), 14, "the symbol's place, 11, and the gap after it, 3")
    },
    test("the pill keeps its size on screen as the view zooms in") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 30, y: 60, width: 100, height: 60)))
        editor.camera = Camera(origin: .zero, zoom: 2)      // the plaque's top-left corner at (60, 120)
        let untitled = render(editor)
        editor.rename(id, "Lobby")
        let titled = render(editor)
        expect(changedPixels(untitled, titled, in: CGRect(x: 60, y: 95, width: 36, height: 12)) > 300, "9 to 27 points above the corner")
        expectEqual(changedPixels(untitled, titled, in: CGRect(x: 60, y: 60, width: 200, height: 32)), 0, "not up to 54, as it would be zoomed")
    },
    test("below 25% the pill shrinks with the shapes, as every adornment does, and it's blank, as below 35%") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 480, y: 960, width: 800, height: 480)))
        editor.camera = Camera(origin: .zero, zoom: 0.125)  // at (60, 120), 100 points wide: the pill half size, 4.5 to 13.5 points above
        let untitled = render(editor)
        editor.rename(id, "Lobby")
        let titled = render(editor)
        expect(changedPixels(untitled, titled, in: CGRect(x: 60, y: 108, width: 16, height: 6)) > 60, "the pill, half size")
        expectEqual(changedPixels(untitled, titled, in: CGRect(x: 60, y: 85, width: 100, height: 20)), 0, "not full size")
        // Its straight middle, 4.5 points in from each end, is one color: no text.
        let pill = editor.camera.toView(try require(editor.adornmentFrames(of: id).first).rect)
        let middle = pill.insetBy(dx: pill.height / 2 + 1, dy: 2)
        let colors = Set(stride(from: middle.minY, to: middle.maxY, by: 1).flatMap { y in
            stride(from: middle.minX, to: middle.maxX, by: 1).map { x in pixel(titled, at: CGPoint(x: x, y: y)) }
        })
        expect(middle.width > 8, "\(pill)")
        expectEqual(colors.count, 1, "blank: \(colors)")
    },
    test("below 35%, where shapes are skeletons, the pill is its capsule alone; at 35% it has its text") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 60 / 0.3, y: 100 / 0.3, width: 200 / 0.3, height: 120 / 0.3)), named: "Front desk")
        var counts: [CGFloat: Int] = [:]
        for zoom in [0.3, 0.35] as [CGFloat] {
            editor.camera = Camera(origin: .zero, zoom: zoom)
            let pill = editor.camera.toView(try require(editor.adornmentFrames(of: id).first).rect)
            let middle = pill.insetBy(dx: pill.height / 2, dy: 3)
            let rendered = render(editor)
            counts[zoom] = Set(stride(from: middle.minY, to: middle.maxY, by: 1).flatMap { y in
                stride(from: middle.minX, to: middle.maxX, by: 1).map { x in pixel(rendered, at: CGPoint(x: x, y: y)) }
            }).count
        }
        expectEqual(counts[0.3], 1, "blank at 30%")
        expect((counts[0.35] ?? 0) > 3, "its text at 35%: \(counts)")
    },
    test("a shape just below the view shows its pill at the view's foot") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 60, y: 310, width: 200, height: 120)))   // the view is 300 points tall
        let untitled = render(editor)
        editor.rename(id, "Lobby")
        expect(changedPixels(untitled, render(editor), in: CGRect(x: 60, y: 285, width: 36, height: 12)) > 300)
    },
    test("the pill goes where its shape is drawn (a shake), in view points") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 30, y: 50, width: 100, height: 60)), named: "Lobby")
        editor.camera = Camera(origin: .zero, zoom: 2)      // the plaque's top-left corner at (60, 100)
        let still = render(editor)
        editor.setDrawingOffset(CGPoint(x: 12, y: 0), for: id)
        let moved = render(editor)
        for y in stride(from: 76, through: 86, by: 2) {
            for x in stride(from: 60, through: 90, by: 3) {
                expectEqual(pixel(moved, at: CGPoint(x: x + 12, y: y)), pixel(still, at: CGPoint(x: x, y: y)), "(\(x), \(y))")
            }
        }
    },
])
