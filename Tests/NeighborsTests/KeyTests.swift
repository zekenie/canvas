import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Neighbors
import Queries
import Selection
import TestKit

// Which lights a hover shows: those whose keys are the ones held (of the keys some light names), as the
// shipped lights are shown, what it points to on a plain hover, what points to it with ⌥, mentions with
// ⌃⌥. Every light is asked once a hover, so a key pressed or let go only shows another part of the answer.

@MainActor let keyTests = Suite("Neighbors: the keys held choose the lights", [
    test("a plain hover shows the lights that name no key, ⌥ those that name ⌥, ⌃⌥ those that name both; a key changes them with nothing asked") {
        let star = Star()
        let h = try neighborHarness(star.file(), lights: keyedLights())
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1])])
        h.hold(.option)
        h.wait(0)
        expectEqual(h.lit, [Lit(.into, 0, [star.c, star.l2])], "what has a wire to it, with no move of the pointer")
        h.hold([.control, .option])
        h.wait(0)
        expectEqual(h.lit, [Lit(.quotes, 0, [star.q]), Lit(.quoted, 0, [star.m])])
        h.hold([])
        h.wait(0)
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1])], "let go: the plain hover's again")
        #if DEBUG
        expectEqual(h.neighbors.asked, 1, "one ask for the hover: the keys only show another part of its answer")
        expectEqual(h.neighbors.placed, 4)
        #endif
    },
    test("a key no light names changes nothing (⇧ for a click that adds, ⌘), and keys that name no light show none") {
        let star = Star()
        let h = try neighborHarness(star.file(), lights: keyedLights())
        h.editor.hovered = star.s
        h.settle()
        h.hold(.shift)
        h.wait(0)
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1])])
        h.hold(.command)
        h.wait(0)
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l1])])
        h.hold([.shift, .option])
        h.wait(0)
        expectEqual(h.lit, [Lit(.into, 0, [star.c, star.l2])])
        h.hold(.control)
        h.wait(0)
        expectEqual(h.lit, [], "⌃ alone is no light's")
        // Lights that name no key show whatever is held.
        let plain = try neighborHarness(star.file())
        plain.hold(.option)
        plain.editor.hovered = star.s
        plain.settle()
        expectEqual(plain.lit.count, 4)
    },
    test("keys held as the hover lands, from the window wherever the keyboard is, and with the pointer, all choose") {
        let star = Star()
        let h = try neighborHarness(star.file(), lights: keyedLights())
        h.hold(.option)
        h.editor.hovered = star.b
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [star.s, star.u, star.l1, star.l3])], "held before the hover")
        h.hold([])
        h.wait(0)
        expectEqual(h.lit, [], "B has a wire to nothing")
        // A change the window hears while a panel's field or the table of contents has the keyboard.
        h.editor.modifiersChangedInWindow(held: .option)
        h.wait(0)
        expectEqual(h.lit, [Lit(.into, 0, [star.s, star.u, star.l1, star.l3])])
        h.editor.modifiersChangedInWindow(held: [])
        h.wait(0)
        // The pointer onto S with ⌥ held: the move says the keys as it hovers the shape.
        h.editor.pointerMoved(PointerEvent(location: CGPoint(x: 410, y: 310), timestamp: h.time + 0.016, modifiers: .option, clickCount: 0))
        h.settle()
        expectEqual(h.editor.hovered, star.s)
        expectEqual(h.lit, [Lit(.into, 0, [star.c, star.l2])])
    },
    test("rings count the lights shown: a shape in a light that isn't shown takes no ring") {
        let star = Star()
        let extra = link(ShapeID(), star.s, star.c)                       // S has a wire to C, which has one to S
        let h = try neighborHarness(star.file(adding: [extra]), lights: keyedLights())
        h.editor.hovered = star.s
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.c, star.l1, extra.id])])
        h.hold(.option)
        h.wait(0)
        expectEqual(h.lit, [Lit(.into, 0, [star.c, star.l2])], "C in the first ring, as the only light shown")
        // Two memos that quote each other: both of ⌃⌥'s lights, a ring each.
        let a = ShapeID(), b = ShapeID()
        let quotes = try neighborHarness(CanvasFile(root: board(memo(a, quoting: b), memo(b, quoting: a, at: CGPoint(x: 300, y: 0)))),
                                         lights: keyedLights())
        quotes.hold([.control, .option])
        quotes.editor.hovered = a
        quotes.settle()
        expectEqual(quotes.lit, [Lit(.quotes, 0, [b]), Lit(.quoted, 1, [b])])
    },
    test("a commit with a key held shows the new answer's lights for those keys; keys with nothing hovered work nothing out") {
        let star = Star()
        let h = try neighborHarness(star.file(), lights: keyedLights())
        #if DEBUG
        h.hold(.option)
        h.wait(0)
        h.hold([])
        h.wait(0)
        expectEqual(h.neighbors.placed, 0, "nothing hovered")
        #endif
        h.editor.hovered = star.s
        h.hold(.option)
        h.settle()
        let added = ShapeID()
        h.editor.transact("Link") { $0.insert(link(added, star.u, star.s)) }
        h.settle()
        expectEqual(h.lit, [Lit(.into, 0, [star.c, star.u, star.l2, added])])
    },
    test("the canvas is asked to draw only when a key changes what's shown") {
        let star = Star()
        let h = try neighborHarness(star.file(), lights: keyedLights())
        let redraws = Redraws()
        h.editor.delegate = redraws
        h.editor.hovered = star.u                          // a wire to B, and nothing else
        h.settle()
        expectEqual(h.lit, [Lit(.out, 0, [star.b, star.l3])])
        var drawn = redraws.count
        h.hold([.control, .option])
        h.wait(0)
        expectEqual(h.lit, [])
        expectEqual(redraws.count, drawn + 1, "the lights went")
        drawn = redraws.count
        h.hold(.option)
        h.wait(0)
        expectEqual(h.lit, [])
        expectEqual(redraws.count, drawn, "nothing shown for ⌥ either: nothing to draw")
    },
    test("a light's keys are the plugin's to say, kept in plugin order with the light") {
        let lights = keyedLights()
        let registry = try Registry(plugins: [NeighborsPlugin(), lightsPlugin(lights)])
        expectEqual(registry.neighborLights.map(\.keys), [[], .option, [.control, .option], [.control, .option]])
        expectEqual(NeighborLight("Plain", color: .black, query: { $0 }).keys, [], "none, a plain hover, unless said")
    },
])
