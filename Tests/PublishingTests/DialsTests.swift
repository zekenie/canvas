@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Publishing
import TestKit
import Topology

@MainActor let dialsTests = Suite("Public, always and never", [
    test("a kind opts in unless it's always public or never public; the property is a boolean Publishing owns") {
        let h = try publishingHarness()
        let registry = h.editor.registry
        for kind: ShapeKind in ["plaque", "box", "disc"] {
            expect(registry.properties(for: kind).contains("private"), "\(kind) holds it")
            let properties = try require(registry.schema(for: kind)?.json["properties"]?.objectValue)
            expectEqual(properties["private"], ["type": "boolean", "x-canvas-owner": "publishing"], "\(kind)")
        }
        for kind: ShapeKind in ["seal", "draft", "holder", "relay"] {
            expect(!registry.properties(for: kind).contains("private"), "\(kind) holds none")
        }
    },
    test("isPublic and canBePublic: a shape of a kind that holds the property until it's made private, and an always-public kind's") {
        let h = try publishingHarness()
        let registry = h.editor.registry
        let plaque = h.add(Plaque(plaqueFrame)), seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame))
        let record = { (id: ShapeID) in h.editor.document[id]! }
        expect(registry.isPublic(record(plaque)), "a plaque is public until it's made private")
        expectEqual(record(plaque)[PrivateProperty.self], nil, "and holds nothing for it")
        expect(registry.isPublic(record(seal)), "a seal always is")
        expect(!registry.isPublic(record(draft)))
        h.conceal(plaque)
        expect(!registry.isPublic(record(plaque)))
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true)
        expect(registry.canBePublic("plaque") && registry.canBePublic("seal"))
        expect(!registry.canBePublic("draft"), "never")
        expect(!registry.canBePublic("holder"))
    },
    test("makePublic on a record is the one writer that takes private away: a private shape is made public, a public or always-public one already is, a never-public one refuses and is left as it was") {
        let h = try publishingHarness()
        let registry = h.editor.registry
        let plaque = h.add(Plaque(plaqueFrame)), seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame))
        h.conceal(plaque)
        var record = try require(h.editor.document[plaque])
        expect(registry.makePublic(&record))
        expectEqual(record[PrivateProperty.self], nil)
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], true, "a record, not the document")
        expect(registry.makePublic(&record), "already public")
        var sealed = try require(h.editor.document[seal])
        let sealedBefore = sealed
        expect(registry.makePublic(&sealed), "always public")
        expect(sealed == sealedBefore, "and nothing written")
        var drafted = try require(h.editor.document[draft])
        let before = drafted
        expect(!registry.makePublic(&drafted), "never public")
        expect(drafted == before)
        // The editor's writer goes through it.
        h.editor.makePublic([plaque, draft])
        expectEqual(h.editor.document[plaque]?[PrivateProperty.self], nil)
        expectEqual(h.editor.document[draft]?[PrivateProperty.self], nil)
    },
    test("a definition that adopts both dials is refused when the registry is built") {
        do {
            _ = try Registry(plugins: publishingPlugins([Contributor(id: "both") { r in r.shape(BothDefinition()) }]))
            expect(false, "the registry took a kind that's both")
        } catch let error as RegistryError {
            guard case .invalid(let point, let reason) = error else { return expect(false, "\(error)") }
            expectEqual(point, "PublishingDials")
            expect(reason.contains("both"), reason)
        }
    },
    test("`admitting` is built once, when the editor is, and says what's public, always public and not a stand-in") {
        let h = try publishingHarness()
        let admitting = try require(h.editor.publishing).admitting
        let plaque = h.add(Plaque(plaqueFrame)), seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame))
        let holder = h.hold([seal])
        expect(admitting(h.editor.document[plaque]!), "public, as every plaque starts")
        h.conceal(plaque)
        expect(!admitting(h.editor.document[plaque]!), "once it's made private, by the same closure")
        expect(admitting(h.editor.document[seal]!))
        expect(!admitting(h.editor.document[draft]!))
        expect(!admitting(h.editor.document[holder]!), "a stand-in is never stood for")
        #if DEBUG
        expectEqual(h.editor.admittingMade, 1, "built at install, never again")
        #endif
    },
    test("`admittable` says what Make Public would admit: a private shape of a kind that can be public; never a public one, a seal, a draft or a stand-in") {
        let h = try publishingHarness()
        let admittable = try require(h.editor.publishing).admittable
        let plaque = h.add(Plaque(plaqueFrame)), seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(plaqueFrame))
        let holder = h.hold([seal])
        expect(!admittable(h.editor.document[plaque]!), "public: admitted already")
        h.conceal(plaque)
        expect(admittable(h.editor.document[plaque]!), "private, of a kind that can be public")
        expect(!admittable(h.editor.document[seal]!), "always public")
        expect(!admittable(h.editor.document[draft]!), "never public")
        expect(!admittable(h.editor.document[holder]!), "a stand-in is never stood for")
    },
    test("only a public shape is stood for: a plaque from the start, let go of in the commit that makes it private, and a seal's always") {
        let h = try publishingHarness()
        let plaque = h.add(Plaque(plaqueFrame)), seal = h.add(Seal(plaqueFrame))
        let holder = h.hold([plaque, seal])
        let topology = try require(h.editor.topology)
        expectEqual(topology.forwards(of: holder), [plaque, seal], "every plaque is public until it's made private")
        h.editor.transact { $0.update(plaque) { $0[PrivateProperty.self] = true } }        // a path with no guard: a hand-edited board
        expectEqual(topology.forwards(of: holder), [seal], "made private, the plaque drops out in that commit, nothing asked")
        h.editor.undo()
        expectEqual(topology.forwards(of: holder), [plaque, seal], "public again by undo")
    },
])
