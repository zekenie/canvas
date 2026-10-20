@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// How the editor delivers a change to services (`CanvasEditor.beginDelivery`, `finishDelivery`): each takes it in in the
// order they were made, each once, a service asked for meanwhile taking it in first, and what a service looked up as it
// was made first of all; a service asked for while it is taking it in is a mistake (debug builds stop, unless a test holds
// it: `busyRead`); what one asks to do once it has taken it in runs as its hook returns (`onceHeard`); then every service
// settles, and what waited for that runs (`onceSettled`). That nothing may change the file meanwhile is a precondition,
// which a test can't hold.

/// What three hearers heard, and saw of one another, as they heard it.
@MainActor final class Hearings {
    /// Each change a hearer heard, as "first commit", in the order they heard them.
    var heard: [String] = []
    /// The revisions each hearer heard, by name.
    var revisions: [String: [Int]] = [:]
    /// The hearers each reads as it hears a change, by name.
    var reads: [String: [String]] = [:]
    /// The hearers each reads as it settles, by name.
    var settleReads: [String: [String]] = [:]
    /// The hearers that ask, as they hear a change, to read themselves once they have (`onceHeard`).
    var tells: Set<String> = []
    /// The hearers that ask, as they hear a change, to read every hearer once all have settled (`onceSettled`), and
    /// then ask to once more.
    var waits: Set<String> = []
    /// What each read: "first read third: heard" when the one it read had heard the change being delivered.
    var seen: [String] = []
    /// Each settling, as "first commit after 3": how many hearings had come by then.
    var settled: [String] = []
    /// The mistakes a test holds (`busyRead`).
    var mistakes: [String] = []
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
        read(hearings.reads[name] ?? [], as: name, in: editor)
        if hearings.tells.contains(name) {
            editor.onceHeard { [self] in
                hearings.heard.append("\(name) told")
                read([name], as: "\(name) told", in: editor)
            }
        }
        if hearings.waits.contains(name) {
            editor.onceSettled { [self] in
                hearings.heard.append("\(name) once settled")
                read(["first", "second", "third"], as: "\(name) once settled", in: editor)
                editor.onceSettled { [self] in hearings.heard.append("\(name) once settled again") }
            }
        }
    }

    fileprivate func settle(_ what: String, in editor: CanvasEditor) {
        hearings.settled.append("\(name) \(what) after \(hearings.heard.count)")
        read(hearings.settleReads[name] ?? [], as: "\(name) settling", in: editor)
    }

    private func read(_ others: [String], as reader: String, in editor: CanvasEditor) {
        for other in others {
            guard let hearer = hearer(other, in: editor) else { continue }
            hearings.seen.append("\(reader) read \(other): \(hearer.heardRevision == editor.revision ? "heard" : "not heard")")
        }
    }
}

final class FirstHearer: Hearer {}
final class SecondHearer: Hearer {}
final class ThirdHearer: Hearer {}

extension Hearer: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { hear("commit", in: editor) }
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) { hear("board", in: editor) }
    func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) { settle("commit", in: editor) }
    func boardDidSettle(_ change: BoardChange, in editor: CanvasEditor) { settle("board", in: editor) }
}

/// The hearer called `name`, looked up as any service is.
@MainActor private func hearer(_ name: String, in editor: CanvasEditor) -> Hearer? {
    switch name {
    case "first": editor.service(FirstHearer.self)
    case "second": editor.service(SecondHearer.self)
    default: editor.service(ThirdHearer.self)
    }
}

/// Boxes, pockets and the three hearers, made in that order, on a root holding a pocket whose board holds a box. The
/// mistakes a busy read is are held in `hearings.mistakes`.
@MainActor private func listening(_ hearings: Hearings) throws -> (h: EditorHarness, pocket: ShapeID) {
    let pocket = ShapeID()
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 60))))]),
                          children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 40))))])])
    let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(),
                                        Contributor(id: "first") { r in r.service { _ in FirstHearer("first", hearings) } },
                                        Contributor(id: "second") { r in r.service { _ in SecondHearer("second", hearings) } },
                                        Contributor(id: "third") { r in r.service { _ in ThirdHearer("third", hearings) } }], file: file)
    h.editor.busyRead = { [weak hearings] in hearings?.mistakes.append($0) }
    return (h, pocket)
}

/// A host that counts the redraws it's asked for.
@MainActor private final class Host: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

/// A service that asks for a redraw, many times, as it hears each commit.
@MainActor private final class Redrawer {}

extension Redrawer: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        for _ in 0..<5 { editor.setNeedsDisplay() }
    }
}

/// A service that keeps the second hearer, looked up as it's made, and notes as it hears a change whether the one it
/// kept has taken it in: what it reads through the reference is no lookup.
@MainActor private final class Keeper {
    let kept: SecondHearer?
    var saw: [String] = []
    init(editor: CanvasEditor) { kept = editor.service(SecondHearer.self) }
}

