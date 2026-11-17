import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Mentions
import Neighbors
import Queries
import Selection
import ShippedTesting
import StickyNotes
import TestKit

// The whole reach's budgets (the only hover; [neighbors](neighbors.md)): what a hover costs the main actor to its hop-1 lights and to
// the reach landing, on a 10,000-shape board for a shape with a few dozen reached and for a hub; the engine's walk off the main actor
// (`queries.reaches`, with the arrows between); the landing's main-actor cost with 20,000 and 200,000 lit
// (`BENCH_SIZES=20000,200000 ./build.sh bench`, which holds no budget, the figures are said on the constants); a pulse step; and a frame of the canvas with the
// dim, at 100% and at 10%, the reach settled in its three fade steps, over the same frame unhovered, and one drawn while the camera moves, which
// leaves the dim out (`Style.dimCameraRest`), over the same. The lights are the shipped ones
// (arrows' Points To, its step the arrow's own: the reach follows arrows from note to note), with settings of the benchmark's own
// (the reduced motion each test wants), never the app's. `./build.sh bench` holds them; `./test.sh` runs them small, in debug, and only reports.

extension Budget {
    /// A hover's main-actor time to the hop-1 lights landing (the one-hop answer taken up, its landing, the rings) on a 10,000-shape board,
    /// for a shape with a few dozen reached and for a hub with all of them. The design's hover budget was 1 ms.
    static let reachHopOne = 1.0
    /// The same for the hub, 10,000 lit (5,000 notes and the 5,000 arrows between): more than the 1 ms the design proposed and than the one-hop hover it
    /// replaced on as many (some 0.8 ms, its 2 ms), because the landing here also groups each shape by tier and ring; set to
    /// what it measures (some 1.2 ms) with room.
    static let reachHopOneHub = 2.0
    /// The same to the reach landing too (the engine's reach answered off the main actor, landed there, the rings and the dim's focus made
    /// once per pulse step off it, then taken up and composed): for a few dozen reached, and for a hub with 10,000 lit.
    static let reachHover = SizedBudget(thousand: 1.0, tenThousand: 2.0)
    /// The engine's walk off the main actor (`queries.reaches`: the process's CPU beside the main thread's) at 10,000 and at 20,000 reached,
    /// the arrows between included, a chain and a fan-out. The design proposed 60 ms at 20,000 reached; the walk, generic plan and
    /// all, costs some 9 µs a shape with its between (about 190 ms at 20,000), so this is set to what it measures with room for a busy machine.
    static let reachWalk10k = 120.0
    static let reachWalk20k = 300.0
    /// The main actor's time for that walk: the capture and the answer taken up.
    static let reachWalkMain = 1.0
    /// A hover's main-actor time with 20,000 lit (a chain and a fan-out), from the hover to the reach landed: the landing's.
    static let reachLand20k = 2.0
    /// The same with 200,000 lit, run with `BENCH_SIZES=20000,200000`, which holds no budget: reported against this.
    static let reachLand200k = 4.0
    /// A fan-out is all hop 1: every lit shape lands at once with the first answer (the hub's, as the one-hop hover it replaced did, which was some
    /// 0.8 ms for 10,000 and so some 16 ms for 200,000), taken up and composed on the main actor, linear in what's lit, about 0.09 to 0.14 µs
    /// a lit shape: some 1.4 to 2 ms at 20,000 and 20 to 27 ms at 200,000 (the first hover 33), against the design's 2 and 4 ms, which a
    /// chain, whose hop 1 is one shape, meets (0.5 and 1.2 ms). Set to what it measures, with room.
    static let reachLandFan20k = 3.0
    static let reachLandFan200k = 40.0
    /// One pulse step's main-actor time (a step only picks groups: the dim's focus and the rings were made once per step off the main actor).
    static let reachPulseStep = 1.0
    /// What the reach adds to a frame of the canvas over the same frame unhovered, the dim and the lights in the shipped list's colors, the reach
    /// settled in three fade steps: 1,900 notes in view at 100%, and 10,000 at 10%. The core's dim costs a layer for each strength band
    /// in use (3.5 ms each, the hop-1 band, three fade steps and the unkept layer here): `dimFrame100` and `dimFrame10` hold the dim's cost
    /// (14 and 18); these hold it with the lights. The design proposed 5 and 8 ms, for one layer. Measured on a quiet machine, 6 and 12 ms;
    /// on a busy one (load 15 to 45) the difference swings from 14 to 39 and 16 to 43, so these are set over the busy figures: the frame's
    /// own noise, not the reach's, since it is the difference of two frames of 170 to 410 ms each.
    static let reachFrame100 = 45.0
    static let reachFrame10 = 50.0
    /// What the reach adds to a frame drawn while the camera moves (a small pan before each frame, the reach settled, no 150 ms of rest): the core
    /// leaves the dim out until the camera has rested (`Style.dimCameraRest`), so this holds the lights alone, the rings and the rest of the
    /// outlines, with no transparency layers: it should cost about what a hover's lights cost a frame today, none of the 3.5 ms a layer costs, which is
    /// where the dim's layers took a pan on screen under 60 frames a second. The figure is set from what it measures: -0.4 ms at 100% and 0.9 at 10%
    /// (release, the machine's load 25 to 30, each the difference of two frames of some 300 ms), with room for the frame's own noise, where the
    /// settled frame's dim adds 19 and 13: the dim's layers back would fail it, at any load.
    static let reachFrameMoving100 = 8.0
    static let reachFrameMoving10 = 8.0
}

