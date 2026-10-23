import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import LanguageModels
import Queries
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Topology

// Topology's forwarding through stand-ins, on generated boards (`StandInBenchmarks.swift`): its index
// built as a file with stand-ins opens, what's connected to a shape through 100 of them, a stand-in
// with 100 arrows re-pointed, a drag with 50 stand-ins for what's provided costing nothing more, a
// commit while a query holds the file among 500 stand-ins, a provide that fans out, and an answer
// prepared off the main actor for a lens of every note. No shipped
// kind stands in yet, so the stand-ins are this file's: a mirror stands for the shapes its record
// names (`Forwarding.shapes`), a lens for what's provided for what it asks (`Forwarding.provided`).

extension Budget {
    /// Topology's index of a file with stand-ins, built as it opens: 100 mirrors of one note at
    /// 10,000 shapes, 1,000 arrows into them. Within the index's (and Mentions' catalog's) budget.
    static let topologyOpenStandIns = mentionIndex10k
    /// What's connected to a shape 100 arrows reach through 100 stand-ins: what it returns.
    static let neighborsThroughStandIn = neighbors100
    /// Re-pointing a stand-in 100 arrows end at: the commit, on the main actor.
    static let repointStandIn = 1.0
    /// What a drag event's input costs more with 50 stand-ins for what's provided among the shapes
    /// dragged, against the same shapes standing for nothing: nothing, since a move reads nothing.
    static let standInDragUpkeep = queryUpkeep
    /// What a commit adding an arrow into a stand-in costs more while a query holds the file, among
    /// 500 stand-ins: the tables it shares, each copied once, as `queryHeldCommit`.
    static let heldCommitStandIns = queryHeldCommit
    /// A provide that fans out, on the main actor, outside any gesture: a lens with 100 arrows whose
    /// answer changes from 50 shapes to 50 others, and one whose arrow to another lens is 2,500
    /// pairs. Forwarded on read, no copy is made or kept: it costs what came and went (100 shapes
    /// and the ends they touch), not those times the arrows: release, 2026-10-22, 0.65 ms at either
    /// size, where making the copies was some 6. A frame, so it costs the window none.
    static let provideFanOut = frame
    /// An answer for a lens of every note of the board (100 arrows into it) that adds or drops one
    /// note, worked out off the main actor (`TopologyIndex.preparer()`) and taken in on it: what came
    /// and went, and the arrows at the lens, never the notes. The thread's CPU time; the same answer
    /// worked out on the main actor, every note looked at, is reported beside it. Release,
    /// 2026-10-22: 0.07 ms at 695 notes and at 6,956 (0.003 for the same shapes again), against 0.5
    /// and 3.2 worked out on the main actor.
    static let preparedProvide = 1.0
}

/// Stands for the shapes its record names.
struct Mirror: BoxShapeProps {
    static let kind: ShapeKind = "bench-mirror"
    static let properties = Properties<Mirror> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
}

extension Mirror {
    init() { self.init(.zero) }
}

/// Stands for what's provided for what it asks.
struct Lens: BoxShapeProps {
    static let kind: ShapeKind = "bench-lens"
    static let properties = Properties<Lens> {
        Property("frame", \.frame).required()
        Property("asks", \.asks)
    }
    var frame: CGRect
    var asks: String
    init(_ frame: CGRect, asks: String = "") {
        self.frame = frame
        self.asks = asks
    }
}

extension Lens {
    init() { self.init(.zero) }
}

struct MirrorDefinition {}

extension MirrorDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Mirror>, in context: RenderContext) {}
}

struct LensDefinition {}

extension LensDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {}
}

/// Mirrors and lenses; `plain`, the same kinds standing for nothing (what a stand-in costs is
/// measured against them).
struct StandInBenchPlugin: CanvasPlugin {
    var plain = false
    var id: PluginID { "bench-stand-ins" }

    func register(into registrar: inout PluginRegistrar) {
        let plain = plain
        registrar.shape(MirrorDefinition()) { mirror in
            if !plain { mirror.standsIn { shape, _ in .shapes(shape.props.stands.map(\.shape)) } }
        }
        registrar.shape(LensDefinition()) { lens in
            if !plain { lens.standsIn { shape, _ in .provided(ForwardingKey(shape.props.asks)) } }
        }
    }
}

private let standInBox = CGRect(x: -2_000, y: -2_000, width: 160, height: 40)

