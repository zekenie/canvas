import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import SwiftUI
import TestKit

// What the panel remembers: per editor, in memory.
@MainActor let stateTests = Suite("Panel state", [
    test("the chosen tab is remembered per kind, and a shape without it shows the first") {
        let editor = try gadgetEditor()
        let state = try require(editor.detailPanel)
        let withParts = editor.add(Gadget(gadgetFrame, parts: [Gadget.Part()]))
        let without = editor.add(Gadget(gadgetFrame))
        let box = editor.add(Box(gadgetFrame))
        expectEqual(state.currentTab(in: try editor.layout(withParts), for: Gadget.kind), .of(GadgetTab.self))
        state.choose(.of(PartsTab.self), for: Gadget.kind)
        expectEqual(state.currentTab(in: try editor.layout(withParts), for: Gadget.kind), .of(PartsTab.self))
        expectEqual(state.currentTab(in: try editor.layout(without), for: Gadget.kind), .of(GadgetTab.self))
        expectEqual(state.currentTab(in: try editor.layout(withParts), for: Gadget.kind), .of(PartsTab.self), "still remembered")
        expectEqual(state.currentTab(in: try editor.layout(box), for: Box.kind), .of(ArrangeTab.self))
        expectEqual(state.currentTab(in: try editor.layout(editor.add(Tag(target: nil))), for: Tag.kind), nil)
    },
    test("collapsing an every-box section collapses it for every kind; a kind's own, for that kind only") {
        let editor = try gadgetEditor([Contributor(id: "more") { r in
            r.detailsForEveryBox { DetailSection("Count", in: GadgetTab.self) { _ in Text("Count") } }
        }])
        let state = try require(editor.detailPanel)
        let gadget = try editor.layout(editor.add(Gadget(gadgetFrame)))
        let box = try editor.layout(editor.add(Box(gadgetFrame)))
        let gadgetSize = try require(gadget.sections(in: .of(ArrangeTab.self)).first)
        let boxSize = try require(box.sections(in: .of(ArrangeTab.self)).first)
        state.setCollapsed(gadgetSize, true)
        expect(state.isCollapsed(boxSize))
        let counts = gadget.sections(in: .of(GadgetTab.self)).filter { $0.section == "Count" }
        expectEqual(counts.map(\.description), ["gadget Gadget/Count", "* Gadget/Count"])
        state.setCollapsed(counts[0], true)
        expect(!state.isCollapsed(counts[1]))
        expect(!state.isCollapsed(try require(box.sections(in: .of(GadgetTab.self)).first)))
        state.setCollapsed(gadgetSize, false)
        expect(!state.isCollapsed(boxSize))
    },
    test("selectionSummary is 'N Shapes', with each kind's name once in selection order, and stacked squares") {
        let editor = try gadgetEditor()
        let state = try require(editor.detailPanel)
        let ids = [editor.add(Gadget(gadgetFrame)), editor.add(Box(gadgetFrame)), editor.add(Gadget(gadgetFrame)), editor.add(Tag(target: nil))]
        // Named by the tool that places the kind (Gadget), else by the kind.
        expectEqual(state.selectionSummary(of: ids.compactMap { editor.document[$0] }),
                    DetailHeader("4 Shapes", subtitle: "Gadget, box, tag", systemImage: "square.on.square"))
        expectEqual(state.selectionSummary(of: ids.reversed().prefix(2).compactMap { editor.document[$0] }).subtitle, "tag, Gadget")
    },
    test("each editor has its own state, and none without the panel's plugin") {
        let registry = try Registry(plugins: [KeyboardPlugin(), FixturesPlugin(), GadgetsPlugin(), RemarksPlugin(), DetailPanelPlugin()])
        let one = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        let two = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        let id = ShapeID()
        for editor in [one, two] { editor.transact { $0.insert(ShapeRecord(id: id, Gadget(gadgetFrame))) } }
        try require(one.detailPanel).choose(.of(StyleTab.self), for: Gadget.kind)
        expectEqual(try require(one.detailPanel).currentTab(in: try one.layout(id), for: Gadget.kind), .of(StyleTab.self))
        expectEqual(try require(two.detailPanel).currentTab(in: try two.layout(id), for: Gadget.kind), .of(GadgetTab.self))
        expect(one.detailPanel !== two.detailPanel)
        expect(CanvasEditor(registry: try Registry(plugins: [FixturesPlugin()]), scheduler: ManualScheduler()).detailPanel == nil)
    },
])
