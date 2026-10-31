@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Moving between shapes: Tab and ⌥⌘ with an arrow key step the selection from shape to shape (tldraw's
// selectAdjacentShape), ⌘↓ and Return go into a group or a container (selectFirstChildShape), and the
// enclosure is what ⌘↑ steps out to (selectParentShape). Shapes are placed by their centers, which is
// what stepping goes by.

/// The keys, the selection, the fixtures, cards, containers (corrals), links (which have no box), ghosts
/// (which can't be selected) and a fixture's groups, in a view `view` points across if it has one.
@MainActor private func stepHarness(_ groups: GroupsFixture = GroupsFixture(), view: CGSize? = nil, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try groupsHarness(groups, [CorralsPlugin(), LinksPlugin(), GhostsPlugin()] + more)
    if let view { h.editor.viewportDidResize(to: view) }
    return h
}

private let down = KeyChord.downArrow, up = KeyChord.upArrow, left = KeyChord.leftArrow, right = KeyChord.rightArrow

extension EditorHarness {
    /// A box `size` points across whose middle is at (x, y).
    @discardableResult fileprivate func dot(_ x: CGFloat, _ y: CGFloat, size: CGFloat = 20) -> ShapeID {
        add(Box(CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)))
    }

    /// Tab, or ⇧Tab: whether a shortcut took the key.
    @discardableResult fileprivate func tab(back: Bool = false) -> Bool {
        hold(back ? .shift : [])
        defer { hold([]) }
        return key("\t")
    }

    /// ⌥⌘ and an arrow key (⇧⌥⌘ to add): whether a shortcut took it.
    @discardableResult fileprivate func step(_ arrow: KeyChord, adding: Bool = false) -> Bool {
        hold(adding ? [.option, .command, .shift] : [.option, .command])
        defer { hold([]) }
        return key(String(arrow.key))
    }

    /// ⌘↓ or ⌘↑: whether a shortcut took it.
    @discardableResult fileprivate func command(_ arrow: KeyChord) -> Bool {
        hold(.command)
        defer { hold([]) }
        return key(String(arrow.key))
    }

    /// Tabs through `ids` in turn, each the only selected shape.
    fileprivate func tabs(through ids: [ShapeID], back: Bool = false) {
        for id in ids {
            tab(back: back)
            expectEqual(editor.selectedShapeIDs, [id])
        }
    }
}