extension Keeper: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        saw.append(kept?.heardRevision == editor.revision ? "heard" : "not heard")
    }
}

/// A service made first that asks for the keeper as it hears a change, so the keeper takes it in before its turn.
@MainActor private final class Asker {}

extension Asker: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) { _ = editor.service(Keeper.self) }
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
        expectEqual(hearings.mistakes, [])
    },
    test("a service asked for while it takes the change in, by itself or by one it read, is a mistake naming those taking it in, and is as it is") {
        let hearings = Hearings()
        let (h, _) = try listening(hearings)
        hearings.reads = ["first": ["first", "second"], "second": ["first"]]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "second commit", "third commit"])
        expectEqual(hearings.mistakes, ["FirstHearer was asked for while it takes a change in (busy: FirstHearer)",
                                        "FirstHearer was asked for while it takes a change in (busy: FirstHearer > SecondHearer)"])
        expectEqual(hearings.seen, ["first read first: heard", "second read first: heard", "first read second: heard"],
                    "the first reads as far as it had got: it noted the revision first")
    },
    test("once every service has taken a commit in, or another board shown, each settles in the order they were made, and may read any") {
        let hearings = Hearings()
        let (h, pocket) = try listening(hearings)
        hearings.reads = ["first": ["third"]]
        hearings.settleReads = ["first": ["first", "second", "third"], "third": ["first"]]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.settled, ["first commit after 3", "second commit after 3", "third commit after 3"])
        expectEqual(hearings.seen, ["first read third: heard", "first settling read first: heard", "first settling read second: heard",
                                    "first settling read third: heard", "third settling read first: heard"])
        expectEqual(hearings.mistakes, [], "none is busy as they settle")
        hearings.heard = []
        hearings.settled = []
        expect(h.enter(pocket))
        expectEqual(hearings.settled, ["first board after 3", "second board after 3", "third board after 3"])
        expectEqual(hearings.mistakes, [])
    },
    test("what a service asks to do once it has taken the change in runs as its hook returns, before those after it hear, and may read it") {
        let hearings = Hearings()
        let (h, _) = try listening(hearings)
        hearings.tells = ["first", "second"]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "first told", "second commit", "second told", "third commit"])
        expectEqual(hearings.seen, ["first told read first: heard", "second told read second: heard"])
        expectEqual(hearings.mistakes, [])
        hearings.heard = []
        hearings.reads = ["first": ["second"]]
        h.add(Box(CGRect(x: 300, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "second commit", "second told", "first told", "third commit"],
                    "the second, heard as the first read it, told as its own hook returned, the first once it had")
        let ran = Flag()
        h.editor.onceHeard { ran.set() }
        expect(ran.isSet, "at once with no change being delivered")
    },
    test("what waits for every service to have settled runs once they have, in the order asked, none busy, what it asks for after it") {
        let hearings = Hearings()
        let (h, pocket) = try listening(hearings)
        hearings.waits = ["first", "third"]
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(hearings.heard, ["first commit", "second commit", "third commit", "first once settled", "third once settled",
                                     "first once settled again", "third once settled again"])
        expectEqual(hearings.settled, ["first commit after 3", "second commit after 3", "third commit after 3"], "after every settling")
        expectEqual(hearings.seen.filter { !$0.hasSuffix(": heard") }, [], "every one had the commit")
        expectEqual(hearings.mistakes, [], "none is busy")
        hearings.heard = []
        expect(h.enter(pocket))
        expectEqual(Array(hearings.heard.suffix(4)), ["first once settled", "third once settled", "first once settled again", "third once settled again"],
                    "another board shown too")
        let ran = Flag()
        h.editor.onceSettled { ran.set() }
        expect(ran.isSet, "at once with no change being delivered")
    },
    test("a service told before its turn has what it looked up as it was made take the change in first, so what it kept is up to date") {
        let hearings = Hearings()
        let h = try EditorHarness(plugins: [FixturesPlugin(),
                                            Contributor(id: "asker") { r in r.service { _ in Asker() } },
                                            Contributor(id: "keeper") { r in r.service { Keeper(editor: $0) } },
                                            Contributor(id: "second") { r in r.service { _ in SecondHearer("second", hearings) } }])
        h.editor.busyRead = { [weak hearings] in hearings?.mistakes.append($0) }
        h.add(Box(CGRect(x: 200, y: 0, width: 40, height: 40)))
        expectEqual(h.editor.service(Keeper.self)?.saw, ["heard"], "the second, which the keeper's make looked up, took the commit in first")
        expectEqual(hearings.heard, ["second commit"], "once")
        expectEqual(hearings.mistakes, [])
    },
    test("a redraw asked for while services take a change in is the change's own, once they've settled") {
        let host = Host()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "redrawer") { $0.service { _ in Redrawer() } }])
        h.editor.delegate = host
        host.redraws = 0
        h.editor.transact { $0.insert(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))) }
        expectEqual(host.redraws, 1, "the five asked for are the commit's redraw")
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
