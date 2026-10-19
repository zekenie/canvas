@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// How the editor delivers a change to services (`CanvasEditor.deliver`): each in the order they were made,
// each once, and a service asked for while services hear a change hears it first. That nothing may change the
// file while they hear one is a precondition, which a test can't hold.

/// What three hearers heard, and saw of one another, as they heard it.
@MainActor final class Hearings {
    /// Each change a hearer heard, as "first commit", in the order they heard them.
    var heard: [String] = []
    /// The revisions each hearer heard, by name.
    var revisions: [String: [Int]] = [:]
    /// The hearers each reads as it hears a change, by name.
    var reads: [String: [String]] = [:]
    /// What each read: "first read third: heard" when the one it read had heard the change being delivered.
    var seen: [String] = []
}

/// A service that notes each change it hears and reads the hearers `hearings.reads` names for it as it hears it.
@MainActor class Hearer {
    let name: String
    let hearings: Hearings
    private(set) var heardRevision = 0
    init(_ name: String, _ hearings: Hearings) {
        self.name = name
        self.hearings = hearings
    }

    fileprivate func hear(_ what: String, in editor: CanvasEditor) {
        heardRevision = editor.revision
        hearings.heard.append("\(name) \(what)")
        hearings.revisions[name, default: []].append(editor.revision)
        for other in hearings.reads[name] ?? [] {
            guard let hearer = hearer(other, in: editor) else { continue }
            hearings.seen.append("\(name) read \(other): \(hearer.heardRevision == editor.revision ? "heard" : "not heard")")
        }
    }
}

final class FirstHearer: Hearer {}
final class SecondHearer: Hearer {}
final class ThirdHearer: Hearer {}

extension Hearer: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { hear("commit", in: editor) }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { hear("board", in: editor) }
}

/// The hearer called `name`, looked up as any service is.
@MainActor private func hearer(_ name: String, in editor: CanvasEditor) -> Hearer? {
    switch name {
    case "first": editor.service(FirstHearer.self)
    case "second": editor.service(SecondHearer.self)
    default: editor.service(ThirdHearer.self)
    }
}

/// Boxes, pockets and the three hearers, made in that order, on a root holding a pocket whose board holds a box.
@MainActor private func listening(_ hearings: Hearings) throws -> (h: EditorHarness, pocket: ShapeID) {
    let pocket = ShapeID()
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 60))))]),
                          children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 40))))])])
    let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(),
                                        Contributor(id: "first") { r in r.service { _ in FirstHearer("first", hearings) } },
                                        Contributor(id: "second") { r in r.service { _ in SecondHearer("second", hearings) } },
                                        Contributor(id: "third") { r in r.service { _ in ThirdHearer("third", hearings) } }], file: file)
    return (h, pocket)
}

@MainActor let deliveryTests = Suite("Delivering a change to services", [
    test("services hear a commit, and another board shown, in the order they were made, each once") {
        let hearings = Hearings()
        let (h, pocket) = try listening(hearings)
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "second commit", "third commit"])
        hearings.heard = []
        expect(h.enter(pocket))
        expectEqual(hearings.heard, ["first board", "second board", "third board"])
    },
    test("a service read while services hear a commit hears it first, and isn't told it again") {
        let hearings = Hearings()
        let (h, _) = try listening(hearings)
        hearings.reads = ["first": ["third"]]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "third commit", "second commit"])
        expectEqual(hearings.seen, ["first read third: heard"])
    },
    test("so is one read while services hear another board shown") {
        let hearings = Hearings()
        let (h, pocket) = try listening(hearings)
        hearings.reads = ["first": ["third"]]
        expect(h.enter(pocket))
        expectEqual(hearings.heard, ["first board", "third board", "second board"])
        expectEqual(hearings.seen, ["first read third: heard"])
    },
    test("what a service read as it heard reads as it hears, at any depth, each hearing first") {
        let hearings = Hearings()
        let (h, _) = try listening(hearings)
        hearings.reads = ["first": ["third"], "third": ["second"]]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "third commit", "second commit"])
        expectEqual(hearings.seen, ["third read second: heard", "first read third: heard"])
    },
    test("a service read while it hears the change, by itself or by one it read, is as it is, and isn't told it again") {
        let hearings = Hearings()
        let (h, _) = try listening(hearings)
        hearings.reads = ["first": ["first", "second"], "second": ["first"]]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "second commit", "third commit"])
        expectEqual(hearings.seen, ["first read first: heard", "second read first: heard", "first read second: heard"],
                    "the first reads as far as it had got: it noted the revision first")
    },
    test("a service read once services have heard a change hears nothing more") {
        let hearings = Hearings()
        let (h, _) = try listening(hearings)
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        hearings.heard = []
        _ = hearer("third", in: h.editor)
        _ = h.editor.service(SecondHearer.self)
        expectEqual(hearings.heard, [])
    },
    test("whatever services read, each hears every commit and every board shown once, in the order they came") {
        var generator = SeededGenerator(seed: 0xDE11_7E2)
        let names = ["first", "second", "third"]
        for round in 0..<40 {
            let hearings = Hearings()
            let (h, pocket) = try listening(hearings)
            var made: [Int] = []
            for step in 0..<12 {
                hearings.reads = Dictionary(uniqueKeysWithValues: names.map { name in
                    (name, names.filter { _ in Bool.random(using: &generator) })
                })
                if step % 4 == 3 {
                    expect(h.editor.board == .root ? h.enter(pocket) : h.editor.showBoard(.root))
                } else {
                    h.add(Box(CGRect(x: CGFloat(step) * 50, y: 300, width: 40, height: 40)))
                }
                made.append(h.editor.revision)
            }
            for name in names { expectEqual(hearings.revisions[name], made, "round \(round): \(name)") }
        }
    },
])

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
