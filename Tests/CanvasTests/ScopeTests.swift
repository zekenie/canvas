@_spi(Host) import Canvas
import CanvasTesting
import TestKit

// Scopes: which kinds a contribution for many kinds reaches, resolved by the registry as it's built.

/// An added property that boxes opt into, for scopes that go by it.
enum Gilt {}

extension Gilt: ShapeProperty {
    static let key: PropertyKey = "gilt"
    static var defaultValue: Bool? { nil }
}

/// A point that takes scopes: a feature's face on other kinds' shapes says which.
enum Faces {}

extension Faces: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    static var scope: PointScope { .scoped }
}

/// One face a kind, and one for each scope: a keyed point that takes scopes.
enum KeyedFaces {}

extension KeyedFaces: KeyedExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    static var scope: PointScope { .scoped }
    static func uniqueKeys(of _: String, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// A point of one kind each.
enum PerKind {}

extension PerKind: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    static var scope: PointScope { .kinds }
}

/// The kinds a capability's test was asked about, in order.
@MainActor var roundAsked: [ShapeKind] = []

extension ShapeCapability {
    /// A fact the tests state: a disc is round. It notes each kind it's asked about.
    static let round = ShapeCapability("that is round") { kind in
        roundAsked.append(kind.kind)
        return kind.kind == Disc.kind
    }
}

extension ScopedRegistrar {
    /// Sugar a horizontal would publish for the shapes of other kinds.
    mutating func face(_ text: String) { contribute(text, to: Faces.self) }
}

/// Declares `Gilt`, and opts boxes into it.
private func gilding() -> Contributor {
    Contributor(id: "gilding") { r in
        r.declare(Gilt.self)
        r.optIn(Box.self, to: Gilt.self)
    }
}

