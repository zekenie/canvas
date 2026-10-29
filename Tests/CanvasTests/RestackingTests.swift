@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// The core's restacking of several shapes at once (`bringToFront`, `sendToBack`, `bringForward`,
// `sendBackward`), over CanvasTesting's boxes and corrals, plus one anchored box kind (Banner)
// declared in this file. Restacking on a board that isn't shown is in MovingOffBoardsTests.

/// A box painted by anchor, as an arrow is: document order doesn't decide where it's drawn.
private struct Banner: BoxShapeProps {
    static let kind: ShapeKind = "banner"
    static let properties = Properties<Banner> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

private struct BannerDefinition: ShapeDefinition, PaintOrderAnchored {
    func render(_ shape: ShapeRecord<Banner>, in context: RenderContext) {}
    func paintAnchor(of shape: ShapeRecord<Banner>, in document: CanvasDocument) -> ShapeID? { nil }
}

@MainActor private func order(_ h: EditorHarness) -> [ShapeID] { h.editor.document.shapes.map(\.id) }

/// A small seeded generator (SplitMix64), so the run is the same each time.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The list forms as they were before they replayed the stack: each shape in turn, by the forms of one shape, and a
/// step found by walking the stack from the shape until one overlaps it.
@MainActor private func oneByOne(_ transaction: inout Transaction, _ form: String, _ ids: [ShapeID], registry: Registry) {
    let ordered = ids.sorted { (transaction.document.index(of: $0) ?? 0) < (transaction.document.index(of: $1) ?? 0) }
    switch form {
    case "front": for id in ordered { transaction.bringToFront(id) }
    case "back": for id in ordered.reversed() { transaction.sendToBack(id) }
    default:
        let forward = form == "forward", moving = Set(ids)
        for id in forward ? ordered.reversed() : ordered {
            guard let index = transaction.document.index(of: id), let mine = transaction.shapes.geometry(of: id)?.bounds else { continue }
            let all = Array(transaction.document.shapes)
            let passing = forward ? Array(all[(index + 1)...]) : all[..<index].reversed()
            let held = Set(transaction.document.descendants(of: id, containingKinds: registry.containingKinds))
            let next = passing.first { other in
                !moving.contains(other.id) && !held.contains(other.id) && !(registry.definition(for: other.kind) is any PaintOrderAnchored)
                    && transaction.shapes.geometry(of: other.id).map { $0.bounds.intersects(mine) } == true
            }
            guard let next else { continue }
            if forward { transaction.move(id, above: next.id) } else { transaction.move(id, below: next.id) }
        }
    }
}

@MainActor let restackingTests = Suite("Restacking several shapes", [
    test("to front and to back keep the shapes' order among themselves, whatever order they're given in") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 400, y: 0, width: 100, height: 100)))
        h.editor.transact("Send to Back") { $0.sendToBack([c, a]) }
        expectEqual(order(h), [a, c, b])
        h.editor.transact("Bring to Front") { $0.bringToFront([c, a]) }
        expectEqual(order(h), [b, a, c])
    },
    test("Bring Forward and Send Backward step past the next shape each overlaps, keeping the shapes' order") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))      // overlaps a
        let c = h.add(Box(CGRect(x: 500, y: 0, width: 100, height: 100)))     // overlaps nothing
        let d = h.add(Box(CGRect(x: 60, y: 0, width: 100, height: 100)))      // overlaps a and b
        @MainActor func forward(_ ids: [ShapeID]) { h.editor.transact("Bring Forward") { $0.bringForward(ids) } }
        @MainActor func backward(_ ids: [ShapeID]) { h.editor.transact("Send Backward") { $0.sendBackward(ids) } }
        forward([a])
        expectEqual(order(h), [b, a, c, d])
        forward([a])
        expectEqual(order(h), [b, c, d, a], "past c, which it doesn't overlap, to above d")
        let revision = h.editor.revision
        forward([a])
        expectEqual(h.editor.revision, revision, "nothing above it: nothing to do")
        backward([a])
        expectEqual(order(h), [b, c, a, d])
        backward([a])
        expectEqual(order(h), [a, b, c, d], "past c again, to below b")

        forward([b, a])
        expectEqual(order(h), [c, d, a, b], "each past d, the next it overlaps, a still below b")
        backward([b, a])
        expectEqual(order(h), [c, a, b, d])
    },
    test("a container steps past the next shape it overlaps that it doesn't hold, what it holds going with it") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CorralsPlugin()])
        let corral = h.add(Corral(CGRect(x: 0, y: 0, width: 300, height: 200)))
        let held = h.add(Box(CGRect(x: 20, y: 20, width: 100, height: 100)))
        h.editor.put([held], in: corral)
        let over = h.add(Box(CGRect(x: 250, y: 50, width: 100, height: 100)))       // overlaps the corral, above it
        expectEqual(order(h), [corral, held, over])
        h.editor.transact("Bring Forward") { $0.bringForward([corral]) }
        expectEqual(order(h), [over, corral, held], "past the box above it, not its own box, which goes with it")
        h.editor.transact("Send Backward") { $0.sendBackward([corral]) }
        expectEqual(order(h), [corral, held, over])
    },
    test("a shape painted by anchor isn't one to step past") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "banners") { $0.shape(BannerDefinition()) }])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let banner = h.add(Banner(CGRect(x: 20, y: 0, width: 100, height: 100)))   // overlaps a
        let c = h.add(Box(CGRect(x: 50, y: 0, width: 100, height: 100)))           // overlaps a
        h.editor.transact("Bring Forward") { $0.bringForward([a]) }
        expectEqual(order(h), [banner, c, a], "past c, the banner not counted")
        h.editor.transact("Send Backward") { $0.sendBackward([a]) }
        expectEqual(order(h), [banner, a, c], "below c again")
    },
    test("the list forms leave a read-only shape where it is, and say so once") {
        let log = RefusalLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(log: log)])
        let locked = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let a = h.add(Box(CGRect(x: 20, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 40, y: 0, width: 100, height: 100)))
        h.editor.freeze([locked])
        h.editor.transact("Front") { $0.bringToFront([locked, a]) }
        expectEqual(order(h), [locked, b, a])
        expectEqual(log.refusals, [[locked]])
        h.editor.transact("Forward") { $0.bringForward([locked]) }
        expectEqual(order(h), [locked, b, a])
        h.editor.transact("Backward") { $0.sendBackward([locked]) }
        expectEqual(order(h), [locked, b, a])
        h.editor.transact("Back") { $0.sendToBack([locked, a]) }
        expectEqual(order(h), [a, locked, b], "a goes to the back, the locked shape stays")
        expectEqual(log.refusals.count, 3, "all but the step back from the back, which has nowhere to go")
    },
    test("the list forms leave the board as their forms of one shape do in turn, keys and refusals too, over corrals, banners and frozen boxes") {
        for seed in 1...12 as ClosedRange<UInt64> {
            var random = SeededGenerator(seed: seed)
            @MainActor func plugins(_ log: RefusalLog) -> [any CanvasPlugin] {
                [FixturesPlugin(), CorralsPlugin(), FreezingPlugin(log: log), Contributor(id: "banners") { $0.shape(BannerDefinition()) }]
            }
            let replayed = RefusalLog(), stepped = RefusalLog()
            let registry = try Registry(plugins: plugins(replayed))
            let h = EditorHarness { CanvasEditor(registry: registry, scheduler: $0, stackingKeys: .sequential) }
            func spot(_ side: ClosedRange<Int>) -> CGRect {
                CGRect(x: Int.random(in: 0...500, using: &random), y: Int.random(in: 0...500, using: &random),
                       width: Int.random(in: side, using: &random), height: Int.random(in: side, using: &random))
            }
            // Boxes heaped so most overlap a few, corrals holding some of them (one corral in another, now and then),
            // banners among them, and a few frozen.
            var boxes = (0..<24).map { _ in h.add(Box(spot(60...160))) }
            let corrals = (0..<3).map { _ in h.add(Corral(spot(200...300))) }
            for corral in corrals {
                boxes.shuffle(using: &random)
                h.editor.put(Array(boxes.prefix(Int.random(in: 1...5, using: &random))), in: corral)
            }
            if Bool.random(using: &random) { h.editor.put([corrals[1]], in: corrals[0]) }
            for _ in 0..<3 { _ = h.add(Banner(spot(60...160))) }
            var ids = order(h)
            h.editor.freeze(Array(ids.shuffled(using: &random).prefix(3)))
            ids = order(h)
            // What setting the board up refused (a freeze inside a frozen corral) is no restack's.
            replayed.refusals = []
            let steppedRegistry = try Registry(plugins: plugins(stepped))
            let r = EditorHarness { CanvasEditor(registry: steppedRegistry, document: h.editor.document, scheduler: $0, stackingKeys: .sequential) }
            for round in 0..<16 {
                let form = ["front", "back", "forward", "backward"].randomElement(using: &random)!
                let count = Bool.random(using: &random) ? ids.count : Int.random(in: 1...ids.count, using: &random)
                let picked = Array(ids.shuffled(using: &random).prefix(count))
                h.editor.transact(form) { transaction in
                    switch form {
                    case "front": transaction.bringToFront(picked)
                    case "back": transaction.sendToBack(picked)
                    case "forward": transaction.bringForward(picked)
                    default: transaction.sendBackward(picked)
                    }
                }
                r.editor.transact(form) { oneByOne(&$0, form, picked, registry: r.editor.registry) }
                let note = "seed \(seed), round \(round): \(form) of \(count)"
                expectEqual(Array(h.editor.document.shapes), Array(r.editor.document.shapes), note)
                expectEqual(replayed.refusals, stepped.refusals, "\(note): the refusals")
                guard h.editor.document == r.editor.document else { break }
            }
        }
    },
])
