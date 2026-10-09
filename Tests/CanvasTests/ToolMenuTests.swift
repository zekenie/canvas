@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// A tool's menu on the toolbar is a value made when it opens, and a tool registered with
// `placesShapes` is dimmed where the tools that place shapes are.

@MainActor private func titles(_ entries: [ToolMenuEntry]?) -> [String]? {
    entries?.map { entry in
        switch entry {
        case .item(let item): item.title
        case .separator: "-"
        }
    }
}

@MainActor private func items(_ entries: [ToolMenuEntry]?) -> [ToolMenuItem] {
    (entries ?? []).compactMap { if case .item(let item) = $0 { item } else { nil } }
}

@MainActor private struct Menus {
    let h: EditorHarness
    let palette: Palette
    init(_ colors: [String] = ["Red", "Green"]) throws {
        palette = Palette(colors)
        h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), PalettePlugin(palette)])
    }
}

@MainActor let toolMenuTests = Suite("Tool menus", [
    test("a tool with a menu has it; one without has none") {
        let menus = try Menus()
        let registry = menus.h.editor.registry
        expect(registry.hasToolMenu(for: PalettePlugin.palette))
        expect(!registry.hasToolMenu(for: PalettePlugin.stamp))
        expect(!registry.hasToolMenu(for: .hand))
        expect(menus.h.editor.toolMenu(for: PalettePlugin.stamp) == nil)
        expect(menus.h.editor.toolMenu(for: .hand) == nil)
        expect(registry.report.contains("tool menu palette"), registry.report)
    },
    test("the menu is asked each time it opens, so it lists the list as it is then") {
        let menus = try Menus()
        let editor = menus.h.editor
        expectEqual(menus.palette.asked, 0, "not when the editor is made")
        expectEqual(titles(editor.toolMenu(for: PalettePlugin.palette)), ["Red", "Green", "-", "Unavailable"])
        menus.palette.colors.append("Blue")
        expectEqual(titles(editor.toolMenu(for: PalettePlugin.palette)), ["Red", "Green", "Blue", "-", "Unavailable"])
        menus.palette.colors = []
        expectEqual(titles(editor.toolMenu(for: PalettePlugin.palette)), ["-", "Unavailable"])
        expectEqual(menus.palette.asked, 3)
    },
    test("an item carries its symbol, its check and whether it can be chosen") {
        let menus = try Menus()
        let editor = menus.h.editor
        var lines = items(editor.toolMenu(for: PalettePlugin.palette))
        expectEqual(lines.map(\.systemImage), ["circle", "circle", nil])
        expectEqual(lines.map(\.isChecked), [false, false, false])
        expectEqual(lines.map(\.isEnabled), [true, true, false])
        editor.choose(lines[1])
        lines = items(editor.toolMenu(for: PalettePlugin.palette))
        expectEqual(lines.map(\.isChecked), [false, true, false], "what was chosen is checked")
    },
    test("choosing an item runs what it does, with the editor; a dimmed item does nothing") {
        let menus = try Menus()
        let editor = menus.h.editor
        let lines = items(editor.toolMenu(for: PalettePlugin.palette))
        editor.choose(lines[0])
        editor.choose(lines[1])
        editor.choose(lines[2])
        expectEqual(menus.palette.chosen, ["Red", "Green"])
        var got: CanvasEditor?
        editor.choose(ToolMenuItem("Who") { got = $0 })
        expect(got === editor)
    },
    test("a second menu for one tool conflicts, and a menu for a tool nobody registers is invalid") {
        expectThrows(RegistryError.conflict(point: "ToolMenus", key: "the menu of tool palette", plugins: ["palettes", "again"])) {
            _ = try Registry(plugins: [PalettePlugin(), Contributor(id: "again") { $0.toolMenu(for: PalettePlugin.palette) { _ in [] } }])
        }
        expectThrows(RegistryError.invalid(point: "ToolMenus", reason: "no plugin registers tool zap, which has a menu")) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.toolMenu(for: "zap") { _ in [] } }])
        }
    },
    test("the Hand can have a menu: any registered tool may") {
        let registry = try Registry(plugins: [Contributor(id: "x") { $0.toolMenu(for: .hand) { _ in [.separator] } }])
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        expectEqual(titles(editor.toolMenu(for: .hand)), ["-"])
    },
    test("a tool registered with placesShapes is dimmed on a board that takes no shapes, and one that doesn't isn't") {
        let owner = ShapeID(), inner = ShapeID()
        var frozen = AnyShapeRecord(ShapeRecord(id: owner, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        frozen[Frozen.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [frozen]),
                              children: [owner: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: inner, Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), FreezingPlugin(), PalettePlugin(), TilesPlugin()], file: file)
        let editor = h.editor
        expect(editor.isToolEnabled(PalettePlugin.stamp))
        expect(h.enter(owner))
        expect(editor.isBoardReadOnly)
        expect(!editor.isToolEnabled(PalettePlugin.stamp), "it places shapes")
        expect(!editor.isToolEnabled(ToolID(placing: Tile.kind)), "as the tool a kind registers does")
        expect(editor.isToolEnabled(PalettePlugin.palette), "one that doesn't, doesn't")
        expect(editor.isToolEnabled(.hand))
        editor.setTool(PalettePlugin.stamp)
        expectEqual(editor.currentToolID, .hand, "and it isn't taken")
        editor.setTool(PalettePlugin.palette)
        expectEqual(editor.currentToolID, PalettePlugin.palette)
        expect(editor.showBoard(.root))
        expect(editor.isToolEnabled(PalettePlugin.stamp))
        editor.setTool(PalettePlugin.stamp)
        expectEqual(editor.currentToolID, PalettePlugin.stamp)
    },
    test("a tool in use that places shapes is left for the default tool as its board becomes read-only") {
        let owner = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: owner, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                              children: [owner: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), FreezingPlugin(), PalettePlugin()], file: file)
        expect(h.enter(owner))
        h.editor.setTool(PalettePlugin.stamp)
        expectEqual(h.editor.currentToolID, PalettePlugin.stamp)
        h.editor.transact(on: .root, "Freeze") { $0.update(owner) { $0[Frozen.self] = true } }
        expectEqual(h.editor.currentToolID, .hand)
    },
])