@MainActor let steppingTests = Suite("Moving between shapes", [
    test("Tab goes through the shapes in reading order, row by row, left to right, and ⇧Tab the other way; both wrap; with nothing selected, the first, or the last") {
        let h = try stepHarness()
        let e = h.dot(250, 250), a = h.dot(50, 50), d = h.dot(50, 250), c = h.dot(450, 50), b = h.dot(250, 50)
        expect(h.tab(), "a shortcut takes Tab")
        expectEqual(h.editor.selectedShapeIDs, [a], "nothing selected: the first")
        h.tabs(through: [b, c, d, e, a])
        h.tabs(through: [e, d, c, b, a], back: true)
        h.editor.selectedShapeIDs = []
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [e], "going back with nothing selected: the last")
    },
    test("a shape joins a row when its middle is under 100 units above or below the row's last, so one lower than another can read first") {
        let h = try stepHarness()
        let p = h.dot(50, 50), s = h.dot(-150, 130), q = h.dot(250, 140), r = h.dot(50, 260)
        h.tabs(through: [s, p, q, r])
        let chain = try stepHarness()
        let first = chain.dot(300, 0), second = chain.dot(200, 60), third = chain.dot(100, 120)
        chain.tabs(through: [third, second, first])
        let apart = try stepHarness()
        let upper = apart.dot(200, 0), lower = apart.dot(100, 100)
        apart.tabs(through: [upper, lower])
    },
    test("in a row, the next two swap when the one after next is nearer the shape by a tenth of the squared distance, in a shallow angle") {
        let swapped = try stepHarness()
        let a = swapped.dot(0, 0), b = swapped.dot(100, 90), c = swapped.dot(105, 0)
        swapped.tabs(through: [a, c, b])
        let steep = try stepHarness()
        let first = steep.dot(0, 0), second = steep.dot(100, 90), third = steep.dot(105, 60)
        steep.tabs(through: [first, second, third])
    },
    test("only the selection's siblings count: the board's own shapes, or the shapes of the container the selection is in, which ⇧Tab and Tab wrap round") {
        let h = try stepHarness()
        let a = h.dot(50, 50), c = h.dot(850, 50)
        let corral = h.add(Corral(CGRect(x: 300, y: 0, width: 400, height: 200)))
        let inner = h.dot(400, 100), other = h.dot(600, 200)
        h.editor.put([inner, other], in: corral)
        h.editor.selectedShapeIDs = [a]
        h.tabs(through: [corral, c, a], back: false)
        h.editor.selectedShapeIDs = [inner]
        h.tabs(through: [other, inner, other])
        h.tabs(through: [inner], back: true)
        h.editor.selectedShapeIDs = [inner, a]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [corral], "shapes in different places: the board's own, from the first of them it has")
    },
    test("shape(_:from:among:): the next or previous in reading order of the shapes taken in the same container, each alone, wrapping; nil alone and for a direction") {
        let h = try stepHarness()
        let a = h.dot(50, 50), b = h.dot(250, 50), skipped = h.dot(450, 50), d = h.dot(50, 250)
        let corral = h.add(Corral(CGRect(x: 600, y: 0, width: 400, height: 200)))
        let inner = h.dot(700, 100), other = h.dot(900, 100)
        h.editor.put([inner, other], in: corral)
        let taken: (AnyShapeRecord) -> Bool = { $0.kind == Box.kind && $0.id != skipped }
        expectEqual(h.editor.shape(.next, from: a, among: taken), b)
        expectEqual(h.editor.shape(.next, from: b, among: taken), d, "one not taken is passed over, and the corral's are not the board's")
        expectEqual(h.editor.shape(.next, from: d, among: taken), a, "wrapping")
        expectEqual(h.editor.shape(.previous, from: a, among: taken), d)
        expectEqual(h.editor.shape(.next, from: inner, among: taken), other, "in a container, its own")
        expectEqual(h.editor.shape(.previous, from: inner, among: taken), other)
        expectEqual(h.editor.shape(.next, from: a, among: { $0.id == a }), nil, "alone")
        expectEqual(h.editor.shape(.right, from: a, among: taken), nil, "a direction isn't an order")
        expectEqual(h.editor.selectedShapeIDs, [], "it selects nothing")
    },
    test("a group is one stop, where its shapes' bounds are; inside it, its parts are, and Tab wraps in it") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let g1 = h.dot(50, 50), g2 = h.dot(250, 50), y = h.dot(450, 50), x = h.dot(650, 50)
        groups.paths = [g1: ["g"], g2: ["g"]]
        h.editor.selectedShapeIDs = [x]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [g1, g2], "the group, whole")
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [y])
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [g1, g2])
        h.editor.selectedShapeIDs = [g1]
        expectEqual(h.editor.selectionFocus, ["g"])
        h.tabs(through: [g2, g1, g2])
        expectEqual(h.editor.selectionFocus, ["g"], "not out of the group")
        h.editor.selectedShapeIDs = []
        expectEqual(h.editor.selectionFocus, ["g"], "an empty selection keeps the group it was inside")
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [g1], "and Tab with nothing selected goes to the first of its parts")
        h.editor.selectedShapeIDs = []
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [g2], "⇧Tab to the last")
    },
    test("groups in groups: with the selection inside the outer one, its stops are the inner group and the shapes beside it") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let a = h.dot(50, 50), b = h.dot(150, 50), c = h.dot(300, 50), d = h.dot(600, 50)
        groups.paths = [a: ["outer", "inner"], b: ["outer", "inner"], c: ["outer"]]
        h.editor.selectedShapeIDs = [c]
        expectEqual(h.editor.selectionFocus, ["outer"])
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [a, b], "the inner group whole")
        expectEqual(h.editor.selectionFocus, ["outer"])
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [c])
        h.editor.selectedShapeIDs = [a]
        expectEqual(h.editor.selectionFocus, ["outer", "inner"])
        h.tabs(through: [b, a])
        h.editor.selectedShapeIDs = [d]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [a, b, c], "outside it, the outer group is the stop")
    },
    test("arrows, which have no box, and shapes that can't be selected are never stops") {
        let h = try stepHarness()
        let a = h.dot(50, 50), b = h.dot(250, 50), c = h.dot(450, 50)
        h.add(Link(from: a, to: c))
        h.add(Ghost(CGRect(x: 340, y: 40, width: 20, height: 20)))
        h.tabs(through: [a, b, c, a])
        h.editor.selectedShapeIDs = [b]
        h.step(right)
        expectEqual(h.editor.selectedShapeIDs, [c])
        h.step(left)
        h.step(left)
        expectEqual(h.editor.selectedShapeIDs, [a])
    },
    test("a held Tab goes on, and the keys take no part while a gesture runs or a shape is edited") {
        let h = try stepHarness()
        let a = h.dot(50, 50), b = h.dot(250, 50), c = h.dot(450, 50)
        h.editor.selectedShapeIDs = [a]
        expect(h.key("\t"))
        expect(h.key("\t", isRepeat: true))
        expectEqual(h.editor.selectedShapeIDs, [c], "again and again while held")
        let card = h.add(Card(CGRect(x: 40, y: 340, width: 100, height: 60)))
        h.editor.selectedShapeIDs = [b]
        h.press(at: CGPoint(x: 500, y: 500))
        h.drag(to: CGPoint(x: 600, y: 600))
        expect(!h.tab() && !h.step(right), "mid-gesture the keys pass")
        h.release()
        h.editor.selectedShapeIDs = [b]
        expect(h.editor.beginEditing(card))
        expect(!h.tab() && !h.step(right), "while editing")
        h.editor.endEditing()
        expect(h.tab())
    },
    test("the camera stays where the next shape is in view, and goes where it is not, at the zoom it has") {
        let view = CGSize(width: 1000, height: 700)
        let h = try stepHarness(view: view)
        let a = h.dot(150, 150, size: 100), c = h.dot(450, 150, size: 100), far = h.dot(3050, 2050, size: 100)
        h.editor.selectedShapeIDs = [a]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [c])
        h.wait(200)
        expectEqual(h.editor.camera, Camera(), "in view: nothing moves")
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.wait(100)
        expect(h.editor.camera != Camera() && h.editor.camera != Camera(fitting: CGRect(x: 3000, y: 2000, width: 100, height: 100), in: view, inset: 100, maxZoom: 1),
               "on its way over 200 ms: \(h.editor.camera)")
        h.wait(100)
        let there = Camera(fitting: CGRect(x: 3000, y: 2000, width: 100, height: 100), in: view, inset: 100, maxZoom: 1)
        expectEqual(h.editor.camera, there)
        expectEqual(h.editor.camera.zoom, 1, "not closer, as going to a shape would bring it")
        h.tab(back: true)
        h.wait(200)
        expectEqual(h.editor.selectedShapeIDs, [c])
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 400, y: 100, width: 100, height: 100), in: view, inset: 100, maxZoom: 1), "and back")
    },
    test("a shape partly in view is brought in, and one too big for the view zooms it out to fit") {
        let view = CGSize(width: 1000, height: 700)
        let edge = try stepHarness(view: view)
        let a = edge.dot(150, 150, size: 100), cut = edge.dot(1000, 150, size: 100)
        edge.editor.selectedShapeIDs = [a]
        edge.tab()
        expectEqual(edge.editor.selectedShapeIDs, [cut])
        edge.wait(200)
        expectEqual(edge.editor.camera, Camera(fitting: CGRect(x: 950, y: 100, width: 100, height: 100), in: view, inset: 100, maxZoom: 1))

        let big = try stepHarness(view: view)
        let first = big.dot(150, 150, size: 100)
        let wide = big.add(Box(CGRect(x: 0, y: 1000, width: 4000, height: 100)))
        big.editor.selectedShapeIDs = [first]
        big.tab()
        expectEqual(big.editor.selectedShapeIDs, [wide])
        big.wait(200)
        let fitted = Camera(fitting: CGRect(x: 0, y: 1000, width: 4000, height: 100), in: view, inset: 100, maxZoom: 1)
        expectEqual(big.editor.camera, fitted)
        expect(fitted.zoom < 0.3, "zoomed out to fit: \(fitted.zoom)")
    },
    test("an arrow with ⌥⌘ selects the nearest shape that way, from the one selected last; with none that way nothing happens, and the key is taken") {
        let h = try stepHarness()
        let origin = h.dot(500, 500)
        let east = h.dot(800, 500), north = h.dot(500, 200), west = h.dot(200, 500), south = h.dot(500, 800)
        h.editor.selectedShapeIDs = [origin]
        for (arrow, target) in [(right, east), (up, north), (left, west), (down, south)] {
            h.editor.selectedShapeIDs = [origin]
            expect(h.step(arrow))
            expectEqual(h.editor.selectedShapeIDs, [target])
        }
        expect(h.step(down), "taken")
        expectEqual(h.editor.selectedShapeIDs, [south], "nothing south of south")
        h.editor.selectedShapeIDs = []
        expect(h.step(right), "taken with nothing selected")
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.selectedShapeIDs = [east, origin]
        h.step(left)
        expectEqual(h.editor.selectedShapeIDs, [west], "from the shape selected last")
    },
    test("the nearest is the lowest score: straight ahead beats a nearer one off to the side, until it is far enough") {
        /// Steps east from (100, 400), with a shape `ahead` units east of it and one 150 east and 100 south.
        @MainActor func stepEast(ahead distance: CGFloat) throws -> (selected: [ShapeID], ahead: ShapeID, aside: ShapeID) {
            let h = try stepHarness()
            let origin = h.dot(100, 400), ahead = h.dot(100 + distance, 400), aside = h.dot(250, 500)
            h.editor.selectedShapeIDs = [origin]
            h.step(right)
            return (h.editor.selectedShapeIDs, ahead, aside)
        }
        // 300 straight ahead scores 300; the other, 150 over and 100 down, scores about 443.
        let near = try stepEast(ahead: 300)
        expectEqual(near.selected, [near.ahead])
        // 900 ahead scores 900.
        let far = try stepEast(ahead: 900)
        expectEqual(far.selected, [far.aside])
    },
    test("only shapes in the direction's wedge count: across no more than twice as far as along, on that side") {
        let h = try stepHarness()
        let origin = h.dot(500, 500)
        let steep = h.dot(600, 750), flat = h.dot(900, 650)
        h.editor.selectedShapeIDs = [origin]
        h.step(right)
        expectEqual(h.editor.selectedShapeIDs, [flat], "250 down for 100 across is not east; 150 for 400 is")
        h.editor.selectedShapeIDs = [origin]
        h.step(down)
        expectEqual(h.editor.selectedShapeIDs, [steep], "that one is south")
        h.editor.selectedShapeIDs = [origin]
        h.step(left)
        h.step(up)
        expectEqual(h.editor.selectedShapeIDs, [origin], "nothing west or north")
        h.editor.selectedShapeIDs = [origin]
        let level = h.dot(500, 300)
        let beside = h.dot(700, 500)
        h.step(up)
        expectEqual(h.editor.selectedShapeIDs, [level])
        h.editor.selectedShapeIDs = [origin]
        h.step(right)
        expectEqual(h.editor.selectedShapeIDs, [beside], "now straight east is nearer than the other")
    },
    test("the angle off the direction counts both ways round: a shape a little north of east is not 350 degrees from it") {
        let h = try stepHarness()
        let origin = h.dot(100, 400)
        let above = h.dot(400, 350)
        h.dot(400, 460)
        h.editor.selectedShapeIDs = [origin]
        h.step(right)
        // 304 + 2 × 50 + 6 + 5 against 306 + 2 × 60 + 9 + 6: the angle of the one above, 350 degrees round, is 9 off east.
        expectEqual(h.editor.selectedShapeIDs, [above])
    },
    test("with ⇧, the nearest shape that way that is not selected yet is added after the selection, and the start stays first") {
        let h = try stepHarness()
        let a = h.dot(100, 100), b = h.dot(300, 100), c = h.dot(500, 100), d = h.dot(300, 600)
        h.editor.selectedShapeIDs = [a]
        expect(h.step(right, adding: true))
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.step(right, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, b, c])
        // Selected outright, so no step is there to undo.
        h.editor.selectedShapeIDs = []
        h.editor.selectedShapeIDs = [a, b, c]
        h.step(left, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, b, c], "b and a are selected, and d is not to the west")
        h.step(down, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, b, c, d])
        h.editor.selectedShapeIDs = []
        h.editor.selectedShapeIDs = [a, b, c, d]
        h.step(up, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, b, c, d], "all selected")
        h.editor.selectedShapeIDs = [a]
        h.step(down, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, d])
        h.step(right, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, d], "from d, nothing east is unselected")
    },
    test("a group added is added whole, and a group is a stop to step to") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let a = h.dot(100, 100), g1 = h.dot(400, 100), g2 = h.dot(600, 100), z = h.dot(900, 100)
        groups.paths = [g1: ["g"], g2: ["g"]]
        h.editor.selectedShapeIDs = [a]
        h.step(right, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, g1, g2])
        h.step(right, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, g1, g2, z])
        h.editor.selectedShapeIDs = [a]
        h.step(right)
        expectEqual(h.editor.selectedShapeIDs, [g1, g2])
    },
    test("stepping to a shape in view is no step back; to one out of view it is, and Back returns to the shape left") {
        let h = try stepHarness(view: CGSize(width: 1000, height: 700))
        let a = h.dot(50, 50), b = h.dot(250, 50), far = h.dot(5000, 50)
        h.editor.selectedShapeIDs = [a]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [b])
        expect(!h.editor.canGoBack, "b was in view")
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [b])
    },
    test("Go › Forward (⌘]) undoes Back, place by place, until the person goes somewhere new") {
        let h = try stepHarness(view: CGSize(width: 1000, height: 700))
        let a = h.dot(50, 50), b = h.dot(5050, 50), c = h.dot(10050, 50)
        h.editor.selectedShapeIDs = [a]
        h.tabs(through: [b, c])                                  // each out of the view the one before was brought into
        expect(!h.editor.canGoForward, "nothing gone back from")
        h.hold(.command)
        expect(!h.key("]"), "the key passes, as the item is dimmed")
        expect(h.key("["))
        expect(h.key("["))
        expectEqual(h.editor.selectedShapeIDs, [a])
        expect(h.key("]"))
        expectEqual(h.editor.selectedShapeIDs, [b])
        expect(h.key("]"))
        expectEqual(h.editor.selectedShapeIDs, [c])
        expect(!h.key("]"), "as far as it went")
        expect(h.key("["))
        h.hold([])
        expectEqual(h.editor.selectedShapeIDs, [b])
        expect(h.editor.canGoForward)
        h.editor.selectedShapeIDs = [a]
        expect(!h.editor.canGoForward, "a, out of view, is a new place, which lets the way forward go, as a browser's does")
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [b], "and Back is to where it was left from")
    },
    test("⇧Tab after Tab from several shapes selects them again, and Tab after ⇧Tab; a step of its own goes on from the first") {
        let h = try stepHarness()
        let a = h.dot(50, 50), b = h.dot(250, 50), c = h.dot(450, 50), d = h.dot(650, 50)
        h.editor.selectedShapeIDs = [b, c]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [c], "from the first of them in reading order")
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [b, c], "exactly where it began")
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [a], "a step of its own")
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [b, c])
        h.tabs(through: [c, d, a, b])
        for back in [a, d, c] { h.tab(back: true); expectEqual(h.editor.selectedShapeIDs, [back]) }
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [b, c], "every step retraced")
        h.editor.selectedShapeIDs = [a, d]
        h.tab()
        h.editor.selectedShapeIDs = [c]
        h.editor.selectedShapeIDs = [b]
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [a], "the selection changed otherwise: no step is undone")
        h.editor.selectedShapeIDs = []
        h.tab()
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [], "from nothing selected, back to nothing")
    },
    test("⌥⌘ and an arrow, then the opposite, come back to the start, in each direction, where the nearest that way would not") {
        let across = try stepHarness()
        let s = across.dot(0, 0), r = across.dot(300, 0), x = across.dot(200, 60)
        let down = try stepHarness()
        let top = down.dot(0, 0), bottom = down.dot(0, 300), side = down.dot(60, 200)
        // x is nearer r than s is, westward, and side nearer bottom than top is, northward.
        for (h, start, arrow, there, back, near) in [(across, s, right, r, left, x), (across, r, left, x, right, r),
                                                     (down, top, KeyChord.downArrow, bottom, KeyChord.upArrow, side),
                                                     (down, bottom, KeyChord.upArrow, side, KeyChord.downArrow, bottom)] {
            h.editor.selectedShapeIDs = [start]
            h.step(arrow)
            expectEqual(h.editor.selectedShapeIDs, [there])
            h.step(back)
            expectEqual(h.editor.selectedShapeIDs, [start], "back where it began")
            h.editor.selectedShapeIDs = [there]
            h.step(back)
            expectEqual(h.editor.selectedShapeIDs, [near], "with no step to undo, the nearest that way")
        }
    },
    test("a step back to a shape that has gone since steps on instead: ⇧Tab after Tab and a deletion goes to the stop before, never to nothing") {
        let h = try stepHarness()
        let a = h.dot(100, 100), b = h.dot(300, 100), c = h.dot(500, 100)
        h.editor.selectedShapeIDs = [a]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [b])
        h.editor.transact { $0.delete([a]) }
        expectEqual(h.editor.selectedShapeIDs, [b], "still where Tab left it")
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [c], "the stop before b, wrapping, as with no step to undo")
    },
    test("⇧⌥⌘ and an arrow, then the opposite, take off the shape it added") {
        let h = try stepHarness()
        let a = h.dot(100, 100), b = h.dot(300, 100), c = h.dot(500, 100)
        h.editor.selectedShapeIDs = [a]
        h.step(right, adding: true)
        h.step(right, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, b, c])
        h.step(left, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        h.step(left, adding: true)
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.step(right, adding: true)
        h.step(left)
        expectEqual(h.editor.selectedShapeIDs, [a], "a plain ⌥⌘ step is no undo of an added one: from b, west is a")
    },
    test("Tab from a selected arrow goes to the stop after its middle in reading order, ⇧Tab to the one before, never an end; the opposite key comes back to it") {
        let h = try stepHarness()
        h.dot(50, 50)
        let b = h.dot(250, 50), c = h.dot(450, 50)
        h.dot(650, 50)
        let link = h.add(Link(from: b, to: c))
        h.editor.selectedShapeIDs = [link]
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [c], "after the middle, between b and c")
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [link], "back to the arrow")
        h.tab(back: true)
        expectEqual(h.editor.selectedShapeIDs, [b], "before the middle")
        h.tab()
        expectEqual(h.editor.selectedShapeIDs, [link])
    },
])

