import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit
import Titles

// The pill is 18 points tall and 9 above its shape's top edge, so from 27 to 9 points above it.
// A shape's shadow reaches 6 points out, and the pill's edges are antialiased, so the pill is
// checked in its band 25 to 13 points above the edge.

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
    test("the pill fits its title, and stops at the shape's right edge, where a longer title ends in an ellipsis") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 60, y: 100, width: 120, height: 80)))
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
    test("a title of several lines shows on one") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(plaqueFrame, name: "Front\ndesk"))
        let twoLines = render(editor)
        editor.rename(id, "Front desk")
        expectEqual(changedPixels(twoLines, render(editor), in: CGRect(x: 0, y: 0, width: 400, height: 300)), 0)
    },
    test("no pill on an untitled or blank-titled shape, a kind opted in without one, or a shape too narrow for one") {
        let editor = try titleEditor([Contributor(id: "disc-titles") { $0.title(Disc.self, pill: false) { _ in "Disc" } }])
        let empty = render(editor)
        editor.add(Plaque(CGRect(x: 20, y: 60, width: 100, height: 60)))
        editor.add(Plaque(CGRect(x: 140, y: 60, width: 100, height: 60), name: "  "))
        editor.add(Disc(CGRect(x: 260, y: 60, width: 100, height: 60)))
        editor.add(Plaque(CGRect(x: 20, y: 200, width: 24, height: 60), name: "Narrow"))
        let shapes = render(editor)
        for x in [20, 140, 260] {
            expectEqual(changedPixels(empty, shapes, in: CGRect(x: x, y: 35, width: 100, height: 12)), 0, "above the shape at \(x)")
        }
        expectEqual(changedPixels(empty, shapes, in: CGRect(x: 20, y: 175, width: 24, height: 12)), 0, "above the narrow one")
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
    test("below 25% the pill shrinks with the shapes, as the checklist chip does") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 480, y: 960, width: 800, height: 480)))
        editor.camera = Camera(origin: .zero, zoom: 0.125)  // at (60, 120), 100 points wide: the pill half size, 4.5 to 13.5 points above
        let untitled = render(editor)
        editor.rename(id, "Lobby")
        let titled = render(editor)
        expect(changedPixels(untitled, titled, in: CGRect(x: 60, y: 108, width: 16, height: 6)) > 60, "the pill, half size")
        expectEqual(changedPixels(untitled, titled, in: CGRect(x: 60, y: 85, width: 100, height: 20)), 0, "not full size")
    },
    test("a shape just below the view shows its pill at the view's foot") {
        let editor = try titleEditor()
        let id = editor.add(Plaque(CGRect(x: 60, y: 310, width: 200, height: 120)))   // the view is 300 points tall
        let untitled = render(editor)
        editor.rename(id, "Lobby")
        expect(changedPixels(untitled, render(editor), in: CGRect(x: 60, y: 285, width: 36, height: 12)) > 300)
    },
])