@MainActor let scopeTests = Suite("Scopes", [
    test("a scoped contribution reaches only the kinds its scope names, after a kind's own, each in plugin order") {
        let registry = try Registry(plugins: [
            FixturesPlugin(), PocketsPlugin(), StampsPlugin(), gilding(),
            Contributor(id: "a") { r in
                r.forShapes(holding: Gilt.self) { $0.face("gilt") }
                r.forShapes(adopting: (any BoardOwning).self) { $0.face("board") }
                r.contribute("box-own", to: Faces.self, for: .kind(Box.kind))
            },
            Contributor(id: "b") { r in
                r.forEveryShape { $0.face("every") }
                r.forShapes(adopting: .round) { $0.face("round") }
            },
        ])
        expectEqual(registry.contributions(to: Faces.self, for: Box.kind), ["box-own", "gilt", "every"], "its own first, then what reaches it")
        expectEqual(registry.contributions(to: Faces.self, for: Disc.kind), ["every", "round"])
        expectEqual(registry.contributions(to: Faces.self, for: Pocket.kind), ["board", "every"])
        expectEqual(registry.contributions(to: Faces.self, for: Tag.kind), ["every"])
        expectEqual(registry.contributions(to: Faces.self, reaching: Box.kind).map(\.target),
                    [.kind(Box.kind), .holding(Gilt.key), .adopting(.everyKind)], "and with where each came from")
        expectEqual(registry.contributions(to: Faces.self, reaching: Box.kind).map(\.pluginID), ["a", "a", "b"])
    },
    test("a point that doesn't take scopes still reaches by them, beside its contributions for every kind") {
        let registry = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), gilding(), Contributor(id: "a") { r in
            r.contribute("any", to: Stamps.self)
            r.forShapes(holding: Gilt.self) { $0.contribute("gilt", to: Stamps.self) }
        }])
        expectEqual(registry.contributions(to: Stamps.self, for: Box.kind), ["any", "gilt"])
        expectEqual(registry.contributions(to: Stamps.self, for: Disc.kind), ["any"])
    },
    test("the report names each scope") {
        let registry = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), gilding(), Contributor(id: "a") { r in
            r.forShapes(holding: Gilt.self) { $0.face("gilt") }
            r.forShapes(adopting: (any BoardOwning).self) { $0.face("board") }
            r.forShapes(adopting: .round) { $0.face("round") }
            r.forEveryShape { $0.face("every") }
        }])
        expect(registry.report.contains("Faces → every shape holding gilt · Faces → every shape adopting BoardOwning · "
                                        + "Faces → every shape that is round · Faces → every shape"), registry.report)
        expectEqual("\(ShapeTarget.holding(Gilt.key))", "every shape holding gilt")
        expectEqual("\(ShapeTarget.adopting(.everyKind))", "every shape")
    },
    test("a point that takes scopes refuses a contribution for every shape that names none") {
        expectThrows(RegistryError.invalid(point: "Faces", reason: "lazy contributes for every shape with no scope; say which shapes it's for: "
                                           + "forShapes(holding:), forShapes(adopting:), or forEveryShape for what every shape has")) {
            _ = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), Contributor(id: "lazy") { $0.contribute("x", to: Faces.self) }])
        }
        let registry = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), Contributor(id: "every") { r in r.forEveryShape { $0.face("x") } }])
        expectEqual(registry.contributions(to: Faces.self, for: Disc.kind), ["x"], "every shape, said so, is a scope")
    },
    test("a point of one kind each refuses a scope and every kind, and takes a kind") {
        let refused: [(ShapeTarget, String)] = [(.any, "every shape"), (.holding(Gilt.key), "every shape holding gilt"), (.adopting(.everyKind), "every shape")]
        for (target, said) in refused {
            expectThrows(RegistryError.invalid(point: "PerKind", reason: "wide contributes for \(said); it takes one kind at a time")) {
                _ = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), gilding(),
                                           Contributor(id: "wide") { $0.contribute("x", to: PerKind.self, for: target) }])
            }
        }
        let registry = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), Contributor(id: "one") {
            $0.contribute("x", to: PerKind.self, for: .kind(Box.kind))
        }])
        expectEqual(registry.contributions(to: PerKind.self, for: Box.kind), ["x"])
    },
    test("a scope by a property no installed plugin declares is refused") {
        expectThrows(RegistryError.invalid(point: "Faces", reason: "p contributes for every shape holding gilt, which no installed plugin declares")) {
            _ = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), Contributor(id: "p") { r in r.forShapes(holding: Gilt.self) { $0.face("gilt") } }])
        }
    },
    test("two contributions that reach one kind can't claim one key there; a kind's own may, and comes first") {
        expectThrows(RegistryError.conflict(point: "KeyedFaces", key: "box", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [
                FixturesPlugin(), StampsPlugin(), gilding(),
                Contributor(id: "a") { r in r.forShapes(holding: Gilt.self) { $0.contribute("gilt", to: KeyedFaces.self) } },
                Contributor(id: "b") { r in r.forEveryShape { $0.contribute("every", to: KeyedFaces.self) } },
            ])
        }
        let registry = try Registry(plugins: [
            FixturesPlugin(), StampsPlugin(), gilding(),
            Contributor(id: "a") { r in r.forShapes(holding: Gilt.self) { $0.contribute("gilt", to: KeyedFaces.self) } },
            Contributor(id: "b") { r in r.forShapes(adopting: .round) { $0.contribute("round", to: KeyedFaces.self) } },
            Contributor(id: "c") { $0.contribute("box-own", to: KeyedFaces.self, for: .kind(Box.kind)) },
        ])
        expectEqual(registry.contributions(to: KeyedFaces.self, for: Box.kind), ["box-own", "gilt"],
                    "the kind's own first, so it's what a point that keeps the first of a key keeps")
        expectEqual(registry.contributions(to: KeyedFaces.self, for: Disc.kind), ["round"], "scopes that reach no kind together don't conflict")
    },
    test("a capability's test is asked once a kind, as the registry is built, however many contributions go by it") {
        roundAsked = []
        let registry = try Registry(plugins: [FixturesPlugin(), StampsPlugin(), Contributor(id: "a") { r in
            r.forShapes(adopting: .round) { $0.face("one"); $0.face("two") }
            r.forShapes(adopting: .round) { $0.face("three") }
        }])
        expectEqual(roundAsked.count, registry.kinds.count)
        expectEqual(Set(roundAsked), Set(registry.kinds))
        expectEqual(registry.contributions(to: Faces.self, for: Disc.kind), ["one", "two", "three"])
        expectEqual(registry.contributions(to: Faces.self, for: Box.kind), [])
        expectEqual(roundAsked.count, registry.kinds.count, "asking for contributions asks nothing more")
    },
    test("a kind as the registry has it says what it holds and what it adopts") {
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), NamingPlugin(), gilding()])
        let box = try require(registry.registeredKind(Box.kind))
        expect(box.holds(Gilt.self))
        expect(!box.adopts((any BoardOwning).self))
        expect(box.adopts(.box))
        let pocket = try require(registry.registeredKind(Pocket.kind))
        expect(pocket.adopts((any BoardOwning).self))
        expect(pocket.adopts(ShapeCapability((any BoardOwning).self)))
        expect(!pocket.holds(Gilt.self))
        expectEqual(registry.registeredKind(Tag.kind)?.adopts(.box), false, "a tag is no box")
        expectEqual(registry.registeredKind(Memo.kind)?.adopts(.namingShapes), true, "a memo holds citations")
        expectEqual(registry.registeredKind(Box.kind)?.adopts(.namingShapes), false)
        expectEqual(registry.registeredKind(Tag.kind)?.adopts(.everyKind), true)
        expect(registry.registeredKind("nope") == nil)
    },
    test("whether a target reaches a kind: its own, every kind's, a property's holders, a capability's kinds, resolved or asked") {
        roundAsked = []
        let registry = try Registry(plugins: [FixturesPlugin(), PocketsPlugin(), StampsPlugin(), gilding(),
                                              Contributor(id: "a") { r in r.forShapes(adopting: .round) { $0.face("round") } }])
        let asked = roundAsked.count
        expect(registry.reaches(.kind(Box.kind), Box.kind))
        expect(!registry.reaches(.kind(Box.kind), Disc.kind))
        expect(registry.reaches(.any, Disc.kind))
        expect(registry.reaches(.holding(Gilt.key), Box.kind))
        expect(!registry.reaches(.holding(Gilt.key), Disc.kind))
        expect(registry.reaches(.adopting(.round), Disc.kind))
        expect(!registry.reaches(.adopting(.round), Box.kind))
        expectEqual(roundAsked.count, asked, "a capability a scope names was worked out as the registry was built")
        expect(registry.reaches(.adopting(ShapeCapability((any BoardOwning).self)), Pocket.kind), "one no scope names is asked")
        expect(!registry.reaches(.adopting(ShapeCapability((any BoardOwning).self)), Box.kind))
    },
    test("a capability is a protocol's or a fact's, the same for the same protocol or phrase") {
        expectEqual(ShapeCapability((any BoardOwning).self), ShapeCapability((any BoardOwning).self))
        expect(ShapeCapability((any BoardOwning).self) != ShapeCapability((any ShapeContaining).self))
        expectEqual(ShapeCapability((any BoardOwning).self).phrase, "adopting BoardOwning")
        expectEqual(ShapeCapability("that is round") { _ in false }, .round, "a fact is named by its phrase")
        expectEqual(ShapeCapability.box.phrase, "with a box")
    },
])