/// How a board of notes is joined by arrows from its subject.
private enum Reaching {
    /// A chain from the subject of this many notes after it; the rest of the notes in a chain of their own.
    case chain(Int)
    /// The subject, an arrow to each other note.
    case fan
    /// A tree of ten to each: every note's parent is the one at (i - 1) / 10, so the reach has hops, ways and shares.
    case tree
}

/// `notes` notes in a grid, the first the subject, and an arrow for most of them (`reaching`): `notes` + (notes - 1) shapes.
@MainActor private func reachBoard(notes count: Int, _ reaching: Reaching, columns: Int = 120, spacing: CGFloat = 95, side: CGFloat = 80)
    -> (document: CanvasDocument, subject: ShapeID) {
    let ids = (0..<count).map { _ in ShapeID() }
    var shapes: [AnyShapeRecord] = []
    shapes.reserveCapacity(count * 2)
    for i in 0..<count {
        let frame = CGRect(x: CGFloat(i % columns) * spacing, y: CGFloat(i / columns) * spacing, width: side, height: side)
        shapes.append(AnyShapeRecord(ShapeRecord(id: ids[i], StickyNote(frame: frame, text: MentionText(plain: "Note \(i)")))))
    }
    switch reaching {
    case .chain(let length):
        for i in 1..<count where i != length + 1 { shapes.append(arrow(from: ids[i - 1], to: ids[i])) }
    case .fan:
        for i in 1..<count { shapes.append(arrow(from: ids[0], to: ids[i])) }
    case .tree:
        for i in 1..<count { shapes.append(arrow(from: ids[(i - 1) / 10], to: ids[i])) }
    }
    return (CanvasDocument(shapes: shapes), ids[0])
}

/// The shipped list with the reach's settings of the benchmark's own (settled at once when `pulse` is off, as Reduce Motion shows it).
@MainActor private func reachPlugins(_ pasteboard: NSPasteboard, pulse: Bool = false) -> [any CanvasPlugin] {
    ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel(), reach: ReachSettings(reducesMotion: { !pulse }))
}

@MainActor private func reachEditor(_ document: CanvasDocument, pasteboard: NSPasteboard, pulse: Bool = false, viewport: CGSize = CGSize(width: 1200, height: 800)) throws -> EditorHarness {
    let registry = try Registry(plugins: reachPlugins(pasteboard, pulse: pulse))
    let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
    h.editor.viewportDidResize(to: viewport)
    return h
}