func mirror(_ id: ShapeID = ShapeID(), standing targets: [ShapeID]) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Mirror(standInBox, stands: targets.map(Citation.init))))
}

func lens(_ id: ShapeID = ShapeID(), asks: String, at origin: CGPoint = standInBox.origin) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Lens(CGRect(origin: origin, size: standInBox.size), asks: asks)))
}

/// The generated board's notes, in its order.
@MainActor func notes(of document: CanvasDocument) -> [ShapeID] { document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id) }

/// Times one service's making as an editor is made, on the main thread's CPU: a service made just
/// before it reads the thread's clock, and one made just after reads it again.
@MainActor final class ThreadStopwatch {
    var started: UInt64?
    var ended: UInt64?
    var milliseconds: Double { started.flatMap { start in ended.map { Double($0 - start) / 1e6 } } ?? .nan }
}

@MainActor final class ThreadStopwatchStart {
    init(_ watch: ThreadStopwatch) { watch.started = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}

extension ThreadStopwatchStart: EditorService {}

@MainActor final class ThreadStopwatchEnd {
    init(_ watch: ThreadStopwatch) { watch.ended = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }
}

extension ThreadStopwatchEnd: EditorService {}

/// The shipped plugins and the bench's stand-ins, with a stopwatch around Topology's service.
@MainActor func pluginsTimingTopology(_ watch: ThreadStopwatch, _ pasteboard: NSPasteboard, plain: Bool) -> [any CanvasPlugin] {
    var plugins = shippedPlugins(pasteboard) + [StandInBenchPlugin(plain: plain)]
    let at = plugins.firstIndex { $0.id == .topology }!
    plugins.insert(Contributor(id: "bench-stopwatch-end") { r in r.service { _ in ThreadStopwatchEnd(watch) } }, at: at + 1)
    plugins.insert(Contributor(id: "bench-stopwatch-start") { r in r.service { _ in ThreadStopwatchStart(watch) } }, at: at)
    return plugins
}

@MainActor let standInBenchmarks = Suite("Stand-in benchmarks", [
    test("Topology's index of a file with stand-ins, built as it opens, within the index's budget") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            // A hundredth of the shapes mirrors of one note, a tenth arrows into them, from the notes.
            let mirrors = size / 100, arrows = size / 10
            let base = generatedBoard(shapes: size - mirrors - arrows)
            let from = notes(of: base), note = try require(from.first)
            let standIns = (0..<mirrors).map { _ in mirror(standing: [note]) }
            let into = (0..<arrows).map { arrow(from: from[($0 + 1) % from.count], to: standIns[$0 % mirrors].id) }
            let document = CanvasDocument(shapes: base.shapes + standIns + into)
            var times: [String: Double] = [:]
            for plain in [false, true] {
                let watch = ThreadStopwatch()
                let registry = try Registry(plugins: pluginsTimingTopology(watch, pasteboard, plain: plain))
                var runs: [Double] = []
                for _ in 0..<5 {
                    let editor = CanvasEditor(registry: registry, document: document, scheduler: ManualScheduler())
                    runs.append(watch.milliseconds)
                    let topology = try require(editor.topology)
                    expectEqual(topology.standIns(for: note).count, plain ? 0 : mirrors)
                    expectEqual(topology.edges(of: note, .incoming, types: .within(ArrowEdge.id)).count, plain ? 0 : arrows)
                }
                times[plain ? "plain" : "standing"] = middle(runs)
            }
            let standing = times["standing"] ?? .nan, plain = times["plain"] ?? .nan
            report(String(format: "%6d shapes, Topology's index as it opens, %d stand-ins for one note, %d arrows into them: %6.2f ms (budget %.0f), %6.2f with them standing for nothing",
                          size, mirrors, arrows, standing, Budget.topologyOpenStandIns, plain))
            if holdsToBudgets, size >= 10_000 {
                expect(standing < Budget.topologyOpenStandIns, "Topology's index of \(size) shapes with \(mirrors) stand-ins took \(standing) ms")
            }
        }
    },

