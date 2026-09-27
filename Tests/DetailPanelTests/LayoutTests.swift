import Canvas
import CanvasTesting
import DetailPanel
import SwiftUI
import TestKit

/// A tab type titled like DetailPanel's Style.
enum LookalikeStyleTab {}
extension LookalikeStyleTab: DetailTab { static var title: String { "Style" } }

// What the panel shows for a shape, resolved headlessly from the registry.
@MainActor let layoutTests = Suite("Detail layout", [
    test("a box nobody contributes to shows only Arrange: Size, then Position") {
        let editor = try gadgetEditor()
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).outline, ["Arrange: Size, Position"])
    },
    test("a kind without a frame has no tabs, and its header is its kind") {
        let editor = try gadgetEditor()
        let layout = try editor.layout(editor.add(Tag(target: nil)))
        expectEqual(layout.tabs, [])
        expectEqual(layout.header, DetailHeader("tag"))
    },
    test("a kind's own tabs lead in first appearance; a feature tab, Style and Arrange trail by order") {
        let editor = try gadgetEditor()
        // Remarks' tab is contributed first, but its order (50) puts it after the kind's own (0).
        expectEqual(try editor.layout(editor.add(Gadget(gadgetFrame, parts: [Gadget.Part()]))).outline, [
            "Gadget: main, Count", "Parts: Items", "Remarks: main", "Style: Color", "Arrange: Size, Position",
        ])
    },
    test("opting into a horizontal brings its tab, and only to the kinds that opt in") {
        let editor = try gadgetEditor([CardsPlugin()])
        expectEqual(editor.registry.contributions(to: Remarks.self).map(\.target), [.kind(Gadget.kind)])
        expect(try editor.layout(editor.add(Gadget(gadgetFrame))).tabs.contains(.of(RemarksTab.self)))
        expect(try !editor.layout(editor.add(Box(gadgetFrame))).tabs.contains(.of(RemarksTab.self)))
        expect(try !editor.layout(editor.add(Card(gadgetFrame))).tabs.contains(.of(RemarksTab.self)))
    },
    test("the opt-in needs its horizontal installed, and the panel") {
        expectThrows(RegistryError.ownerNotInstalled(point: "Remarks", owner: "remarks", contributor: "gadgets")) {
            _ = try Registry(plugins: [GadgetsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: "gadgets")) {
            _ = try Registry(plugins: [GadgetsPlugin(), RemarksPlugin()])
        }
    },
    test("within a tab: the kind's sections, then a bridge's, then every-box ones, each in plugin order") {
        let editor = try gadgetEditor([
            Contributor(id: "bridge") { r in
                r.details(Gadget.self) {
                    DetailSection("Shade", in: StyleTab.self) { _ in Text("Shade") }
                    DetailSection("Fit", in: ArrangeTab.self) { _ in Text("Fit") }
                }
            },
            Contributor(id: "grid") { r in r.detailsForEveryBox { DetailSection("Grid", in: ArrangeTab.self) { _ in Text("Grid") } } },
        ])
        let layout = try editor.layout(editor.add(Gadget(gadgetFrame)))
        expectEqual(layout.outline, ["Gadget: main, Count", "Remarks: main", "Style: Color, Shade", "Arrange: Fit, Size, Position, Grid"])
        expectEqual(layout.sections(in: .of(ArrangeTab.self)).map(\.description), ["gadget Arrange/Fit", "* Arrange/Size", "* Arrange/Position", "* Arrange/Grid"])
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).outline, ["Arrange: Size, Position, Grid"])
    },
    test("`when` hides a section, and a tab it leaves empty") {
        let editor = try gadgetEditor()
        let id = editor.add(Gadget(gadgetFrame))
        expect(try !editor.layout(id).tabs.contains(.of(PartsTab.self)))
        editor.transact { $0.update(id, as: Gadget.self) { $0.props.parts = [Gadget.Part()] } }
        expectEqual(try editor.layout(id).sections(in: .of(PartsTab.self)).map(\.section), ["Items"])
    },
    test("two plugins adding one section to one tab of a kind conflict") {
        expectThrows(RegistryError.conflict(point: "ShapeDetails", key: "gadget Style/Color", plugins: ["gadgets", "more"])) {
            _ = try gadgetEditor([Contributor(id: "more") { r in
                r.details(Gadget.self) { DetailSection("Color", in: StyleTab.self) { _ in Text("Mine") } }
            }])
        }
    },
    test("one section id in two tabs, or for a kind and for every box, doesn't conflict") {
        let editor = try gadgetEditor([Contributor(id: "more") { r in
            r.details(Gadget.self) { DetailSection("Color", in: ArrangeTab.self) { _ in Text("Color") } }
            r.detailsForEveryBox { DetailSection("Color", in: StyleTab.self) { _ in Text("Color") } }
        }])
        expectEqual(try editor.layout(editor.add(Gadget(gadgetFrame))).outline,
                    ["Gadget: main, Count", "Remarks: main", "Style: Color, Color", "Arrange: Color, Size, Position"])
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).outline, ["Style: Color", "Arrange: Size, Position"])
    },
    test("two headers for one kind conflict") {
        expectThrows(RegistryError.conflict(point: "ShapeDetails", key: "header for gadget", plugins: ["gadgets", "more"])) {
            _ = try gadgetEditor([Contributor(id: "more") { r in r.details(Gadget.self, header: { _ in DetailHeader("Mine") }) {} }])
        }
    },
    test("details for a kind nobody registers are an unknown kind") {
        expectThrows(RegistryError.unknownKind(Gadget.kind, point: "ShapeDetails", contributor: "p")) {
            _ = try Registry(plugins: [DetailPanelPlugin(), Contributor(id: "p") { r in
                r.details(Gadget.self) { DetailSection(in: StyleTab.self) { _ in Text("Orphan") } }
            }])
        }
    },
    test("two tab types with one title are invalid, naming both and a plugin using each") {
        expectEqual(DetailTabID.of(StyleTab.self).name, "DetailPanel.StyleTab")
        expectThrows(RegistryError.invalid(point: "ShapeDetails", reason: "DetailPanel.StyleTab (from gadgets) and "
                                           + "DetailPanelTests.LookalikeStyleTab (from more) are both tabs titled \"Style\"; share one, or retitle one")) {
            _ = try gadgetEditor([Contributor(id: "more") { r in
                r.details(Gadget.self) { DetailSection("Tint", in: LookalikeStyleTab.self) { _ in Text("Tint") } }
            }])
        }
    },
    test("the header: the kind's own, else the place tool's label and symbol, else the kind") {
        let editor = try gadgetEditor([CardsPlugin(), Contributor(id: "p") { r in
            r.details(Card.self, header: { DetailHeader($0.props.text, systemImage: "star") }) {}
        }])
        // The kind's own header, with the tool's symbol, since it names none.
        expectEqual(try editor.layout(editor.add(Gadget(gadgetFrame))).header, DetailHeader("Unnamed", subtitle: "plain", systemImage: "gearshape"))
        expectEqual(try editor.layout(editor.add(Card(gadgetFrame, text: "Hi"))).header, DetailHeader("Hi", systemImage: "star"))
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).header, DetailHeader("box"))

        let plain = try gadgetEditor([CardsPlugin()])
        expectEqual(try plain.layout(plain.add(Card(gadgetFrame))).header, DetailHeader("Card", systemImage: "rectangle"))
    },
    test("statuses: the kind's, then every kind's, each in plugin order; they may read services") {
        let editor = try gadgetEditor([
            Contributor(id: "a") { r in
                r.detailStatusForEveryShape { _, context in [DetailStatus(context.service(DetailPanelState.self) == nil ? "a" : "a, with state")] }
            },
            Contributor(id: "b") { r in
                r.contribute({ _, _ in [DetailStatus("gadget b", tone: .warning)] }, to: DetailStatuses.self, for: .kind(Gadget.kind))
                r.detailStatusForEveryShape { _, _ in [DetailStatus("b", tone: .error)] }
            },
        ])
        let state = try require(editor.detailPanel)
        let gadgetID = editor.add(Gadget(gadgetFrame)), boxID = editor.add(Box(gadgetFrame))
        let gadget = try require(editor.document[gadgetID]), box = try require(editor.document[boxID])
        expectEqual(state.statuses(for: gadget).map(\.text), ["gadget b", "a, with state", "b"])
        expectEqual(state.statuses(for: box), [DetailStatus("a, with state"), DetailStatus("b", tone: .error)])
    },
    test("one details call is one line in the report") {
        let registry = try Registry(plugins: [FixturesPlugin(), DetailPanelPlugin(), Contributor(id: "p") { r in
            r.details(Box.self, header: { _ in DetailHeader("Box") }) {
                DetailSection(in: StyleTab.self) { _ in Text("One") }
                DetailSection("Two", in: StyleTab.self) { _ in Text("Two") }
                DetailSection("Three", in: ArrangeTab.self) { _ in Text("Three") }
            }
        }])
        expectEqual(registry.report, """
        core          tool select [v] · tool hand [h]
        fixtures      shape box · shape disc · shape tag
        detail-panel  service DetailPanelState · ShapeDetails
        p             ShapeDetails → box
        """)
    },
])
