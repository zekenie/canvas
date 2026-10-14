@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Topology

// Making a stand-in that stands for a given shape (`standsIn(makes:)`, `registry.standIns`): which kinds
// can be made to, who they stand for, what they're given, what's put in step, and what the rule says
// without the index. Over a fixture of the tests' own: an echo stands for the shape its record cites,
// and says its name, and it's as wide as it says.

/// Whether an echo may stand for a shape.
enum Ajar: ShapeMetaKey {
    static let owner: PluginID = "echoes"
    static let name = "ajar"
    typealias Value = Bool
}

/// A box that stands for the shape it cites and says what it stands for: its width follows its words.
struct Echo: BoxShapeProps {
    static let kind: ShapeKind = "echo"
    static let properties = Properties<Echo> {
        Property("frame", \.frame).required()
        Property("cites", \.cites)
        Property("says", \.says)
    }
    var frame: CGRect
    var cites: Citation?
    var says: String
    init(_ frame: CGRect, cites: ShapeID? = nil, says: String = "") {
        self.frame = frame
        self.cites = cites.map(Citation.init)
        self.says = says
    }

    static func width(saying says: String) -> CGFloat { 30 + 7 * CGFloat(says.count) }
}

extension Echo {
    init() { self.init(CGRect(x: 0, y: 0, width: 90, height: 30)) }
}

struct EchoDefinition {}

extension EchoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Echo>, in context: RenderContext) {}
}

extension EchoDefinition: DerivedProps {
    func derive(_ props: inout Echo) { props.frame.size.width = Echo.width(saying: props.says) }
}

/// A kind that stands in and says nothing of how it's made, and one whose rule says how but that no tool
/// places.
struct Mute: BoxShapeProps {
    static let kind: ShapeKind = "mute"
    static let properties = Properties<Mute> {
        Property("frame", \.frame).required()
        Property("cites", \.cites)
    }
    var frame: CGRect
    var cites: Citation?
    init(_ frame: CGRect, cites: ShapeID? = nil) {
        self.frame = frame
        self.cites = cites.map(Citation.init)
    }
}

extension Mute {
    init() { self.init(unit) }
}

struct MuteDefinition {}

extension MuteDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Mute>, in context: RenderContext) {}
}

struct Phantom: BoxShapeProps {
    static let kind: ShapeKind = "phantom"
    static let properties = Properties<Phantom> {
        Property("frame", \.frame).required()
        Property("cites", \.cites)
    }
    var frame: CGRect
    var cites: Citation?
    init(_ frame: CGRect, cites: ShapeID? = nil) {
        self.frame = frame
        self.cites = cites.map(Citation.init)
    }
}

extension Phantom {
    init() { self.init(unit) }
}

struct PhantomDefinition {}

extension PhantomDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Phantom>, in context: RenderContext) {}
}

/// Echoes (made for ajar shapes, by a tool that places them 90 wide), a mute that stands in without a
/// way to be made, and a phantom whose rule says how but that no tool places.
struct EchoesPlugin: CanvasPlugin {
    var needs: String? = "ajar"
    var fulfils = true
    /// A fulfilling that changes the copy, then answers this: false, or true without having made it admissible.
    var changesThenAnswers: Bool?
    var id: PluginID { "echoes" }

    func register(into registrar: inout PluginRegistrar) {
        var fulfilling: (@MainActor (inout AnyShapeRecord, Registry) -> Bool)?
        if let answer = changesThenAnswers {
            fulfilling = { record, _ in
                record.meta[Ajar.self] = false
                return answer
            }
        } else if fulfils {
            fulfilling = { record, _ in
                record.meta[Ajar.self] = true
                return true
            }
        }
        registrar.shape(EchoDefinition()) { echo in
            echo.standsIn(admitting: { target, _ in target.meta[Ajar.self] == true }, needs: needs,
                          fulfilling: fulfilling,
                          calls: { shape, _ in shape.props.says.isEmpty ? nil : shape.props.says },
                          makes: { props, target, label in
                              props.cites = Citation(target)
                              props.says = label
                          }) { shape, _ in shape.props.cites.map { .shapes([$0.shape]) } }
            echo.tool(label: "Echo", systemImage: "arrow.right", placing: echo.placement(size: CGSize(width: 90, height: 30)) { Echo() })
        }
        registrar.shape(MuteDefinition()) { mute in
            mute.standsIn { shape, _ in shape.props.cites.map { .shapes([$0.shape]) } }
            mute.tool(label: "Mute", systemImage: "circle", placing: mute.placement(size: CGSize(width: 50, height: 50)) { Mute() })
        }
        registrar.shape(PhantomDefinition()) { phantom in
            phantom.standsIn(makes: { props, target, _ in props.cites = Citation(target) }) { shape, _ in shape.props.cites.map { .shapes([$0.shape]) } }
        }
    }
}

