@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// A horizontal declared by a test plugin: the core has never heard of it.
enum Stamps: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
}

/// One stamp per kind at most: a keyed, single-valued point.
enum Titles: KeyedExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    static func uniqueKeys(of _: String, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// A point with a rule that spans contributions: it logs each check, and refuses "refuse".
enum Checked {}

extension Checked: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    @MainActor static var log: [String] = []
    static func check(_ registry: Registry) throws(RegistryError) {
        let mine = registry.contributions(to: Checked.self).map(\.value)
        let stamps = registry.contributions(to: Stamps.self).map(\.value)
        log.append("\(mine.joined(separator: ",")) with stamps \(stamps.joined(separator: ","))")
        if mine.contains("refuse") { throw .invalid(point: "Checked", reason: "a contribution refused") }
    }
}

/// A check spelled with plain `throws`, throwing its own error: the registry still runs it.
enum Untyped {}

extension Untyped: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    struct Refusal: Error, CustomStringConvertible { var description: String { "refused" } }
    static func check(_ registry: Registry) throws { throw Refusal() }
}

struct StampsPlugin: CanvasPlugin {
    var id: PluginID { "stamps" }
    func register(into registrar: inout PluginRegistrar) {}
}

extension ShapeRegistrar {
    /// Sugar a horizontal would publish: the kind is stamped for you.
    mutating func stamp(_ text: String) { contribute(text, to: Stamps.self) }
}

