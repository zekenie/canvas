import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import Neighbors
import Queries
import Selection
import TestKit
import Topology

// The hover, which is the whole reach: it lights what each light's step leads to from the
// shape and on from there, each shape at a strength of 0.6 a hop past the first times its share of the
// reach, its ring as wide as its strength says and mixed toward the canvas by it; the rest of the board
// dimmed once the pointer rests, the dim keeping each lit shape at one of three steps (or full); hop 1
// at once, the rest after the rest, a hop at a time. Every shape here is a fixture.

/// A chain on the root: A wired to B (L1), B to C (L2), C to D (L3), D to E (L4), E to F (L5); and U wired
/// to V (L6), which nothing of A's reaches.
struct Chain {
    let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID(), e = ShapeID(), f = ShapeID(), u = ShapeID(), v = ShapeID()
    let l1 = ShapeID(), l2 = ShapeID(), l3 = ShapeID(), l4 = ShapeID(), l5 = ShapeID(), l6 = ShapeID()

    var shapes: [ShapeID] { [a, b, c, d, e, f] }

    func file(adding extra: [AnyShapeRecord] = []) -> CanvasFile {
        let boxes = shapes.enumerated().map { box($1, at: CGPoint(x: CGFloat($0) * 200, y: 100)) }
        return CanvasFile(root: CanvasDocument(shapes: boxes + [box(u, at: CGPoint(x: 0, y: 500)), box(v, at: CGPoint(x: 200, y: 500)),
                                                                 link(l1, a, b), link(l2, b, c), link(l3, c, d), link(l4, d, e), link(l5, e, f),
                                                                 link(l6, u, v)] + extra))
    }
}

/// One group of rings as the reach draws it: its light, ring, strength (from its width) and shapes.
struct Ring: Hashable, CustomStringConvertible {
    let light: Light
    let ring: Int
    let strength: Double
    let shapes: Set<ShapeID>

    init(_ light: Light, _ ring: Int, _ strength: Double, _ shapes: Set<ShapeID>) {
        self.light = light
        self.ring = ring
        self.strength = strength
        self.shapes = shapes
    }

    var description: String { "\(light) ring \(ring) at \(strength): \(shapes.map { String($0.description.prefix(4)) }.sorted())" }
}

extension EditorHarness {
    /// What the canvas rings now, groups of one light, ring and strength joined.
    var rings: Set<Ring> {
        var joined: [Ring: Set<ShapeID>] = [:]
        for group in editor.outlines.tinted {
            let width = group.width ?? 2
            let strength = (((width - 1) / 2.5) * 40).rounded() / 40
            let key = Ring(Self.light(of: group.color), group.ring, Double(strength), [])
            joined[key, default: []].formUnion(group.shapes)
        }
        return Set(joined.map { Ring($0.light, $0.ring, $0.strength, $1) })
    }

    /// The dim's focus, rounded to hundredths; nil while the board isn't dimmed.
    var focus: [ShapeID: Double]? {
        editor.outlines.dim.map { $0.focus.mapValues { (Double($0) * 100).rounded() / 100 } }
    }

    /// Which light a ring's color is mixed from: the channels that stand above the canvas's gray.
    private static func light(of color: NSColor) -> Light {
        var rgb: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            rgb = (c.redComponent, c.greenComponent, c.blueComponent)
        }
        let low = min(rgb.0, rgb.1, rgb.2) + 0.01
        switch (rgb.0 > low, rgb.1 > low, rgb.2 > low) {
        case (false, true, false): return .out
        case (true, false, false): return .into
        case (false, true, true): return .quotes
        default: return .quoted
        }
    }
}