/// A box that's ajar.
func ajar(_ id: ShapeID) -> AnyShapeRecord {
    var record = box(id)
    record.meta[Ajar.self] = true
    return record
}

@MainActor let makingTests = Suite("Making a stand-in for a shape", [
    test("the kinds that can be made to stand for a shape are those whose rule says how and a tool places, in plugin order; every kind that stands in is read too") {
        let h = try graph(more: [StandInsPlugin(), EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        expectEqual(standIns.makers, [Echo.kind], "the mute says nothing, the phantom has no tool, the proxy and gate say nothing")
        expectEqual(standIns.kinds, [Proxy.kind, Gate.kind, Echo.kind, Mute.kind, Phantom.kind])
        expect(!standIns.isEmpty)
        expect(try graph().editor.registry.standIns.isEmpty, "none without a rule")
        expectEqual(try graph().editor.registry.standIns.makers, [])
        // The report says each rule as it always did.
        let report = try Registry(plugins: graphPlugins(more: [EchoesPlugin()])).report
        expect(report.contains("stands in → echo"), report)
    },
    test("what a record says it stands for is its kind's rule, applied; nothing for a shape that doesn't stand in, or stands for nothing") {
        let a = ShapeID(), r = ShapeID()
        let h = try graph(CanvasFile(root: board(box(a), AnyShapeRecord(ShapeRecord(id: r, Echo(unit, cites: a, says: "A"))),
                                                 AnyShapeRecord(ShapeRecord(Echo(unit))))), more: [EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        expectEqual(standIns.forwarding(of: try require(h.editor.document[r])), .shapes([a]))
        expectEqual(standIns.forwarding(of: try require(h.editor.document[a])), nil, "a box doesn't stand in")
        expectEqual(standIns.forwarding(of: try require(h.editor.document.shapes.last)), nil, "an echo that cites nothing stands for nothing")
    },
    test("a stand-in of a kind admits what the kind's rule admits, and never a stand-in or a shape kept aside") {
        let open = ShapeID(), shut = ShapeID(), echo = ShapeID()
        let h = try graph(CanvasFile(root: board(ajar(open), box(shut), AnyShapeRecord(ShapeRecord(id: echo, Echo(unit, cites: open, says: "x"))))),
                          more: [EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        expect(standIns.admits(Echo.kind, try require(h.editor.document[open])))
        expect(!standIns.admits(Echo.kind, try require(h.editor.document[shut])))
        var echoAjar = try require(h.editor.document[echo])
        echoAjar.meta[Ajar.self] = true
        expect(!standIns.admits(Echo.kind, echoAjar), "one hop: a stand-in isn't stood for")
        expect(!standIns.admits(Box.kind, try require(h.editor.document[open])), "a kind that doesn't stand in admits nothing")
        let kept = try require(hiddenFile().file.root.shapes.first { $0.isOpaque })
        expect(!standIns.admits(Echo.kind, kept), "a shape kept aside")
    },
    test("what a shape needs is the kind's word for a message, or nothing") {
        let h = try graph(more: [EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        expectEqual(standIns.needs(Echo.kind), "ajar")
        expectEqual(standIns.needs(Mute.kind), nil)
        expectEqual(standIns.needs(Box.kind), nil)
        expectEqual(try graph(more: [EchoesPlugin(needs: nil)]).editor.registry.standIns.needs(Echo.kind), nil)
    },
    test("a stand-in is made from what the kind's tool places, at the origin, then made to stand for the shape by the kind and put in step: its id is new, and it stands for it") {
        let target = ShapeID()
        let h = try graph(CanvasFile(root: board(ajar(target))), more: [EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        let made = try require(standIns.make(Echo.kind, standingFor: target, label: "Target"))
        let echo = try require(made.typed(as: Echo.self))
        expectEqual(echo.props.cites?.shape, target)
        expectEqual(echo.props.says, "Target")
        expectEqual(echo.props.frame.width, Echo.width(saying: "Target"), "put in step: its width follows its words")
        expectEqual(echo.props.frame.height, 30, "the size the tool places")
        expectEqual(made.box?.midY, 0, "at the origin, as the tool places it centered there")
        expect(h.editor.document[made.id] == nil, "in no document")
        expect(made.id != target)
        expectEqual(standIns.forwarding(of: made), .shapes([target]))
        // Put on the board, it stands for the shape in the graph.
        h.editor.transact { $0.insert(made) }
        expectEqual(h.topology.forwards(of: made.id), [target])
        // Two made are two shapes.
        let another = try require(standIns.make(Echo.kind, standingFor: target, label: "Target"))
        expect(another.id != made.id)
        // The kind's hook gets the blank, and the label as given, however long.
        let long = try require(standIns.make(Echo.kind, standingFor: target, label: String(repeating: "w", count: 40)))
        expectEqual(long.typed(as: Echo.self)?.props.frame.width, Echo.width(saying: String(repeating: "w", count: 40)))
    },
    test("what a stand-in calls what it stands for is its kind's word for it, or nothing: a kind that says nothing, one that calls it nothing, a shape that doesn't stand in") {
        let target = ShapeID()
        let h = try graph(CanvasFile(root: board(ajar(target))), more: [EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        let made = try require(standIns.make(Echo.kind, standingFor: target, label: "Target"))
        expectEqual(standIns.calls(made), "Target")
        expectEqual(standIns.calls(try require(standIns.make(Echo.kind, standingFor: target, label: ""))), nil, "called nothing")
        expectEqual(standIns.calls(AnyShapeRecord(ShapeRecord(Mute(unit, cites: target)))), nil, "the mute says nothing")
        expectEqual(standIns.calls(try require(h.editor.document[target])), nil, "a box doesn't stand in")
    },
    test("a shape is fulfilled by the kind's own word, on a copy kept only if the kind then admits it: an admitted one is left, one the kind can't make so is left") {
        let shut = ShapeID(), open = ShapeID()
        let h = try graph(CanvasFile(root: board(box(shut), ajar(open))), more: [EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        var record = try require(h.editor.document[shut])
        expect(!standIns.admits(Echo.kind, record))
        expect(standIns.fulfil(Echo.kind, &record))
        expectEqual(record.meta[Ajar.self], true, "made so")
        expect(standIns.admits(Echo.kind, record))
        expect(h.editor.document[shut]?.meta[Ajar.self] == nil, "a record, not the document")
        var admitted = try require(h.editor.document[open])
        expect(standIns.fulfil(Echo.kind, &admitted), "already admitted")
        var other = try require(h.editor.document[shut])
        expect(standIns.fulfil(Mute.kind, &other), "a kind that says nothing and admits anything has nothing to do")
        expect(!standIns.fulfil(Box.kind, &other), "a kind that doesn't stand in")
        expect(other.meta[Ajar.self] == nil, "and nothing written")
        // A fulfilling that does not make it admissible leaves the record as it was.
        let stubborn = try graph(CanvasFile(root: board(box(shut))), more: [EchoesPlugin(fulfils: false)])
        var untouched = try require(stubborn.editor.document[shut])
        expect(!stubborn.editor.registry.standIns.fulfil(Echo.kind, &untouched))
        expect(untouched.meta[Ajar.self] == nil)
        // One that changes the copy first, then fails or admits nothing, leaves the record as it was too.
        for answer in [false, true] {
            let spoiling = try graph(CanvasFile(root: board(box(shut))), more: [EchoesPlugin(changesThenAnswers: answer)])
            var record = try require(spoiling.editor.document[shut])
            let before = record
            expect(!spoiling.editor.registry.standIns.fulfil(Echo.kind, &record), "not fulfilled (answering \(answer))")
            expectEqual(record, before, "unchanged (answering \(answer))")
        }
    },
    test("a kind that says nothing of how it's made, or whose tool doesn't place it, can't be made to stand for a shape") {
        let target = ShapeID()
        let h = try graph(CanvasFile(root: board(ajar(target))), more: [StandInsPlugin(), EchoesPlugin()])
        let standIns = h.editor.registry.standIns
        expectEqual(standIns.make(Mute.kind, standingFor: target, label: "T")?.kind, nil, "its rule has no way")
        expectEqual(standIns.make(Phantom.kind, standingFor: target, label: "T")?.kind, nil, "no tool places it")
        expectEqual(standIns.make(Proxy.kind, standingFor: target, label: "T")?.kind, nil)
        expectEqual(standIns.make(Box.kind, standingFor: target, label: "T")?.kind, nil, "a kind that doesn't stand in")
    },
    test("making a stand-in doesn't ask whether it may stand for the shape: whoever puts it down does, and one for a shape it may not stand for stands for nothing") {
        let shut = ShapeID()
        let h = try graph(CanvasFile(root: board(box(shut))), more: [EchoesPlugin()])
        let made = try require(h.editor.registry.standIns.make(Echo.kind, standingFor: shut, label: "Shut"))
        h.editor.transact { $0.insert(made) }
        expectEqual(h.topology.forwards(of: made.id), [], "the graph's rule is the admission's: it stands for nothing")
        expectEqual(h.topology.forwarding(of: made.id), .record([]))
    },
])