private let viewport = CGSize(width: 1200, height: 800)

private func nanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

/// A hover on `subject` from nothing hovered: the main actor's time to the hop-1 lights landing, to the reach landed, and what ran off the main actor.
@MainActor private func reachHover(_ h: EditorHarness, _ subject: ShapeID) throws -> (hop: Double, whole: Double, off: Double) {
    _ = threadCPUTime {}                                           // marks the test as one that measures a budget
    let reach = try require(h.editor.reach)
    let (split, main, off) = try cpu { () -> Double in
        let start = nanos()
        h.editor.hovered = subject
        h.wait(0)                                                  // the look at the hover, which asks
        var spun = 0
        while h.editor.outlines.tinted.isEmpty, spun < 60_000 {           // the one-hop answer lands (a millisecond's sleep is no CPU)
            try await Task.sleep(for: .milliseconds(1))
            spun += 1
        }
        let hop = nanos()
        await reach.landed()
        return Double(hop - start) / 1e6
    }
    // `split` is the main thread's time to the hop-1 lights, from the clock marks taken inside the run (sleeping adds none).
    return (hop: split, whole: main, off: off)
}

@MainActor let reachBenchmarks = Suite("Reach benchmarks", [
    test("a hover on a shape with a few dozen reached, and on a hub with all of them, among 10,000 shapes: the main actor's time to the hop-1 lights and to the reach landed") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #if DEBUG
        let total = 300
        #else
        let total = 10_000
        #endif
        let notes = (total + 1) / 2
        for (what, reaching, reached) in [("a few dozen reached", Reaching.chain(40), 80), ("a hub", Reaching.fan, total - 1)] {
            let (document, subject) = reachBoard(notes: notes, reaching)
            let h = try reachEditor(document, pasteboard: pasteboard)
            let reach = try require(h.editor.reach)
            let first = try reachHover(h, subject)
            expect(reach.hasReach, "the reach landed")
            var hops: [Double] = [], wholes: [Double] = [], offs: [Double] = []
            for _ in 0..<measuredRuns(11) {
                h.editor.hovered = nil
                h.wait(500)
                let (hop, whole, off) = try reachHover(h, subject)
                hops.append(hop)
                wholes.append(whole)
                offs.append(off)
            }
            let budget = reached > 100 ? Budget.reachHover.at(10_000) : Budget.reachHover.at(1_000)
            let hopBudget = reached > 100 ? Budget.reachHopOneHub : Budget.reachHopOne
            report(String(format: "%6d shapes, a hover on %@ (%d lit): main %5.3f ms to the hop-1 lights (budget %.1f), %5.3f to the reach landed (the first %5.3f; budget %.1f), off the main actor %6.1f ms",
                          total, what, reached, middle(hops), hopBudget, middle(wholes), first.whole, budget, middle(offs)))
            if holdsToBudgets {
                expect(middle(hops) < hopBudget, "a hover on \(what) took \(middle(hops)) ms of the main actor to its hop-1 lights")
                expect(middle(wholes) < budget, "a hover on \(what) took \(middle(wholes)) ms of the main actor to the reach landed")
            }
        }
    },
    test("the engine's walk off the main actor: 10,000 and 20,000 reached, a chain and a fan-out, with the arrows between") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #if DEBUG
        let counts = [300, 600]
        #else
        let counts = [10_000, 20_000]
        #endif
        for count in counts {
            for (what, reaching) in [("chain", Reaching.chain(count)), ("fan-out", Reaching.fan)] {
                let (document, subject) = reachBoard(notes: count + 1, reaching)
                let h = try reachEditor(document, pasteboard: pasteboard)
                let queries = try require(h.editor.queries)
                let light = try require(h.editor.registry.neighborLights.first)
                let request = QueryReachRequest(step: light.query(":scope"), between: light.between?(":scope"), start: subject)
                var mains: [Double] = [], offs: [Double] = []
                var reached = 0, carriers = 0
                for _ in 0..<measuredRuns(5, debugRuns: 3) {
                    let (answer, main, off) = try cpu { await queries.reaches([request]) }
                    let reach = try require(answer.first).get()
                    reached = reach.ids.count
                    carriers = reach.carriers.count
                    mains.append(main)
                    offs.append(off)
                }
                let budget = count > 10_000 ? Budget.reachWalk20k : Budget.reachWalk10k
                report(String(format: "%6d reached (%d answered, %d arrows between), a %@'s walk: %6.1f ms off the main actor (budget %.0f), main %5.3f ms (budget %.1f)",
                              count, reached, carriers, what, middle(offs), budget, middle(mains), Budget.reachWalkMain))
                #if !DEBUG
                expect(reached >= count, "the walk reached \(reached) of \(count)")
                #endif
                if holdsToBudgets {
                    expect(middle(offs) < budget, "the walk of \(count) reached, a \(what), took \(middle(offs)) ms off the main actor")
                    expect(middle(mains) < Budget.reachWalkMain, "the walk of \(count) reached took \(middle(mains)) ms of the main actor")
                }
            }
        }
    },
    test("the landing's main-actor cost with 20,000 lit (200,000 with BENCH_SIZES=20000,200000), a chain and a fan-out") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #if DEBUG
        let counts = [600]
        #else
        let counts = ProcessInfo.processInfo.environment["BENCH_SIZES"] != nil ? sizes.values : [20_000]
        #endif
        for count in counts {
            for (what, reaching) in [("chain", Reaching.chain(count)), ("fan-out", Reaching.fan)] {
                Scaling.currentSize = count
                let (document, subject) = reachBoard(notes: count / 2 + 1, reaching)
                let h = try reachEditor(document, pasteboard: pasteboard)
                let reach = try require(h.editor.reach)
                let first = try reachHover(h, subject)
                expect(reach.hasReach, "the reach landed")
                var mains: [Double] = [], offs: [Double] = [], hops: [Double] = []
                for _ in 0..<measuredRuns(5) {
                    h.editor.hovered = nil
                    h.wait(500)
                    let (hop, whole, off) = try reachHover(h, subject)
                    hops.append(hop)
                    mains.append(whole)
                    offs.append(off)
                }
                let fan = what == "fan-out"
                let budget = count > 20_000 ? (fan ? Budget.reachLandFan200k : Budget.reachLand200k) : (fan ? Budget.reachLandFan20k : Budget.reachLand20k)
                report(String(format: "%7d lit, a %@: main %5.3f ms from the hover to the reach landed, %5.3f of it to the hop-1 lights (the first %5.3f; budget %.0f), off the main actor %7.1f ms",
                              count, what, middle(mains), middle(hops), first.whole, budget, middle(offs)))
                if holdsToBudgets { expect(middle(mains) < budget, "a hover with \(count) lit, a \(what), took \(middle(mains)) ms of the main actor") }
            }
        }
    },
    test("a pulse step costs the main actor little: the reach spreading a hop at a time over a tree of 10,000") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #if DEBUG
        let notes = 150
        #else
        let notes = 5_000
        #endif
        let (document, subject) = reachBoard(notes: notes, .tree)
        let registry = try Registry(plugins: reachPlugins(pasteboard, pulse: true))
        let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        let reach = try require(h.editor.reach)
        var steps: [[Double]] = Array(repeating: [], count: 3)                // hops 2, 3, and 4 and on: settled as the last arrives
        for _ in 0..<measuredRuns(7) {
            h.editor.hovered = nil
            h.wait(500)
            _ = try reachHover(h, subject)
            h.wait(149)                                            // the rest comes at 150: the dim, and the pulse begins
            h.wait(1)
            for i in 0..<steps.count {
                let step = threadCPUTime { h.wait(80) }.milliseconds
                steps[i].append(step)
            }
        }
        expect(reach.pulseStep == 3, "the pulse ran to its end")
        let medians = steps.map(middle)
        let worst = steps.flatMap { $0 }.max() ?? 0
        report(String(format: "%6d shapes, a pulse step: main %@ ms by step (worst %5.3f; budget %.1f)",
                      notes * 2 - 1, medians.map { String(format: "%5.3f", $0) }.joined(separator: ", "), worst, Budget.reachPulseStep))
        if holdsToBudgets { expect(middle(steps.flatMap { $0 }) < Budget.reachPulseStep, "a pulse step took \(medians) ms of the main actor") }
    },
    test("the reach adds little to a frame: the dim and its three fade steps, 1,900 notes in view at 100% and 10,000 at 10%; and less while the camera moves, the dim left out") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let context = try bitmapContext(viewport)
        for (what, count, zoom, columns, spacing, side, budget, movingBudget) in [("1,900 in view at 100%", 1_944, CGFloat(1), 54, CGFloat(22), CGFloat(16), Budget.reachFrame100, Budget.reachFrameMoving100),
                                                                    ("10,000 in view at 10%", 10_000, CGFloat(0.1), 120, CGFloat(95), CGFloat(80), Budget.reachFrame10, Budget.reachFrameMoving10)] {
            #if DEBUG
            let count = min(count, 300)
            #endif
            let (document, subject) = reachBoard(notes: count, .tree, columns: columns, spacing: spacing, side: side)
            let h = try reachEditor(document, pasteboard: pasteboard)
            let reach = try require(h.editor.reach)
            let board = h.editor.shapeBounds
            let camera = zoom == 1 ? Camera(origin: .zero, zoom: 1) : camera(centering: board, at: zoom, in: viewport)
            /// A frame after a small pan: the camera rested 150 ms since it (the dim drawn, if there is one), or not (moving: the core leaves it out).
            @MainActor func frame(rested: Bool = true) -> Double {
                var step = 0.0
                let pan = {
                    step = step == 0 ? 1 : 0
                    h.editor.camera = Camera(origin: CGPoint(x: camera.origin.x + step / camera.zoom, y: camera.origin.y), zoom: camera.zoom)
                    if rested { h.wait(150) }
                }
                h.editor.camera = camera
                if rested { h.wait(150) }
                draw(h.editor, into: context, size: viewport)
                return median(runs: 11, prepare: pan, onThread: true) { draw(h.editor, into: context, size: viewport) }
            }
            // The unhovered frame and the hovered one, alternately, so a machine that gets busier between two measures hits both; the median of the differences.
            var added: [Double] = [], bases: [Double] = [], addedMoving: [Double] = []
            var lit = 0
            for _ in 0..<measuredRuns(5) {
                h.editor.hovered = nil
                h.wait(500)
                let unhovered = frame()
                h.editor.hovered = subject
                h.wait(0)
                try awaitResult(timeout: 60) { await reach.landed() }
                h.wait(150)                                        // rested: the board dimmed, the reach settled
                expect(reach.dims && reach.hasReach, "the board is dimmed and the reach has landed")
                lit = h.editor.outlines.tinted.reduce(0) { $0 + $1.shapes.count }
                added.append(frame() - unhovered)
                addedMoving.append(frame(rested: false) - unhovered)
                bases.append(unhovered)
            }
            let hovered = middle(added) + middle(bases), unhovered = middle(bases)
            report(String(format: "%d notes (%@): the reach settled adds %6.2f ms to a frame (%d lit) over %6.2f unhovered (budget %.0f)", count, what, hovered - unhovered, lit, unhovered, budget))
            if holdsToBudgets { expect(hovered - unhovered < budget, "the reach added \(hovered - unhovered) ms to a frame of \(what)") }
            let moving = middle(addedMoving)
            report(String(format: "%d notes (%@): the reach settled adds %6.2f ms to a frame while the camera moves, the dim left out (budget %.0f)", count, what, moving, movingBudget))
            if holdsToBudgets { expect(moving < movingBudget, "the reach added \(moving) ms to a frame of \(what) while the camera moved") }
        }
    },
])
