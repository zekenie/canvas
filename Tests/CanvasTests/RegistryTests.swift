import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
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

/// A point that says how the report shows its contributions.
enum Described {}

extension Described: ExtensionPoint {
    typealias Contribution = String
    static var owner: PluginID { "stamps" }
    static func summary(of contribution: String, for _: ShapeTarget) -> String { "described \(contribution)" }
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
    test("the product's text files are in the product's executables alone: this one, which isn't, has none") {
        expectEqual(ShippedText.named("ask-prompt"), nil)
        expectEqual(ShippedText.named(""), nil)
    },
    test("a list's plugins are made by name, in its order: each a type this executable has that can be made from nothing") {
        let plugins = try ShippedList.plugins(named: ["CanvasTests.SecondListed", "CanvasTests.FirstListed"])
        expectEqual(plugins.map(\.id), ["second-listed", "first-listed"], "the list's order, not the order they're declared in")
        _ = try Registry(plugins: plugins)
        expectEqual(try ShippedList.plugins(named: []).count, 0)
    },
    test("a list is refused, saying which line, for a name that isn't Module.Type, a type that isn't here, and one that can't be made from nothing") {
        for line in ["FirstListed", "CanvasTests.", ".FirstListed", "CanvasTests.First.Listed", "Canvas Tests.FirstListed", ""] {
            expectThrows(ShippedListError.malformed(line)) { _ = try ShippedList.plugins(named: ["CanvasTests.FirstListed", line]) }
        }
        expectThrows(ShippedListError.notFound("CanvasTests.Mislisted")) { _ = try ShippedList.plugins(named: ["CanvasTests.Mislisted"]) }
        expectThrows(ShippedListError.notFound("Nowhere.FirstListed")) { _ = try ShippedList.plugins(named: ["Nowhere.FirstListed"]) }
        expectThrows(ShippedListError.notListed("CanvasTests.NeverListed")) { _ = try ShippedList.plugins(named: ["CanvasTests.NeverListed"]) }
        expectThrows(ShippedListError.notListed("CanvasTests.NotAPlugin")) { _ = try ShippedList.plugins(named: ["CanvasTests.NotAPlugin"]) }
        expect(ShippedListError.notFound("Boards.BoardsPlugin").description.contains("Boards.BoardsPlugin"))
    },
    test("a plugin that reaches outside the process is the caller's to hand over: the list won't make one, and takes the caller's in its place") {
        let names = ["CanvasTests.FirstListed", "CanvasTests.Outward", "CanvasTests.SecondListed"]
        expectThrows(ShippedListError.notSupplied(["CanvasTests.Outward"])) { _ = try ShippedList.plugins(named: names) }
        let plugins = try ShippedList.plugins(named: names, supplying: [Outward(reaching: "a test's own")])
        expectEqual(plugins.map(\.id), ["first-listed", "outward", "second-listed"], "in the list's place for it")
        expectEqual((plugins[1] as? Outward)?.reaching, "a test's own", "the one handed over, not one made from nothing")
        // Any listed plugin can be handed over; one the list hasn't is refused, so a typo can't pass for a swap.
        let own = try ShippedList.plugins(named: names, supplying: [Outward(reaching: "own"), SecondListed(note: "own")])
        expectEqual((own[2] as? SecondListed)?.note, "own")
        expectThrows(ShippedListError.notInList(["CanvasTests.NeverListed"])) {
            _ = try ShippedList.plugins(named: names, supplying: [Outward(reaching: "own"), NeverListed()])
        }
        expect(ShippedListError.notSupplied(["CanvasTests.Outward"]).description.contains("supplying"), "it says what to do")
    },
    test("only the product has a list: this executable, which isn't, has none to load") {
        expectEqual(ShippedList.names, nil)
        expectThrows(ShippedListError.notTheProduct) { _ = try ShippedList.plugins(supplying: []) }
    },
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
    test("a tool id that's taken conflicts") {
        expectThrows(RegistryError.conflict(point: "Tools", key: "tool hand", plugins: ["core", "clash"])) {
            _ = try Registry(plugins: [Contributor(id: "clash") {
                $0.tool(ToolDescriptor(id: .hand, label: "Mine", systemImage: "circle")) { _ in NoTool() }
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
    test("a kind is called what it declares, else its placing tool's label and symbol, else its id; a second label for it conflicts") {
        let registry = try Registry(plugins: [CardsPlugin { card, _ in card.label("Index Card", systemImage: "menucard") }, discTools(),
                                              Contributor(id: "boxes") { $0.shape(BoxDefinitionForTests()) }])
        expectEqual(registry.label(of: Card.kind), KindLabel(name: "Index Card", systemImage: "menucard"), "declared, over its tool's")
        expectEqual(registry.label(of: Disc.kind), KindLabel(name: "Disc", systemImage: "circle"), "its tool's")
        expectEqual(registry.label(of: Box.kind), KindLabel(name: "box", systemImage: nil), "its id")
        expect(registry.report.contains("label Index Card → card"), registry.report)
        expectThrows(RegistryError.conflict(point: "KindLabels", key: "the label of card", plugins: ["cards", "cards"])) {
            _ = try Registry(plugins: [CardsPlugin { card, _ in
                card.label("Index Card", systemImage: "menucard")
                card.label("Card", systemImage: "rectangle")
            }])
        }
    },
    test("a kind's label carries the tint it declares, whichever names it; none for a kind that declares none; a second tint for it conflicts") {
        let registry = try Registry(plugins: [CardsPlugin { card, _ in
            card.label("Index Card", systemImage: "menucard")
            card.tint(.systemTeal)
        }, Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
                disc.tint(.systemOrange)
            }
        }, Contributor(id: "boxes") { $0.shape(BoxDefinitionForTests()) }])
        expectEqual(registry.label(of: Card.kind), KindLabel(name: "Index Card", systemImage: "menucard", tint: .systemTeal), "with its declared label")
        expectEqual(registry.label(of: Disc.kind), KindLabel(name: "Disc", systemImage: "circle", tint: .systemOrange), "with its tool's")
        expectEqual(registry.label(of: Box.kind).tint, nil)
        expect(registry.report.contains("tint → card"), registry.report)
        expectThrows(RegistryError.conflict(point: "KindTints", key: "the tint of card", plugins: ["cards", "cards"])) {
            _ = try Registry(plugins: [CardsPlugin { card, _ in
                card.tint(.systemTeal)
                card.tint(.systemPink)
            }])
        }
    },
    test("the toolbar is the core's Hand tool, then each plugin's tools in plugin order") {
        let registry = try Registry(plugins: [CardsPlugin(), Contributor(id: "x") {
            $0.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt")) { _ in NoTool() }
        }])
        expectEqual(registry.tools.map(\.id), [.hand, ToolID(placing: Card.kind), "zap"])
        expectEqual(registry.tools.map(\.label), ["Hand", "Card", "Zap"])
    },
    test("a claimed default tool leads the toolbar, and the editor starts in it") {
        let registry = try Registry(plugins: [CardsPlugin(), Contributor(id: "x") {
            $0.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt")) { _ in NoTool() }
            $0.defaultTool("zap")
        }])
        expectEqual(registry.defaultTool, "zap")
        expectEqual(registry.tools.map(\.id), ["zap", .hand, ToolID(placing: Card.kind)])
        expectEqual(CanvasEditor(registry: registry, scheduler: ManualScheduler()).currentToolID, "zap")
    },
    test("any plugin's tool can be the default; one that isn't registered is invalid, and two claims conflict") {
        let registry = try Registry(plugins: [CardsPlugin(), Contributor(id: "x") { $0.defaultTool(ToolID(placing: Card.kind)) }])
        expectEqual(registry.defaultTool, ToolID(placing: Card.kind))
        expectThrows(RegistryError.invalid(point: "DefaultTool", reason: "no plugin registers tool zap")) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.defaultTool("zap") }])
        }
        expectThrows(RegistryError.conflict(point: "DefaultTool", key: "the default tool", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.defaultTool(.hand) }, Contributor(id: "y") { $0.defaultTool(.hand) }])
        }
    },
    test("a command runs what its plugin claimed; an unclaimed one reports false; two claims conflict") {
        let ran = RunLog()
        let editor = CanvasEditor(registry: try Registry(plugins: [Contributor(id: "x") { r in
            r.command("scrap", title: "Scrap") { _ in ran.commands.append("scrap") }
            r.command("custom", title: "Custom") { _ in ran.commands.append("custom") }
        }]), scheduler: ManualScheduler())
        expect(editor.perform("scrap"))
        expect(editor.perform("custom"))
        expect(!editor.perform("unclaimed"))
        expectEqual(ran.commands, ["scrap", "custom"])
        expectThrows(RegistryError.conflict(point: "Commands", key: "scrap", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.command("scrap", title: "Scrap") { _ in } },
                                       Contributor(id: "y") { $0.command("scrap", title: "Scrap") { _ in } }])
        }
    },
    test("a command named for the step it would take says so with a menu title that follows the editor; its title stays what it is called") {
        let step = RunLog()
        let editor = CanvasEditor(registry: try Registry(plugins: [Contributor(id: "x") { r in
            r.command("climb", title: "Climb", menuTitle: { _ in "Climb " + (step.commands.last ?? "nothing") }) { _ in }
            r.command("plain", title: "Plain") { _ in }
        }]), scheduler: ManualScheduler())
        expectEqual(editor.menuTitle(of: "climb"), "Climb nothing")
        step.commands.append("a rung")
        expectEqual(editor.menuTitle(of: "climb"), "Climb a rung", "asked afresh each time")
        expectEqual(editor.registry.title(of: "climb"), "Climb", "what it is called wherever it is listed")
        expectEqual(editor.menuTitle(of: "plain"), nil, "a command whose item keeps its own title")
        expectEqual(editor.menuTitle(of: "unclaimed"), nil)
    },
    test("a secondary click opens what its plugin makes, asked in world units; unclaimed or nil, nothing opens; two claims conflict") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "x") { r in
            r.menuForSecondaryClick { _, pointer in pointer.world.x > 100 ? NSMenu(title: "at \(Int(pointer.world.x))") : nil }
        }])
        h.editor.camera.setZoom(2, around: .zero)
        expectEqual(h.secondaryClick(at: CGPoint(x: 300, y: 10))?.title, "at 150")
        expect(h.secondaryClick(at: CGPoint(x: 100, y: 10)) == nil)
        expect(try EditorHarness(plugins: [FixturesPlugin()]).secondaryClick(at: CGPoint(x: 300, y: 10)) == nil)
        expectThrows(RegistryError.conflict(point: "SecondaryClickMenu", key: "the secondary-click menu", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.menuForSecondaryClick { _, _ in nil } },
                                       Contributor(id: "y") { $0.menuForSecondaryClick { _, _ in nil } }])
        }
    },
    test("the selection's menu is what its plugin makes, told the commands to leave out; unclaimed, the editor has none; two claims conflict") {
        let asked = RunLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "x") { r in
            r.menuForSelection { _, commands, _ in
                asked.commands.append(commands.map(\.rawValue).sorted().joined(separator: ","))
                return commands.isEmpty ? NSMenu(title: "everything") : nil
            }
        }])
        expectEqual(h.editor.menuForSelection(omitting: [])?.title, "everything")
        expect(h.editor.menuForSelection(omitting: ["cut", "copy"]) == nil)
        expectEqual(asked.commands, ["", "copy,cut"])
        expect(try EditorHarness(plugins: [FixturesPlugin()]).editor.menuForSelection(omitting: []) == nil)
        expectThrows(RegistryError.conflict(point: "SelectionMenu", key: "the selection's menu", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.menuForSelection { _, _, _ in nil } },
                                       Contributor(id: "y") { $0.menuForSelection { _, _, _ in nil } }])
        }
    },
    test("a key stroke goes to the one plugin that claims key strokes, as it came; unclaimed, no key does anything; two claims conflict") {
        let seen = RunLog()
        let h = try EditorHarness(plugins: [Contributor(id: "x") { r in
            r.keyStrokes { _, stroke in
                seen.commands.append("\(stroke.characters) \(stroke.modifiers == .command ? "⌘" : "") \(stroke.isRepeat)")
                return stroke.characters == "k"
            }
        }])
        h.hold(.command)
        expect(h.key("k"))
        h.hold([])
        expect(!h.key("q", isRepeat: true))
        expectEqual(seen.commands, ["k ⌘ false", "q  true"])
        expect(!(try EditorHarness(plugins: []).key("h")), "the core gives no key a meaning, the Hand's H included")
        expectThrows(RegistryError.conflict(point: "KeyStrokes", key: "key strokes", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.keyStrokes { _, _ in false } }, Contributor(id: "y") { $0.keyStrokes { _, _ in true } }])
        }
    },
    test("a secondary click isn't asked while a press is under way (the hand's, here)") {
        let asked = RunLog()
        let h = try EditorHarness(plugins: [Contributor(id: "x") { r in
            r.menuForSecondaryClick { _, _ in asked.commands.append("menu"); return NSMenu() }
        }])
        h.press(at: CGPoint(x: 10, y: 10))
        expect(h.secondaryClick() == nil)
        h.release()
        expect(h.secondaryClick() != nil)
        expectEqual(asked.commands, ["menu"])
    },
    test("the report lists who contributes what") {
        let registry = try Registry(plugins: [FixturesPlugin(), CardsPlugin(), StampsPlugin(),
                                              Contributor(id: "p") { r in
                                                  r.contribute("x", to: Stamps.self, for: .kind(Card.kind))
                                                  r.outlines { _ in Outlines() }
                                                  r.command("scrap", title: "Scrap", in: EditMenu.CutCopyPaste.self) { _ in }
                                                  r.defaultTool(ToolID(placing: Card.kind))
                                                  r.menuForSecondaryClick { _, _ in nil }
                                                  r.menuForSelection { _, _, _ in nil }
                                                  r.keyStrokes { _, _ in false }
                                                  r.contribute("x", to: Described.self)
                                              }])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        fixtures      shape box · shape disc · shape tag
        cards         shape card · tool card · command insert:card in InsertMenu.Shapes
        stamps        \("")
        p             Stamps → card · outlines · command scrap in EditMenu.CutCopyPaste · default tool card · secondary-click menu · selection menu · key strokes · described x
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

// Two services whose types share a name, as two plugins' private engines might.
enum Left { final class Engine: EditorService {} }
enum Right { final class Engine: EditorService {} }

/// Made first, and needs `Late`, which a plugin further down the list registers.
final class Early: EditorService {
    let late: Late?
    init(late: Late?) { self.late = late }
}
final class Late: EditorService {}

@MainActor final class RunLog {
    var commands: [String] = []
}


// MARK: Plugins a list can name

/// Plugins the loader finds in this executable by name (`CanvasTests.FirstListed`): two made from
/// nothing, one that reaches outside the process, one that's a plugin but can't be listed, and a
/// type that's no plugin at all.
struct FirstListed: ListedPlugin {
    init() {}
    var id: PluginID { "first-listed" }
    func register(into registrar: inout PluginRegistrar) {}
}

struct SecondListed: ListedPlugin {
    let note: String
    init() { note = "" }
    init(note: String) { self.note = note }
    var id: PluginID { "second-listed" }
    func register(into registrar: inout PluginRegistrar) {}
}

struct Outward: OutwardPlugin {
    let reaching: String
    init() { reaching = "the world" }
    init(reaching: String) { self.reaching = reaching }
    var id: PluginID { "outward" }
    func register(into registrar: inout PluginRegistrar) {}
}

struct NeverListed: CanvasPlugin {
    var id: PluginID { "never-listed" }
    func register(into registrar: inout PluginRegistrar) {}
}

struct NotAPlugin {}