@MainActor let reachTests = Suite("Neighbors: the whole reach", [
    test("a chain: hop 1 at once at full strength with no dim, then once rested each hop 60% of the one before, the arrows at what they reach") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.settle()
        expectEqual(h.rings, [Ring(.out, 0, 1, [chain.b, chain.l1])], "hop 1 alone, at once")
        expect(h.focus == nil, "no dim before the pointer rests")
        h.wait(149)
        expect(h.focus == nil)
        h.wait(1)
        expect(h.reach.dims)
        expectEqual(h.rings, [Ring(.out, 0, 1, [chain.b, chain.l1]), Ring(.out, 0, 0.6, [chain.c, chain.l2]),
                              Ring(.out, 0, 0.35, [chain.d, chain.l3]), Ring(.out, 0, 0.225, [chain.e, chain.l4]),
                              Ring(.out, 0, 0.125, [chain.f, chain.l5])])
        expectEqual(h.focus, [chain.a: 1, chain.b: 1, chain.l1: 1, chain.c: 0.65, chain.l2: 0.65, chain.d: 0.35, chain.l3: 0.35,
                              chain.e: 0.12, chain.l4: 0.12, chain.f: 0.12, chain.l5: 0.12],
                    "the shape, then each lit one at the nearest of three steps; U and V dim")
        let widths = Set(h.editor.outlines.tinted.compactMap(\.width))
        expectEqual(widths, [3.5, 2.5, 1.875, 1.5625, 1.3125], "1 + 2.5 × strength")
    },
    test("a ring's color is the light's mixed toward the canvas by its strength, opaque, in either appearance") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        let faded = try require(h.editor.outlines.tinted.first { $0.shapes.contains(chain.c) }).color
        for (name, ground) in [(NSAppearance.Name.aqua, 0.965), (.darkAqua, 0.11)] {
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                let c = faded.usingColorSpace(.sRGB)!
                expectEqual(c.alphaComponent, 1)
                expect(abs(c.redComponent - ground * 0.4) < 0.01, "red is the canvas's, 40% of it")
                expect(abs(c.greenComponent - (0.6 + ground * 0.4)) < 0.01, "green 60% of the way to the light's")
            }
        }
    },
    test("a fan splits its share among what it reaches, and two ways in add up, never past the hop") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), d = ShapeID()
        let fan = (0..<5).map { _ in ShapeID() }
        let records = [box(a), box(b), box(c), box(d)] + fan.map { box($0) }
            + [link(ShapeID(), a, b), link(ShapeID(), a, c), link(ShapeID(), b, d), link(ShapeID(), c, d)]
            + fan.map { link(ShapeID(), d, $0) }
        let h = try neighborHarness(CanvasFile(root: CanvasDocument(shapes: records)))
        h.editor.hovered = a
        h.settle()
        h.wait(150)
        let strength = { (shape: ShapeID) in h.rings.first { $0.shapes.contains(shape) }?.strength }
        expectEqual(strength(b), 1)
        expectEqual(strength(d), 0.6, "B and C each pass all of theirs to D: a share of 2, held at 1")
        expectEqual(strength(fan[0]), 0.15, "D's share of 2 split five ways: 0.36 × 0.4 at hop 3")
    },
    test("a ring under 4% is left out, and its shape sinks into the dim") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        let far = (0..<20).map { _ in ShapeID() }
        let records = [box(a), box(b), box(c)] + far.map { box($0) } + [link(ShapeID(), a, b), link(ShapeID(), b, c)]
            + far.map { link(ShapeID(), c, $0) }
        let h = try neighborHarness(CanvasFile(root: CanvasDocument(shapes: records)))
        h.editor.hovered = a
        h.settle()
        h.wait(150)
        let lit = h.rings.reduce(into: Set<ShapeID>()) { $0.formUnion($1.shapes) }
        expect(lit.contains(c))
        expect(lit.isDisjoint(with: far), "0.36 × 1/20 is under 0.04")
        expect(Set(h.focus?.keys ?? [:].keys).isDisjoint(with: far))
    },
    test("an arrow the reach travels is lit, one it spares is kept by the dim untinted at its weaker end, and every other arrow dims") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), u = ShapeID()
        let ab = ShapeID(), bc = ShapeID(), back = ShapeID(), other = ShapeID()
        let file = CanvasFile(root: board(box(a), box(b), box(c), box(u), link(ab, a, b), link(bc, b, c), link(back, c, b), link(other, u, c)))
        let h = try neighborHarness(file)
        h.editor.hovered = a
        h.settle()
        h.wait(150)
        let lit = h.rings.reduce(into: Set<ShapeID>()) { $0.formUnion($1.shapes) }
        expectEqual(lit, [b, ab, c, bc])
        expectEqual(h.focus?[back], 0.35, "C back to B: kept at C's strength (0.6), but never above the second step")
        expectEqual(h.focus?[other], nil, "U's arrow to C dims")
        expectEqual(h.focus?[u], nil)
        expectEqual(h.focus?[a], 1, "the shape hovered, never lit")
        expect(!lit.contains(a), "a cycle never lights the shape hovered")
    },
    test("an arrow between two shapes of one hop is kept no brighter than the second step, however near its ends") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        let ab = ShapeID(), ac = ShapeID(), bc = ShapeID()
        let h = try neighborHarness(CanvasFile(root: board(box(a), box(b), box(c), link(ab, a, b), link(ac, a, c), link(bc, b, c))))
        h.editor.hovered = a
        h.settle()
        h.wait(150)
        expectEqual(h.focus?[b], 1)
        expectEqual(h.focus?[c], 1)
        expectEqual(h.focus?[bc], 0.35, "B and C are both hop 1, and the reach didn't travel B to C")
    },
    test("a shape that reaches nothing leaves the board as it is, rested or not") {
        let chain = Chain(), lone = ShapeID()
        let h = try neighborHarness(chain.file(adding: [box(lone, at: CGPoint(x: 800, y: 500))]))
        h.editor.hovered = lone
        h.settle()
        expect(h.rings.isEmpty)
        expectEqual(h.focus, nil)
        h.wait(150)
        expect(h.rings.isEmpty)
        expectEqual(h.focus, nil, "nothing lit, so nothing to pick out: the board doesn't dim")
    },
    test("an editor let go while its answers are on their way goes, its reach state with it, and nothing lands on it") {
        let chain = Chain()
        weak var state: ReachState?
        weak var editor: CanvasEditor?
        try autoreleasepool {
            let h = try neighborHarness(chain.file())
            h.editor.hovered = chain.a
            h.wait(0)
            expect(h.reach.isAsking, "both asks are out")
            state = h.reach
            editor = h.editor
        }
        spinRunLoop(until: { state == nil && editor == nil })
        expect(state == nil, "no task holds the state past its editor")
        expect(editor == nil)
    },
    test("a card lights at the strongest of what it holds, and the card of a shape hovered elsewhere is kept by the dim, never lit") {
        let nest = Nest()
        let h = try neighborHarness(nest.file)
        h.editor.hovered = nest.s
        h.settle()
        h.wait(150)
        // S wires to X (on P's board, hop 1) and to Y (on Q's board in P's, hop 1); X wires on to Z (hop 2).
        expectEqual(h.rings, [Ring(.out, 0, 1, [nest.p, nest.l, nest.l2])])
        expectEqual(h.focus?[nest.p], 1)
        h.editor.hovered = nil
        h.wait(150)
        expect(h.focus == nil, "let go of")
        h.editor.hoveredElsewhere = nest.x
        h.settle()
        h.wait(150)
        expectEqual(h.focus?[nest.p], 1, "where X is drawn on the board shown")
        expect(h.rings.allSatisfy { !$0.shapes.contains(nest.p) }, "never lit: Selection outlines it faintly")
    },
    test("a pill the reach goes into lights at what it stands for, and one that only stands for a lit shape elsewhere doesn't") {
        let a = ShapeID(), b = ShapeID(), into = ShapeID(), elsewhere = ShapeID(), l = ShapeID()
        let file = CanvasFile(root: board(box(a), box(b, at: CGPoint(x: 900, y: 900)), pill(into, standingFor: [b], at: CGPoint(x: 300, y: 0)),
                                          pill(elsewhere, standingFor: [b], at: CGPoint(x: 600, y: 0)), link(l, a, into)))
        let h = try neighborHarness(file)
        h.editor.hovered = a
        h.settle()
        h.wait(150)
        let lit = h.rings.reduce(into: Set<ShapeID>()) { $0.formUnion($1.shapes) }
        expect(lit.isSuperset(of: [b, into, l]), "the pill gone into and what it stands for, at hop 1")
        expect(!lit.contains(elsewhere))
        expectEqual(h.focus?[into], 1)
        expectEqual(h.focus?[elsewhere], nil)
    },
    test("a sweep keeps the dim and shows each shape's hop 1 until it rests; with nothing hovered the dim and the lights go after the release") {
        let chain = Chain()
        let h = try neighborHarness(chain.file(), lights: keyedLights())
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        expect(h.reach.dims)
        h.editor.hovered = chain.c
        h.settle()
        expect(h.reach.dims, "the dim stays from shape to shape")
        expectEqual(h.rings, [Ring(.out, 0, 1, [chain.d, chain.l3])], "C's hop 1 alone")
        expectEqual(h.focus, [chain.c: 1, chain.d: 1, chain.l3: 1])
        h.wait(150)
        expectEqual(h.rings.count, 3, "rested: C's whole reach, D, E and F")
        h.editor.hovered = nil
        h.wait(100)
        expectEqual(h.rings.count, 3, "lingers")
        h.wait(50)
        expectEqual(h.rings, [])
        expect(h.focus == nil)
        expect(!h.reach.dims)
    },
    test("a shape hovered again before the release keeps what it showed, asking nothing") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        let rings = h.rings
        h.editor.hovered = nil
        h.wait(100)
        h.editor.hovered = chain.a
        h.settle()
        h.wait(200)
        expectEqual(h.rings, rings)
        #if DEBUG
        expectEqual(h.reach.asked, 1)
        #endif
    },
    test("the pulse: once rested a hop arrives every 80 ms at its own strength, the fourth on together, settled by 240, and no shape is ever brighter than it is a step later") {
        let chain = Chain()
        let h = try neighborHarness(chain.file(), settings: reachSettings(pulse: true))
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        let hop1 = Ring(.out, 0, 1, [chain.b, chain.l1]), hop2 = Ring(.out, 0, 0.6, [chain.c, chain.l2])
        let hop3 = Ring(.out, 0, 0.35, [chain.d, chain.l3])
        // Each step's rings, a shape at its strongest, and the dim's focus: what a shape is drawn at as the reach comes in.
        var steps: [(rings: [ShapeID: Double], focus: [ShapeID: Double])] = []
        @MainActor func record() {
            var strongest: [ShapeID: Double] = [:]
            for ring in h.rings { for shape in ring.shapes { strongest[shape] = max(strongest[shape] ?? 0, ring.strength) } }
            steps.append((strongest, h.focus ?? [:]))
        }
        expectEqual(h.rings, [hop1], "rested: the dim, and hop 1")
        expectEqual(h.focus?[chain.c], nil)
        record()
        h.wait(80)
        expectEqual(h.rings, [hop1, hop2], "hop 2 arrives at its own strength, never as hop 1 is drawn")
        expectEqual(h.focus?[chain.c], 0.65, "and the dim keeps it at its fade from the step it arrives")
        record()
        h.wait(80)
        expectEqual(h.rings, [hop1, hop2, hop3])
        expectEqual(h.focus?[chain.d], 0.35)
        record()
        h.wait(80)
        expectEqual(h.reach.pulseStep, 3, "settled as hops 4 and on arrive, together")
        expectEqual(h.rings.count, 5)
        expectEqual(h.focus?[chain.f], 0.12)
        record()
        let settled = h.rings
        h.wait(80)
        expectEqual(h.rings, settled, "nothing comes after it")
        expectEqual(h.reach.pulseStep, 3)
        // A hop that came in at full for its step and then dropped to its own strength read as a flicker before the reach settled.
        for (before, after) in zip(steps, steps.dropFirst()) {
            for (shape, strength) in before.rings { expect(strength <= after.rings[shape] ?? 0, "\(shape) ring dimmed from \(strength)") }
            for (shape, strength) in before.focus { expect(strength <= after.focus[shape] ?? 0, "\(shape) kept dimmer from \(strength)") }
        }
    },
    test("with Reduce Motion the reach shows settled once the pointer rests") {
        let chain = Chain()
        let h = try neighborHarness(chain.file(), settings: reachSettings(pulse: false))
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        expectEqual(h.reach.pulseStep, 3)
        expectEqual(h.rings.count, 5)
    },
    test("⌥ shows the other pole's hop 1 at once and its reach after the rest, asking nothing") {
        let chain = Chain()
        let h = try neighborHarness(chain.file(), lights: keyedLights())
        h.editor.hovered = chain.c
        h.settle()
        h.wait(150)
        expectEqual(h.rings.count, 3, "downstream: D, E, F")
        h.hold(.option)
        h.wait(0)
        expectEqual(h.rings, [Ring(.into, 0, 1, [chain.b, chain.l2])], "upstream's hop 1 at once")
        expect(h.reach.dims)
        h.wait(150)
        expectEqual(h.rings, [Ring(.into, 0, 1, [chain.b, chain.l2]), Ring(.into, 0, 0.6, [chain.a, chain.l1])])
        h.hold([])
        h.wait(0)
        expectEqual(h.rings, [Ring(.out, 0, 1, [chain.d, chain.l3])])
        #if DEBUG
        expectEqual(h.reach.asked, 1, "every light was asked with the hover")
        #endif
    },
    test("shapes in two lights shown together take a ring for each") {
        let a = ShapeID(), b = ShapeID()
        let file = CanvasFile(root: board(memo(a, quoting: b), memo(b, quoting: a, at: CGPoint(x: 300, y: 0))))
        let h = try neighborHarness(file, lights: keyedLights())
        h.hold([.control, .option])
        h.editor.hovered = a
        h.settle()
        h.wait(150)
        expectEqual(h.rings, [Ring(.quotes, 0, 1, [b]), Ring(.quoted, 1, 1, [b])])
    },
    test("commits that touch the reach ask again once, 100 ms after they stop, keeping it settled") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        let g = ShapeID(), w = ShapeID()
        h.editor.transact("Add") { $0.insert(box(g, at: CGPoint(x: 1400, y: 100))) }
        h.wait(60)
        h.editor.transact("Link") { $0.insert(link(w, chain.f, g)) }
        h.wait(60)
        #if DEBUG
        expectEqual(h.reach.asked, 1, "still waiting")
        #endif
        h.wait(40)
        h.settle()
        #if DEBUG
        expectEqual(h.reach.asked, 2, "one ask for the two")
        #endif
        let lit = h.rings.reduce(into: Set<ShapeID>()) { $0.formUnion($1.shapes) }
        expect(lit.isSuperset(of: [g, w]), "G at hop 6, lit at once, settled")
        h.editor.transact("Move") { $0.moveBox(chain.u, to: CGPoint(x: 0, y: 900)) }
        h.wait(200)
        #if DEBUG
        expectEqual(h.reach.asked, 2, "a move asks nothing")
        #endif
    },
    test("each answer is landed off the main actor") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.settle()
        h.editor.hovered = chain.b
        h.settle()
        #if DEBUG
        expectEqual(h.reach.landed, 4, "a one-hop answer and a reach, for each")
        expectEqual(h.reach.landedOnMain, 0)
        expectEqual(h.reach.reachRequested, 8, "a reach request a light")
        #endif
    },
    test("a drag hides the reach and the dim, and they show again once it ends") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.settle()
        h.wait(150)
        let rings = h.rings
        h.editor.session = IdleSession()
        expectEqual(h.rings, [])
        expect(h.editor.outlines.dim == nil)
        h.editor.session = nil
        expectEqual(h.rings, rings)
        expect(h.focus != nil)
    },
    test("another board shown lets go of everything") {
        let nest = Nest()
        let h = try neighborHarness(nest.file, settings: reachSettings())
        h.editor.hovered = nest.s
        h.settle()
        h.wait(150)
        expect(h.enter(nest.p))
        h.wait(0)
        expectEqual(h.rings, [])
        expect(h.focus == nil)
        expectEqual(h.reach.showing, nil)
    },
    test("a reach that fails shows the one hop in its place: every light's when all failed, the failed light's alone otherwise") {
        // A light whose reach request is refused (the step as `:scope` names a kind that isn't one) but whose one hop works.
        func refusingScope(_ light: NeighborLight) -> NeighborLight {
            var light = light
            let query = light.query
            light.query = { $0 == ":scope" ? "chor:edge-from(:scope)" : query($0) }
            return light
        }
        let chain = Chain()
        // All failed: hop 1 stays, with the dim and no pulse.
        let all = try neighborHarness(chain.file(), lights: [refusingScope(testLights()[0])])
        all.editor.hovered = chain.a
        all.settle()
        expectEqual(all.rings, [Ring(.out, 0, 1, [chain.b, chain.l1])], "hop 1 before the rest")
        all.wait(150)
        expect(all.reach.dims)
        expectEqual(all.rings, [Ring(.out, 0, 1, [chain.b, chain.l1])], "and after, where the reach failed: not dropped")
        expect(!all.reach.hasReach)
        // One failed: its one hop, beside the other light's reach.
        var lights = testLights()
        lights[0] = refusingScope(lights[0])
        let some = try neighborHarness(chain.file(), lights: lights)
        some.editor.hovered = chain.c
        some.settle()
        some.wait(150)
        expect(some.reach.hasReach)
        let rings = some.rings
        expect(rings.contains(Ring(.out, 0, 1, [chain.d, chain.l3])), "the failed light's one hop: \(rings)")
        expect(rings.contains(Ring(.into, 0, 1, [chain.b, chain.l2])), "the other's reach, hop 1: \(rings)")
        expect(rings.contains(Ring(.into, 0, 0.6, [chain.a, chain.l1])), "and on from there: \(rings)")
    },
    test("a pill hovered lights its own arrows' far ends at hop 1 once the reach has landed, and the reach goes on from them") {
        let a = ShapeID(), b = ShapeID(), c = ShapeID(), pillID = ShapeID(), own = ShapeID(), onward = ShapeID()
        let file = CanvasFile(root: board(box(a), box(b, at: CGPoint(x: 400, y: 0)), box(c, at: CGPoint(x: 800, y: 0)),
                                          pill(pillID, standingFor: [a], at: CGPoint(x: 0, y: 400)), link(own, pillID, b), link(onward, b, c)))
        let h = try neighborHarness(file)
        h.editor.hovered = pillID
        h.settle()
        let first = h.rings.reduce(into: Set<ShapeID>()) { $0.formUnion($1.shapes) }
        expect(first.isSuperset(of: [b, own]), "its own arrow's far end at once, from the one hop")
        h.wait(150)
        let lit = h.rings.reduce(into: Set<ShapeID>()) { $0.formUnion($1.shapes) }
        expect(lit.isSuperset(of: [b, own]), "still there once the reach replaced it: \(h.rings)")
        expect(lit.isSuperset(of: [c, onward]), "and the reach on from it: \(h.rings)")
        expect(h.rings.contains { $0.strength == 1 && $0.shapes.isSuperset(of: [b, own]) }, "at hop 1")
    },
    test("an edge change while an ask is out asks again once it lands, though nothing it touched was matched and no shape was added") {
        let chain = Chain()
        let h = try neighborHarness(chain.file())
        h.editor.hovered = chain.a
        h.wait(0)
        let asked = h.reach.asked
        expect(h.reach.isAsking, "the ask is out")
        // U's wire is aimed at E, far from A and from everything its reach has met: no shape is added, none is the subject's.
        h.editor.transact("Rewire") { $0.update(chain.l6, as: Link.self) { $0.props.to = chain.e } }
        h.settle()
        h.wait(100)
        h.settle()
        expectEqual(h.reach.asked, asked + 1, "asked once more: the answer that landed may be older than the edges")
    },
])