/// Corrals that open, as a board-owning container would: opening one sets the flag.
@MainActor private func openingCorrals(_ opened: Flag) -> Contributor {
    Contributor(id: "opening-corrals") { r in r.opens(Corral.self, "Open") { _, _ in opened.set() } }
}

@MainActor let enteringTests = Suite("Going into and out of groups and containers", [
    test("⌘↓ and Return with a group selected whole select its first part, one level in, first in reading order, not the first in the stack") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let east = h.dot(450, 50), west = h.dot(50, 50), middle = h.dot(250, 50)
        groups.paths = [east: ["g"], west: ["g"], middle: ["g"]]
        h.click(at: CGPoint(x: 50, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [east, west, middle], "the group, whole")
        expect(h.editor.canPerform(.openSelection))
        expect(h.command(down))
        expectEqual(h.editor.selectedShapeIDs, [west])
        expectEqual(h.editor.selectionFocus, ["g"])
        h.escape()
        expectEqual(h.editor.selectedShapeIDs, [east, west, middle])
        expect(h.key("\r"))
        expectEqual(h.editor.selectedShapeIDs, [west], "Return does the same")
        expect(!h.editor.canPerform(.openSelection), "a lone box opens nothing")
        expect(!h.command(down), "⌘↓ then passes")
        expect(h.key("\r"), "Return takes the key all the same")
        expectEqual(h.editor.selectedShapeIDs, [west])
    },
    test("in a group of groups, ⌘↓ goes one level at a time, to the inner group that reads first, then to its first shape") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let a = h.dot(50, 50), b = h.dot(150, 50), c = h.dot(300, 50), later = h.dot(600, 50)
        groups.paths = [a: ["outer", "inner"], b: ["outer", "inner"], c: ["outer"]]
        h.click(at: CGPoint(x: 300, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [a, b, c])
        h.command(down)
        expectEqual(h.editor.selectedShapeIDs, [a, b], "the inner group whole, which reads before c")
        h.command(down)
        expectEqual(h.editor.selectedShapeIDs, [a])
        h.wait(200)   // a key let go a moment ago still counts as held
        h.click(at: CGPoint(x: 600, y: 50))
        expectEqual(h.editor.selectedShapeIDs, [later])
        expect(!h.editor.canPerform(.openSelection), "a lone shape in no group is no group")
    },
    test("⌘↓ on a container that is a part of a group goes into it: what it holds is in none of the group's") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let inner = h.dot(100, 100)
        h.editor.put([inner], in: corral)
        let other = h.dot(700, 100)
        groups.paths = [corral: ["g"], other: ["g"]]
        h.editor.selectionGroupsDidChange()
        h.editor.selectedShapeIDs = [corral, other]
        expect(h.command(down))
        expectEqual(h.editor.selectedShapeIDs, [corral], "the group's first part")
        expectEqual(h.editor.selectionFocus, ["g"])
        expect(h.editor.canPerform(.openSelection))
        expect(h.command(down))
        expectEqual(h.editor.selectedShapeIDs, [inner], "into the container, though the selection was inside the group")
    },
    test("⌘↓ and Return with one container selected, whose kind neither opens nor edits, select the first shape in it in reading order; a group in it is a stop") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let late = h.dot(500, 100), early = h.dot(100, 100), low = h.dot(100, 300)
        h.editor.put([late, early, low], in: corral)
        h.editor.selectedShapeIDs = [corral]
        expect(h.editor.canPerform(.openSelection))
        expect(h.command(down))
        expectEqual(h.editor.selectedShapeIDs, [early])
        h.editor.selectedShapeIDs = [corral]
        expect(h.key("\r"))
        expectEqual(h.editor.selectedShapeIDs, [early])
        groups.paths = [early: ["g"], low: ["g"]]
        h.editor.selectedShapeIDs = [corral]
        h.command(down)
        expectEqual(h.editor.selectedShapeIDs, [late], "the group's middle is lower than late's row")
        groups.paths = [:]
        // A double-click on it is as it was: it opens nothing.
        h.wait(200)
        h.click(at: CGPoint(x: 300, y: 200))
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [corral])
    },
    test("a container with nothing to step to, one that opens, and one that edits are opened as ever") {
        let opened = Flag()
        let h = try stepHarness(GroupsFixture())
        let empty = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 300)))
        h.editor.selectedShapeIDs = [empty]
        expect(!h.editor.canPerform(.openSelection) && !h.command(down), "nothing in it: ⌘↓ passes")
        expect(h.key("\r"), "Return takes the key")
        expectEqual(h.editor.selectedShapeIDs, [empty])
        let card = h.add(Card(CGRect(x: 400, y: 0, width: 100, height: 60)))
        h.editor.selectedShapeIDs = [card]
        expect(h.editor.canPerform(.openSelection), "an editable one is edited")

        let opening = try stepHarness(GroupsFixture(), [openingCorrals(opened)])
        let corral = opening.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 300)))
        let inside = opening.dot(100, 100)
        opening.editor.put([inside], in: corral)
        opening.editor.selectedShapeIDs = [corral]
        expect(opening.command(down))
        expect(opened.isSet, "a container that opens is opened by its opener")
        expectEqual(opening.editor.selectedShapeIDs, [corral], "and not gone into")
    },
    test("Open Selection is asked of the shapes it's given, the selection or not (a right-click's): a group whole, a container alone, a shape that opens; never several") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let west = h.dot(50, 50), east = h.dot(250, 50), lone = h.dot(450, 50)
        groups.paths = [west: ["g"], east: ["g"]]
        let corral = h.add(Corral(CGRect(x: 0, y: 200, width: 400, height: 300)))
        let inner = h.dot(100, 300)
        h.editor.put([inner], in: corral)
        let card = h.add(Card(CGRect(x: 600, y: 0, width: 100, height: 60)))
        h.editor.selectedShapeIDs = [lone]
        expect(!h.editor.canPerform(.openSelection), "the selection, a lone box, opens nothing")
        expect(h.editor.canPerform(.openSelection, on: [west, east]), "a group whole")
        expect(h.editor.canPerform(.openSelection, on: [corral]), "a container alone")
        expect(h.editor.canPerform(.openSelection, on: [card]), "a shape that opens, by editing")
        expect(!h.editor.canPerform(.openSelection, on: [west]), "a part of a group, alone, is no group")
        expect(!h.editor.canPerform(.openSelection, on: [west, lone]), "several that are no group")
        expect(!h.editor.canPerform(.openSelection, on: [card, corral]), "nor several that would open alone")
        expect(h.editor.perform(.openSelection, on: [west, east]))
        expectEqual(h.editor.selectedShapeIDs, [west], "the group's first part")
        expectEqual(h.editor.selectionFocus, ["g"])
        expect(h.editor.canPerform(.openSelection, on: [west, east]), "the group whole, though the selection is inside it")
        expect(h.editor.perform(.openSelection, on: [corral]))
        expectEqual(h.editor.selectedShapeIDs, [inner])
    },
    test("going in brings the shape selected into view if it's not, at the zoom the camera has") {
        let view = CGSize(width: 1000, height: 700)
        let h = try stepHarness(view: view)
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 6000, height: 400)))
        let far = h.dot(5500, 200, size: 100)
        h.editor.put([far], in: corral)
        h.editor.selectedShapeIDs = [corral]
        h.command(down)
        expectEqual(h.editor.selectedShapeIDs, [far])
        h.wait(200)
        expectEqual(h.editor.camera, Camera(fitting: CGRect(x: 5450, y: 150, width: 100, height: 100), in: view, inset: 100, maxZoom: 1))
    },
    test("a selection is enclosed by the group it is inside, whole, else the container its shapes are all in; selecting it steps out a level at a time") {
        let groups = GroupsFixture()
        let h = try stepHarness(groups)
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)))
        let a = h.dot(100, 100), b = h.dot(200, 100), c = h.dot(400, 100), d = h.dot(900, 100)
        h.editor.put([a, b, c], in: corral)
        groups.paths = [a: ["outer", "inner"], b: ["outer", "inner"], c: ["outer"]]
        expectEqual(h.editor.selectionEnclosure, nil, "nothing selected")
        expect(!h.editor.selectEnclosure())
        h.editor.selectedShapeIDs = [a]
        expectEqual(h.editor.selectionFocus, ["outer", "inner"])
        expectEqual(h.editor.selectionEnclosure, .group)
        expect(h.editor.selectEnclosure())
        expectEqual(h.editor.selectedShapeIDs, [a, b], "the inner group whole, as Escape selects it")
        expectEqual(h.editor.selectionFocus, ["outer"])
        expect(h.editor.selectEnclosure())
        expectEqual(h.editor.selectedShapeIDs, [a, b, c])
        expectEqual(h.editor.selectionEnclosure, .container(corral), "no group is left: the container its shapes are in")
        expect(h.editor.selectEnclosure())
        expectEqual(h.editor.selectedShapeIDs, [corral])
        expectEqual(h.editor.selectionEnclosure, nil)
        expect(!h.editor.selectEnclosure())
        h.editor.selectedShapeIDs = [a, d]
        expectEqual(h.editor.selectionEnclosure, nil, "in different places: in none")
    },
])
