import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import SwiftUI
import TestKit

/// A tab type titled like DetailPanel's Style.
enum LookalikeStyleTab {}
extension LookalikeStyleTab: DetailTab { static var title: String { "Style" } }

/// A tab of a shape's state, as validation's Issues is: status lines only, last.
enum AlertsTab {}
extension AlertsTab: DetailTab {
    static var title: String { "Alerts" }
    static var order: Order<Self> { .after(StyleTab.self) }
}

// What the panel shows for a shape, resolved headlessly from the registry.
@MainActor let layoutTests = Suite("Detail layout", [
    test("the panel has no sections of its own: a box nobody contributes to shows only its header") {
        let editor = CanvasEditor(registry: try Registry(plugins: [KeyboardPlugin(), FixturesPlugin(), DetailPanelPlugin()]), scheduler: ManualScheduler())
        let layout = try editor.layout(editor.add(Box(gadgetFrame)))
        expectEqual(layout.tabs, [])
        expectEqual(layout.header, DetailHeader("box"))
    },
    test("every-box sections alone: a box with nothing else shows their tab") {
        let editor = try gadgetEditor()
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).outline, ["Frame: Size, Position"])
    },
    test("a kind without a frame has no tabs, and its header is its kind") {
        let editor = try gadgetEditor()
        let layout = try editor.layout(editor.add(Tag(target: nil)))
        expectEqual(layout.tabs, [])
        expectEqual(layout.header, DetailHeader("tag"))
    },
    test("a kind's own tabs lead, first, in first appearance; a feature tab, Style and Frame trail by order") {
        let editor = try gadgetEditor()
        // Remarks' tab is contributed first, but says nothing, so it goes after the kind's own, which are first.
        expectEqual(try editor.layout(editor.add(Gadget(gadgetFrame, parts: [Gadget.Part()]))).outline, [
            "Gadget: main, Count", "Parts: Items", "Remarks: main", "Style: Color", "Frame: Size, Position",
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
            _ = try Registry(plugins: [KeyboardPlugin(), GadgetsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: "gadgets")) {
            _ = try Registry(plugins: [KeyboardPlugin(), GadgetsPlugin(), RemarksPlugin()])
        }
    },
    test("within a tab: the kind's sections, then another plugin's for the kind, then every-box ones, each in plugin order") {
        let editor = try gadgetEditor([
            Contributor(id: "bridge") { r in
                r.details(Gadget.self) {
                    DetailSection("Shade", in: StyleTab.self) { _ in Text("Shade") }
                    DetailSection("Fit", in: FrameTab.self) { _ in Text("Fit") }
                }
            },
            Contributor(id: "grid") { r in r.detailsForEveryBox { DetailSection("Grid", in: FrameTab.self) { _ in Text("Grid") } } },
        ])
        let layout = try editor.layout(editor.add(Gadget(gadgetFrame)))
        expectEqual(layout.outline, ["Gadget: main, Count", "Remarks: main", "Style: Color, Shade", "Frame: Fit, Size, Position, Grid"])
        expectEqual(layout.sections(in: .of(FrameTab.self)).map(\.description), ["gadget Frame/Fit", "every shape with a box Frame/Size", "every shape with a box Frame/Position", "every shape with a box Frame/Grid"])
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).outline, ["Frame: Size, Position, Grid"])
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
            r.details(Gadget.self) { DetailSection("Color", in: FrameTab.self) { _ in Text("Color") } }
            r.detailsForEveryBox { DetailSection("Color", in: StyleTab.self) { _ in Text("Color") } }
        }])
        expectEqual(try editor.layout(editor.add(Gadget(gadgetFrame))).outline,
                    ["Gadget: main, Count", "Remarks: main", "Style: Color, Color", "Frame: Color, Size, Position"])
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).outline, ["Style: Color", "Frame: Size, Position"])
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
            r.details(Card.self, header: { $card in DetailHeader(card.text, systemImage: "star") }) {}
        }])
        // The kind's own header, with the tool's symbol, since it names none.
        expectEqual(try editor.layout(editor.add(Gadget(gadgetFrame))).header, DetailHeader("Unnamed", subtitle: "plain", systemImage: "gearshape"))
        expectEqual(try editor.layout(editor.add(Card(gadgetFrame, text: "Hi"))).header, DetailHeader("Hi", systemImage: "star"))
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).header, DetailHeader("box"))

        let plain = try gadgetEditor([CardsPlugin()])
        expectEqual(try plain.layout(plain.add(Card(gadgetFrame))).header, DetailHeader("Card", systemImage: "rectangle"))
    },
    test("a header can be a view of the kind's own, made from the shape's binding and read back as its type") {
        let editor = try gadgetEditor([CardsPlugin(), RenamingCards()])
        let layout = try editor.layout(editor.add(Card(gadgetFrame, text: "Hi")))
        expectEqual(layout.header, nil, "it isn't a DetailHeader")
        expectEqual(layout.header(as: RenamingHeader.self)?.text, "Hi")
        expectEqual(layout.kindName, "Card", "for its placeholder")
    },
    test("statuses: the kind's, then every kind's, each in plugin order; they may read services") {
        let editor = try gadgetEditor([
            Contributor(id: "a") { r in
                r.forEveryShape { scope in
                    scope.detailStatus { _, context in [DetailStatus(context.service(DetailPanelState.self) == nil ? "a" : "a, with state")] }
                }
            },
            Contributor(id: "b") { r in
                r.contribute(DetailStatusContribution { _, _ in [DetailStatus("gadget b", tone: .warning)] }, to: DetailStatuses.self, for: .kind(Gadget.kind))
                r.forEveryShape { scope in
                    scope.detailStatus { _, _ in [DetailStatus("b", tone: .error)] }
                }
            },
        ])
        let state = try require(editor.detailPanel)
        let gadgetID = editor.add(Gadget(gadgetFrame)), boxID = editor.add(Box(gadgetFrame))
        let gadget = try require(editor.document[gadgetID]), box = try require(editor.document[boxID])
        expectEqual(state.statuses(for: gadget).map(\.text), ["gadget b", "a, with state", "b"])
        expectEqual(state.statuses(for: box), [DetailStatus("a, with state"), DetailStatus("b", tone: .error)])
    },
    test("status lines for a tab bring it while the shape has some, in its place by order, and stay out of the footer") {
        let editor = try gadgetEditor([Contributor(id: "alerts") { r in
            r.forEveryShape { scope in
                scope.detailStatus(in: AlertsTab.self) { shape, _ in shape.box?.width == 0 ? [DetailStatus("No width.", tone: .error)] : [] }
            }
            r.forEveryShape { scope in
                scope.detailStatus { _, _ in [DetailStatus("Footer.")] }
            }
        }])
        let state = try require(editor.detailPanel)
        let box = editor.add(Box(gadgetFrame))
        expectEqual(try editor.layout(box).tabs.map(\.title), ["Frame"])
        editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = 0 } }
        let layout = try editor.layout(box)
        expectEqual(layout.tabs.map(\.title), ["Frame", "Alerts"])
        expectEqual(layout.statuses(in: .of(AlertsTab.self)), [DetailStatus("No width.", tone: .error)])
        expectEqual(layout.statuses(in: .of(FrameTab.self)), [])
        expectEqual(state.statuses(for: try require(editor.document[box])), [DetailStatus("Footer.")])
        editor.transact { $0.update(box, as: Box.self) { $0.frame.size.width = 10 } }
        expectEqual(try editor.layout(box).tabs.map(\.title), ["Frame"])
    },
    test("a tab's alert is its lines' worst tone when that's a warning or an error, for the strip to show") {
        final class Lines { var tones: [DetailStatus.Tone] = [] }
        let lines = Lines()
        let editor = try gadgetEditor([Contributor(id: "alerts") { r in
            r.forEveryShape { scope in
                scope.detailStatus(in: AlertsTab.self) { _, _ in lines.tones.map { DetailStatus("A line.", tone: $0) } }
            }
        }])
        let box = editor.add(Box(gadgetFrame))
        for (tones, alert) in [([.neutral], nil), ([.info, .neutral], nil), ([.info, .warning], .warning),
                               ([.error, .warning, .info], .error), ([.warning, .error], DetailStatus.Tone.error)] as [([DetailStatus.Tone], DetailStatus.Tone?)] {
            lines.tones = tones
            expectEqual(try editor.layout(box).alert(in: .of(AlertsTab.self)), alert, "\(tones)")
        }
        expectEqual(try editor.layout(box).alert(in: .of(FrameTab.self)), nil, "a tab without lines")
    },
    test("a tab can hold status lines and sections: the kind's lines, then every kind's; its sections as they were") {
        let editor = try gadgetEditor([Contributor(id: "notes") { r in
            r.forEveryShape { scope in
                scope.detailStatus(in: RemarksTab.self) { _, _ in [DetailStatus("Every kind.")] }
            }
            r.contribute(DetailStatusContribution(in: RemarksTab.self) { _, _ in [DetailStatus("A gadget.", tone: .info)] },
                         to: DetailStatuses.self, for: .kind(Gadget.kind))
        }])
        let layout = try editor.layout(editor.add(Gadget(gadgetFrame)))
        expectEqual(layout.outline, ["Gadget: main, Count", "Remarks: main", "Style: Color", "Frame: Size, Position"])
        expectEqual(layout.statuses(in: .of(RemarksTab.self)).map(\.text), ["A gadget.", "Every kind."])
        expectEqual(try editor.layout(editor.add(Box(gadgetFrame))).tabs.map(\.title), ["Remarks", "Frame"], "lines alone bring the tab")
    },
    test("a status tab titled like another tab is refused, as a section's is") {
        expectThrows(RegistryError.invalid(point: "ShapeDetails", reason: "DetailPanel.StyleTab (from gadgets) and "
                                           + "DetailPanelTests.LookalikeStyleTab (from more) are both tabs titled \"Style\"; share one, or retitle one")) {
            _ = try gadgetEditor([Contributor(id: "more") { r in r.forEveryShape { scope in
                scope.detailStatus(in: LookalikeStyleTab.self) { _, _ in [] }
            } }])
        }
    },
    test("status lines for a tab name it in the report") {
        let registry = try Registry(plugins: [FixturesPlugin(), DetailPanelPlugin(), Contributor(id: "p") { r in
            r.forEveryShape { scope in
                scope.detailStatus { _, _ in [] }
            }
            r.forEveryShape { scope in
                scope.detailStatus(in: AlertsTab.self) { _, _ in [] }
            }
        }])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn in View · command zoomOut in View · command zoomToActualSize in View · command zoomToFit in View
        fixtures      shape box · shape disc · shape tag
        detail-panel  service DetailPanelState · host inspector
        p             DetailStatuses → every shape · DetailStatuses in Alerts after Style → every shape
        """)
    },
    test("one details call is one line in the report") {
        let registry = try Registry(plugins: [FixturesPlugin(), DetailPanelPlugin(), Contributor(id: "p") { r in
            r.details(Box.self, header: { _ in DetailHeader("Box") }) {
                DetailSection(in: StyleTab.self) { _ in Text("One") }
                DetailSection("Two", in: StyleTab.self) { _ in Text("Two") }
                DetailSection("Three", in: FrameTab.self) { _ in Text("Three") }
            }
        }])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn in View · command zoomOut in View · command zoomToActualSize in View · command zoomToFit in View
        fixtures      shape box · shape disc · shape tag
        detail-panel  service DetailPanelState · host inspector
        p             ShapeDetails in Style last, Frame after Style → box
        """)
    },
    test("tabs placed beside each other in a circle are refused, by the point that names them") {
        expectThrows(RegistryError.invalid(point: "ShapeDetails", reason: "tabs placed beside each other in a circle: Ping after Pong, Pong after Ping")) {
            _ = try Registry(plugins: [KeyboardPlugin(), FixturesPlugin(), DetailPanelPlugin(), Contributor(id: "loop") { r in
                r.detailsForEveryBox {
                    DetailSection("One", in: PingTab.self) { _ in Text("One") }
                    DetailSection("Two", in: PongTab.self) { _ in Text("Two") }
                }
            }])
        }
    },
])

/// Two tabs each placed right after the other: no order would do.
enum PingTab {}
extension PingTab: DetailTab {
    static var title: String { "Ping" }
    static var order: Order<Self> { .after(PongTab.self) }
}

enum PongTab {}
extension PongTab: DetailTab {
    static var title: String { "Pong" }
    static var order: Order<Self> { .after(PingTab.self) }
}