    test("what's connected to a shape through 100 stand-ins costs what it returns") {
        for size in sizes {
            let base = generatedBoard(shapes: size)
            let from = notes(of: base), note = try require(from.first)
            let standIns = (0..<100).map { _ in mirror(standing: [note]) }
            let into = standIns.enumerated().map { arrow(from: from[($0.offset + 1) % from.count], to: $0.element.id) }
            let registry = try Registry(plugins: ShippedPlugins.plugins(model: ScriptedLanguageModel()) + [StandInBenchPlugin()])
            let editor = CanvasEditor(registry: registry, document: CanvasDocument(shapes: base.shapes + standIns + into),
                                      scheduler: ManualScheduler())
            let topology = try require(editor.topology)
            var found: [EdgeTypeID: [ShapeID]] = [:]
            let all = median(runs: 21, onThread: true) { found = topology.neighbors(of: note) }
            expectEqual(found[StandingEdge.id]?.count, 100, "each stand-in")
            let arrows = median(runs: 21, onThread: true) { found = topology.neighbors(of: note, .incoming, types: .within(ArrowEdge.id)) }
            expectEqual(topology.edges(of: note, .incoming, types: .within(ArrowEdge.id)).count, 100, "each arrow, through its stand-in")
            report(String(format: "%6d shapes, what's connected to a note through 100 stand-ins (%d shapes by arrows): %6.3f ms, its arrows alone %6.3f (budget %.0f)",
                          size, found.values.reduce(0) { $0 + $1.count }, all, arrows, Budget.neighborsThroughStandIn))
            if holdsToBudgets {
                expect(all < Budget.neighborsThroughStandIn, "what's connected to a note through 100 stand-ins, of \(size) shapes, took \(all) ms")
            }
        }
    },

    test("re-pointing a stand-in 100 arrows end at costs what's at it") {
        for size in sizes {
            let base = generatedBoard(shapes: size)
            let from = notes(of: base)
            let a = try require(from.first), c = try require(from.last)
            let standIn = mirror(standing: [a]), alone = mirror(standing: [a])
            let into = (0..<100).map { arrow(from: from[($0 + 1) % from.count], to: standIn.id) }
            let registry = try Registry(plugins: ShippedPlugins.plugins(model: ScriptedLanguageModel()) + [StandInBenchPlugin()])
            let editor = CanvasEditor(registry: registry, document: CanvasDocument(shapes: base.shapes + [standIn, alone] + into),
                                      scheduler: ManualScheduler())
            let topology = try require(editor.topology)
            var flip = false
            @MainActor func repoint(_ id: ShapeID) {
                flip.toggle()
                editor.transact("Re-point") { $0.update(id, as: Mirror.self) { $0.props.stands = [Citation(flip ? c : a)] } }
            }
            let atIt = median(runs: 21, onThread: true) { repoint(standIn.id) }
            expectEqual(topology.edges(through: standIn.id).count, 100)
            let atNothing = median(runs: 21, onThread: true) { repoint(alone.id) }
            report(String(format: "%6d shapes, re-pointing a stand-in 100 arrows end at: %6.3f ms (budget %.0f), one nothing ends at %6.3f",
                          size, atIt, Budget.repointStandIn, atNothing))
            if holdsToBudgets {
                expect(atIt < Budget.repointStandIn, "re-pointing a stand-in 100 arrows end at, of \(size) shapes, took \(atIt) ms")
            }
        }
    },