@MainActor let registryTests = Suite("Registry", [
    test("a contribution made inside a shape's registrar is stamped with its kind") {
        let registry = try Registry(plugins: [StampsPlugin(), Contributor(id: "boxes") { r in
            r.shape(BoxDefinitionForTests()) { box in box.stamp("hello") }
        }])
        let stamps = registry.contributions(to: Stamps.self)
        expectEqual(stamps.map(\.value), ["hello"])
        expectEqual(stamps.map(\.target), [.kind(Box.kind)])
        expectEqual(stamps.map(\.pluginID), ["boxes"])
    },
    test("kind-specific contributions come before wildcards, each in plugin order") {
        let registry = try Registry(plugins: [
            FixturesPlugin(), StampsPlugin(),
            Contributor(id: "a") { $0.contribute("any-a", to: Stamps.self, for: .any) },
            Contributor(id: "b") { $0.contribute("box-b", to: Stamps.self, for: .kind(Box.kind)) },
            Contributor(id: "c") { $0.contribute("box-c", to: Stamps.self, for: .kind(Box.kind)); $0.contribute("any-c", to: Stamps.self) },
        ])
        expectEqual(registry.contributions(to: Stamps.self, for: Box.kind), ["box-b", "box-c", "any-a", "any-c"])
        expectEqual(registry.contributions(to: Stamps.self, for: Disc.kind), ["any-a", "any-c"])
    },
    test("contributing to a point whose owner isn't installed is an error") {
        expectThrows(RegistryError.ownerNotInstalled(point: "Stamps", owner: "stamps", contributor: "lonely")) {
            _ = try Registry(plugins: [Contributor(id: "lonely") { $0.contribute("x", to: Stamps.self) }])
        }
    },
    test("contributing for a kind no plugin registers is an error") {
        expectThrows(RegistryError.unknownKind("nope", point: "Stamps", contributor: "p")) {
            _ = try Registry(plugins: [StampsPlugin(), Contributor(id: "p") { $0.contribute("x", to: Stamps.self, for: .kind("nope")) }])
        }
    },
    test("a plugin installed twice is an error") {
        expectThrows(RegistryError.duplicatePlugin("fixtures")) { _ = try Registry(plugins: [FixturesPlugin(), FixturesPlugin()]) }
    },
    test("two plugins registering one kind conflict") {
        expectThrows(RegistryError.conflict(point: "Shapes", key: "box", plugins: ["fixtures", "more"])) {
            _ = try Registry(plugins: [FixturesPlugin(), FixturesPlugin(id: "more")])
        }
    },
    test("a shortcut that's taken conflicts, whatever its case, including the core's V") {
        expectThrows(RegistryError.conflict(point: "Tools", key: "shortcut v", plugins: ["core", "clash"])) {
            _ = try Registry(plugins: [Contributor(id: "clash") {
                $0.tool(ToolDescriptor(id: "other", label: "Other", systemImage: "circle", shortcut: "V")) { _ in NoTool() }
            }])
        }
    },
    test("a tool id that's taken conflicts") {
        expectThrows(RegistryError.conflict(point: "Tools", key: "tool select", plugins: ["core", "clash"])) {
            _ = try Registry(plugins: [Contributor(id: "clash") {
                $0.tool(ToolDescriptor(id: .select, label: "Mine", systemImage: "circle")) { _ in NoTool() }
            }])
        }
    },
    test("only one kind may claim double-clicking empty canvas") {
        expectThrows(RegistryError.conflict(point: "DoubleClickPlacement", key: "double-click on empty canvas", plugins: ["cards", "more-cards"])) {
            _ = try Registry(plugins: [CardsPlugin(), Contributor(id: "more-cards") { r in
                r.shape(BoxDefinitionForTests()) { box in box.createOnDoubleClick(box.placement(size: .zero) { Box(.zero) }) }
            }])
        }
    },
    test("a keyed point rejects a second contribution for the same target") {
        expectThrows(RegistryError.conflict(point: "Titles", key: "box", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [FixturesPlugin(), StampsPlugin(),
                                       Contributor(id: "a") { $0.contribute("A", to: Titles.self, for: .kind(Box.kind)) },
                                       Contributor(id: "b") { $0.contribute("B", to: Titles.self, for: .kind(Box.kind)) }])
        }
    },
    test("the toolbar is the core's select tool, then each plugin's tools in plugin order") {
        let registry = try Registry(plugins: [CardsPlugin(), Contributor(id: "x") {
            $0.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt", shortcut: "z")) { _ in NoTool() }
        }])
        expectEqual(registry.tools.map(\.id), [.select, ToolID(placing: Card.kind), "zap"])
        expectEqual(registry.tool(forShortcut: "C"), ToolID(placing: Card.kind))
        expectEqual(registry.tools.map(\.label), ["Select", "Card", "Zap"])
        expectEqual(registry.tools.map(\.shortcut), ["v", "c", "z"])
    },
    test("the report lists who contributes what") {
        let registry = try Registry(plugins: [FixturesPlugin(), CardsPlugin(), StampsPlugin(),
                                              Contributor(id: "p") { $0.contribute("x", to: Stamps.self, for: .kind(Card.kind)) }])
        expectEqual(registry.report, """
        core          tool select [v]
        fixtures      shape box · shape disc · shape tag
        cards         shape card · tool card [c] · double-click card
        stamps        \("")
        p             Stamps → card
        """)
    },
    test("a plain point takes any number of contributions for one target, as a list") {
        let registry = try Registry(plugins: [FixturesPlugin(), StampsPlugin(),
                                              Contributor(id: "a") { $0.contribute("A", to: Stamps.self, for: .kind(Box.kind)) },
                                              Contributor(id: "b") { $0.contribute("B", to: Stamps.self, for: .kind(Box.kind)) }])
        expectEqual(registry.contributions(to: Stamps.self, for: Box.kind), ["A", "B"])
    },
    test("one service type registered twice conflicts; two types that only share a name don't") {
        expectThrows(RegistryError.conflict(point: "Services", key: "CanvasTests.Left.Engine", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [Contributor(id: "a") { $0.service { _ in Left.Engine() } },
                                       Contributor(id: "b") { $0.service { _ in Left.Engine() } }])
        }
        let registry = try Registry(plugins: [Contributor(id: "a") { $0.service { _ in Left.Engine() } },
                                              Contributor(id: "b") { $0.service { _ in Right.Engine() } }])
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        expect(editor.service(Left.Engine.self) != nil)
        expect(editor.service(Right.Engine.self) != nil)
    },
    test("a service can look up another plugin's service, whatever their order in the plugin list") {
        let editor = CanvasEditor(registry: try Registry(plugins: [
            Contributor(id: "early") { $0.service { Early(late: $0.service(Late.self)) } },
            Contributor(id: "late") { $0.service { _ in Late() } },
        ]), scheduler: ManualScheduler())
        let late = try require(editor.service(Late.self))
        expect(editor.service(Early.self)?.late === late)
    },
    test("a point's check refuses the plugin list by throwing invalid") {
        expectThrows(RegistryError.invalid(point: "Checked", reason: "a contribution refused")) {
            _ = try Registry(plugins: [StampsPlugin(), Contributor(id: "p") { $0.contribute("refuse", to: Checked.self) }])
        }
        expectEqual(RegistryError.invalid(point: "Checked", reason: "a contribution refused").description, "Checked: a contribution refused")
    },
    test("a check spelled with plain throws runs, and its error is invalid for its point") {
        expectThrows(RegistryError.invalid(point: "Untyped", reason: "refused")) {
            _ = try Registry(plugins: [StampsPlugin(), Contributor(id: "p") { $0.contribute("x", to: Untyped.self) }])
        }
    },
    test("a point's check runs once, on the built registry, and can read other points") {
        Checked.log = []
        _ = try Registry(plugins: [StampsPlugin(),
                                   Contributor(id: "a") { $0.contribute("one", to: Checked.self); $0.contribute("s", to: Stamps.self) },
                                   Contributor(id: "b") { $0.contribute("two", to: Checked.self) }])
        expectEqual(Checked.log, ["one,two with stamps s"])
    },
    test("a point nobody contributes to is never checked") {
        Checked.log = []
        _ = try Registry(plugins: [StampsPlugin(), Contributor(id: "a") { $0.contribute("s", to: Stamps.self) }])
        expectEqual(Checked.log, [])
    },
    test("a point's check runs after the owner, kind and key checks") {
        Checked.log = []
        expectThrows(RegistryError.ownerNotInstalled(point: "Checked", owner: "stamps", contributor: "p")) {
            _ = try Registry(plugins: [Contributor(id: "p") { $0.contribute("refuse", to: Checked.self) }])
        }
        expectThrows(RegistryError.unknownKind("nope", point: "Checked", contributor: "p")) {
            _ = try Registry(plugins: [StampsPlugin(), Contributor(id: "p") { $0.contribute("refuse", to: Checked.self, for: .kind("nope")) }])
        }
        expectThrows(RegistryError.conflict(point: "Titles", key: "box", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [FixturesPlugin(), StampsPlugin(),
                                       Contributor(id: "a") { $0.contribute("refuse", to: Checked.self); $0.contribute("A", to: Titles.self, for: .kind(Box.kind)) },
                                       Contributor(id: "b") { $0.contribute("B", to: Titles.self, for: .kind(Box.kind)) }])
        }
        expectEqual(Checked.log, [])
    },
    test("a capability conformance declared in a file nothing names survives static linking") {
        let registry = try Registry(plugins: [LinkerGuardPlugin()])
        expect(registry.definition(for: Sealed.kind) is any Editable)
    },
])

struct BoxDefinitionForTests: ShapeDefinition {
    func render(_ shape: ShapeRecord<Box>, in context: RenderContext) {}
}

final class NoTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {}
}

// Two services whose types share a name, as two plugins' private engines might.
enum Left { final class Engine: EditorService {} }
enum Right { final class Engine: EditorService {} }

/// Made first, and needs `Late`, which a plugin further down the list registers.
final class Early: EditorService {
    let late: Late?
    init(late: Late?) { self.late = late }
}
final class Late: EditorService {}