    test("a drag of 50 stand-ins for what's provided, and what they stand for, costs a drag event nothing more") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let standing = try Registry(plugins: shippedPlugins(pasteboard) + [StandInBenchPlugin()])
        let plain = try Registry(plugins: shippedPlugins(pasteboard) + [StandInBenchPlugin(plain: true)])
        for size in sizes {
            let base = generatedBoard(shapes: size)
            let from = notes(of: base)
            let targets = Array(from.prefix(2)), anchor = try require(base[targets[0]]?.box)
            let lenses = (0..<50).map { lens(asks: "all", at: CGPoint(x: anchor.minX + CGFloat($0 * 10), y: anchor.maxY + 40)) }
            let into = lenses.enumerated().flatMap { index, lens in
                [arrow(from: from[(2 * index + 2) % from.count], to: lens.id), arrow(from: from[(2 * index + 3) % from.count], to: lens.id)]
            }
            let document = CanvasDocument(shapes: base.shapes + lenses + into)
            let center = CGPoint(x: anchor.midX, y: anchor.midY)
            let with = EditorHarness { CanvasEditor(registry: standing, document: document, scheduler: $0) }
            let without = EditorHarness { CanvasEditor(registry: plain, document: document, scheduler: $0) }
            try require(with.editor.topology).provide(Dictionary(uniqueKeysWithValues: lenses.map {
                ($0.id, ProvidedForwarding(key: ForwardingKey("all"), shapes: targets, revision: 1))
            }))
            expectEqual(try require(with.editor.topology).edges(through: lenses[0].id).count, 4, "2 arrows into each, each to both")
            for h in [with, without] {
                h.editor.selectedShapeIDs = targets + lenses.map(\.id)
                h.press(at: center)
            }
            var withTimes: [Double] = [], withoutTimes: [Double] = []
            for step in 1...201 {
                let to = center + CGPoint(x: CGFloat(step), y: CGFloat(step) / 2)
                withTimes.append(threadCPUTime { with.drag(to: to) }.milliseconds)
                withoutTimes.append(threadCPUTime { without.drag(to: to) }.milliseconds)
            }
            with.release()
            without.release()
            expectEqual(with.editor.document[lenses[0].id], without.editor.document[lenses[0].id], "both dragged alike")
            expect(with.editor.document[lenses[0].id]?.box?.origin != lenses[0].box?.origin, "the stand-ins moved")
            let standingTime = middle(withTimes), plainTime = middle(withoutTimes)
            report(String(format: "%6d shapes, a drag event's input with 50 stand-ins for what's provided among the 52 shapes dragged: %6.4f ms, %6.4f with them standing for nothing (budget: %.2f more)",
                          size, standingTime, plainTime, Budget.standInDragUpkeep))
            if holdsToBudgets {
                expect(standingTime - plainTime < Budget.standInDragUpkeep,
                       "a drag event on \(size) shapes took \(standingTime) ms with stand-ins, \(plainTime) without")
            }
        }
    },

    test("a commit while a query holds the file costs little more among 500 stand-ins: each table it shares copied once") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let held = HeldCommit()
        let registry = try Registry(plugins: shippedPlugins(pasteboard) + [heldCommitPlugin(held), StandInBenchPlugin()])
        for size in sizes {
            let base = generatedBoard(shapes: size)
            let from = notes(of: base)
            let standIns = (0..<500).map { mirror(standing: [from[$0 % from.count]]) }
            let into = standIns.enumerated().map { arrow(from: from[($0.offset + 1) % from.count], to: $0.element.id) }
            let editor = CanvasEditor(registry: registry, document: CanvasDocument(shapes: base.shapes + standIns + into),
                                      scheduler: ManualScheduler())
            let queries = try require(editor.queries)
            _ = queries.vocabulary
            var next = 0
            // An arrow into the next stand-in: forwarded, so the carrier's resolved edges are kept apart.
            let add = {
                next += 1
                editor.transact("Add Arrow") { $0.insert(arrow(from: from[next % from.count], to: standIns[next % standIns.count].id)) }
            }
            var plain: [Double] = [], during: [Double] = []
            for _ in 0..<21 {
                plain.append(threadCPUTime { add() }.milliseconds)
                held.during = { during.append(threadCPUTime { add() }.milliseconds) }
                _ = try queried("#\(from[0]):held-commit", on: editor, countOnly: true, noting: false)
            }
            expectEqual(during.count, 21, "a commit landed during each query")
            expectEqual(try require(editor.topology).edges(through: standIns[1].id).count, 2, "the arrow added into it, forwarded")
            let alone = middle(plain), whileHeld = middle(during)
            report(String(format: "%6d shapes, 500 stand-ins, a commit adding an arrow into one: %6.3f ms, while a query holds the file %6.3f (budget: %.1f more)",
                          size, alone, whileHeld, Budget.heldCommitStandIns.at(size)))
            if holdsToBudgets {
                expect(whileHeld - alone < Budget.heldCommitStandIns.at(size),
                       "a commit among 500 stand-ins on \(size) shapes while a query holds the file took \(whileHeld) ms, against \(alone)")
            }
        }
    },

    test("a provide that fans out, on the main actor: 100 arrows into a lens whose 50 shapes change, and an arrow between two of 2,500 pairs") {
        for size in sizes {
            let base = generatedBoard(shapes: size)
            let from = notes(of: base)
            let first = Array(from.prefix(50)), second = Array(from.dropFirst(50).prefix(50))
            let fanned = lens(asks: "all"), left = lens(asks: "all"), right = lens(asks: "all")
            let into = (0..<100).map { arrow(from: from[(100 + $0) % from.count], to: fanned.id) }
            let between = arrow(from: left.id, to: right.id)
            let registry = try Registry(plugins: ShippedPlugins.plugins(model: ScriptedLanguageModel()) + [StandInBenchPlugin()])
            let editor = CanvasEditor(registry: registry, document: CanvasDocument(shapes: base.shapes + [fanned, left, right, between] + into),
                                      scheduler: ManualScheduler())
            let topology = try require(editor.topology)
            let key = ForwardingKey("all")
            topology.provide([right.id: ProvidedForwarding(key: key, shapes: second, revision: 1)])
            var revision = 0
            let provide = median(runs: 21, onThread: true) {
                revision += 1
                let shapes = revision % 2 == 0 ? first : second
                topology.provide([fanned.id: ProvidedForwarding(key: key, shapes: shapes, revision: revision),
                                  left.id: ProvidedForwarding(key: key, shapes: shapes, revision: revision)])
            }
            expectEqual(topology.edges(through: fanned.id).count, 100 * 50)
            expectEqual(topology.edges(carriedBy: between.id).count, 50 * 50)
            report(String(format: "%6d shapes, a provide changing a lens's 50 shapes (100 arrows into it) and one with an arrow to another (%d pairs): %6.3f ms (budget %.0f)",
                          size, 50 * 50, provide, Budget.provideFanOut))
            if holdsToBudgets {
                expect(provide < Budget.provideFanOut, "a provide that fans out, of \(size) shapes, took \(provide) ms")
            }
        }
    },

    test("a lens of every note, 100 arrows into it: an answer that adds or drops one, prepared off the main actor, costs the main actor what came and went") {
        for size in sizes {
            let base = generatedBoard(shapes: size)
            let every = notes(of: base)
            let fanned = lens(asks: "all")
            let into = (0..<100).map { arrow(from: every[(100 + $0) % every.count], to: fanned.id) }
            let registry = try Registry(plugins: ShippedPlugins.plugins(model: ScriptedLanguageModel()) + [StandInBenchPlugin()])
            let editor = CanvasEditor(registry: registry, document: CanvasDocument(shapes: base.shapes + [fanned] + into), scheduler: ManualScheduler())
            let topology = try require(editor.topology)
            let key = ForwardingKey("all"), most = Array(every.dropLast())
            topology.provide([fanned.id: ProvidedForwarding(key: key, shapes: most, revision: 1)])
            var revision = 1, answers: [ShapeID: ProvidedForwarding] = [:], prepared: PreparedForwarding?
            let next = {
                revision += 1
                answers = [fanned.id: ProvidedForwarding(key: key, shapes: revision % 2 == 0 ? every : most, revision: revision)]
            }
            let taken = median(runs: 21, prepare: {
                next()
                let preparer = topology.preparer(), asked = answers
                prepared = offMain { preparer.prepare(asked) }
            }, onThread: true) {
                topology.provide(answers, prepared: prepared)
            }
            let newer = median(runs: 21, prepare: {
                revision += 1
                answers = [fanned.id: ProvidedForwarding(key: key, shapes: topology.forwards(of: fanned.id), revision: revision)]
                let preparer = topology.preparer(), asked = answers
                prepared = offMain { preparer.prepare(asked) }
            }, onThread: true) {
                topology.provide(answers, prepared: prepared)
            }
            let here = median(runs: 11, prepare: next, onThread: true) { topology.provide(answers) }
            expectEqual(topology.forwards(of: fanned.id).count, every.count - revision % 2)
            expect(topology.edges(of: every[0], .incoming, types: .within(ArrowEdge.id)).count >= 100, "a hundred arrows into it, read as asked")
            report(String(format: "%6d shapes, a lens of %d notes given one more or one fewer: prepared, the main actor %6.3f ms, the same shapes again %6.3f (budget %.1f); worked out on the main actor %6.3f",
                          size, every.count, taken, newer, Budget.preparedProvide, here))
            if holdsToBudgets {
                expect(taken < Budget.preparedProvide, "a prepared answer for a lens of \(every.count) notes took \(taken) ms on the main actor")
                expect(newer < Budget.preparedProvide, "a prepared answer saying the same took \(newer) ms on the main actor")
            }
        }
    },
])
