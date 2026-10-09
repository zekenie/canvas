import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import SwiftUI
import TestKit

// The toolbar's tools, hosted as the app hosts them (a segmented control in an NSHostingView, in an
// unshown window): each follows the tool that's current, and the tools that place shapes dim on a
// board that takes none, and light again on one that does.

/// A root holding a frozen pocket, whose board holds a box, and a pocket that isn't, over Pockets,
/// Tiles (a tool that places) and Frozen: the picker hosted, with each tool's tooltip made from its
/// label.
@MainActor private final class ToolBar {
    let h: EditorHarness
    let frozen = ShapeID(), plain = ShapeID()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.titled], backing: .buffered, defer: false)

    init() throws {
        var locked = AnyShapeRecord(ShapeRecord(id: frozen, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        locked[Frozen.self] = true
        let free = AnyShapeRecord(ShapeRecord(id: plain, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100))))
        let file = CanvasFile(root: CanvasDocument(shapes: [locked, free]),
                              children: [frozen: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 30))))])])
        h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), TilesPlugin(), FreezingPlugin()], file: file)
        window.contentView = NSHostingView(rootView: ToolPicker(editor: h.editor, help: { "\($0.label) tool" }))
        window.settle()
    }

    var control: NSSegmentedControl { window.contentView!.descendants(NSSegmentedControl.self)[0] }
    var tools: [ToolDescriptor] { h.editor.registry.tools }
    let tile = ToolID(placing: Tile.kind)
    var tileSegment: Int { tools.firstIndex { $0.id == tile }! }

    /// Whether each segment, in the registry's order, takes a click.
    var enabled: [Bool] { (0..<control.segmentCount).map { control.isEnabled(forSegment: $0) } }

    /// A click on a segment: its action sent, as AppKit sends it once the segment is selected.
    func click(_ segment: Int) {
        control.selectedSegment = segment
        _ = (control.target as? NSObject)?.perform(control.action, with: control)
        window.settle()
    }
}

@MainActor let toolPickerTests = Suite("The toolbar's tools", [
    test("a segment a tool, with its symbol and tooltip; the current tool's is selected, and follows a switch made on the canvas") {
        let bar = try ToolBar()
        let control = bar.control, tools = bar.tools
        expect(tools.count > 1)
        expectEqual(control.segmentCount, tools.count)
        expectEqual((0..<tools.count).map { control.toolTip(forSegment: $0) }, tools.map { "\($0.label) tool" })
        expectEqual((0..<tools.count).map { control.image(forSegment: $0)?.accessibilityDescription }, tools.map(\.label), "VoiceOver reads each by its label")
        expectEqual(control.accessibilityLabel(), "Tool")
        expectEqual(control.selectedSegment, 0, "the Hand")
        bar.h.editor.setTool(bar.tile)
        bar.window.spin { control.selectedSegment == bar.tileSegment }
        bar.h.editor.setTool(.hand)
        bar.window.spin { control.selectedSegment == 0 }
    },
    test("a click on a segment picks its tool") {
        let bar = try ToolBar()
        bar.click(bar.tileSegment)
        expectEqual(bar.h.editor.currentToolID, bar.tile)
        expectEqual(bar.control.selectedSegment, bar.tileSegment)
        bar.click(0)
        expectEqual(bar.h.editor.currentToolID, .hand)
        expectEqual(bar.control.selectedSegment, 0)
    },
    test("a tool that places shapes is dimmed on a board that's read-only, and the Hand isn't; both light again on a board that isn't") {
        let bar = try ToolBar()
        expectEqual(bar.enabled, bar.tools.map { _ in true })
        expect(bar.h.enter(bar.frozen))
        bar.window.spin { bar.enabled[bar.tileSegment] == false }
        expectEqual(bar.enabled, bar.tools.map { $0.id != bar.tile }, "only the tools that place")
        bar.click(bar.tileSegment)
        expectEqual(bar.h.editor.currentToolID, .hand, "a click that gets through isn't taken")
        expectEqual(bar.control.selectedSegment, 0, "and the control shows the tool that's current")
        expect(bar.h.editor.showBoard(.root))
        bar.window.spin { bar.enabled[bar.tileSegment] }
        expectEqual(bar.enabled, bar.tools.map { _ in true })
        bar.click(bar.tileSegment)
        expectEqual(bar.h.editor.currentToolID, bar.tile)
    },
    test("a lock above the board shown dims them as it lands, in a commit on another board, and leaves the tool in use for the Hand; thawed, they light again") {
        let bar = try ToolBar()
        expect(bar.h.enter(bar.plain))
        bar.click(bar.tileSegment)
        expectEqual(bar.enabled, bar.tools.map { _ in true })
        bar.h.editor.transact(on: .root, "Freeze") { $0.update(bar.plain) { $0[Frozen.self] = true } }
        bar.window.spin { bar.enabled[bar.tileSegment] == false }
        expectEqual(bar.control.selectedSegment, 0, "the tool in use went back to the default")
        bar.h.editor.transact(on: .root, "Thaw") { $0.update(bar.plain) { $0[Frozen.self] = nil } }
        bar.window.spin { bar.enabled[bar.tileSegment] }
    },
])

// A tool with a menu: the indicator on its segment, and the menu made as it opens.

/// The picker hosted over a palette tool (a menu on its segment) and a stamp (which places shapes).
@MainActor private final class PaletteBar {
    let h: EditorHarness
    let palette: Palette
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 40), styleMask: [.titled], backing: .buffered, defer: false)

    init(colors: [String] = ["Red", "Green"]) throws {
        palette = Palette(colors)
        h = try EditorHarness(plugins: [FixturesPlugin(), PalettePlugin(palette)])
        window.contentView = NSHostingView(rootView: ToolPicker(editor: h.editor, help: { "\($0.label) tool" }))
        window.settle()
    }

    var control: NSSegmentedControl { window.contentView!.descendants(NSSegmentedControl.self)[0] }
    var tools: [ToolDescriptor] { h.editor.registry.tools }
    var paletteSegment: Int { tools.firstIndex { $0.id == PalettePlugin.palette }! }
    var stampSegment: Int { tools.firstIndex { $0.id == PalettePlugin.stamp }! }

    /// The menu on the palette's segment, opened: AppKit asks its delegate to update it as it opens.
    func open() -> NSMenu {
        let menu = control.menu(forSegment: paletteSegment)!
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    func click(_ segment: Int) {
        control.selectedSegment = segment
        _ = (control.target as? NSObject)?.perform(control.action, with: control)
        window.settle()
    }
}

@MainActor let toolMenuPickerTests = Suite("The toolbar's tool menus", [
    test("a segment with a menu shows the indicator and has a menu; the others have neither") {
        let bar = try PaletteBar()
        let control = bar.control
        for segment in 0..<control.segmentCount {
            let hasMenu = segment == bar.paletteSegment
            expectEqual(control.showsMenuIndicator(forSegment: segment), hasMenu, "segment \(segment)")
            expectEqual(control.menu(forSegment: segment) != nil, hasMenu, "segment \(segment)")
        }
        expectEqual(bar.palette.asked, 0, "the menu is made as it opens, not as the toolbar is")
    },
    test("the menu is made as it opens, from the tool's list as it is then: items, a separator, checks and dimmed lines") {
        let bar = try PaletteBar()
        var menu = bar.open()
        expectEqual(menu.items.map(\.title), ["Red", "Green", "", "Unavailable"])
        expectEqual(menu.items.map(\.isSeparatorItem), [false, false, true, false])
        expectEqual(menu.items.map(\.isEnabled), [true, true, false, false], "a separator is never enabled")
        expectEqual(menu.items.map(\.state), [.off, .off, .off, .off])
        expect(menu.items[0].image != nil && menu.items[3].image == nil, "a symbol where the item has one")
        expectEqual(bar.palette.asked, 1)

        bar.palette.colors = ["Blue", "Red", "Green"]
        menu = bar.open()
        expectEqual(menu.items.map(\.title), ["Blue", "Red", "Green", "", "Unavailable"], "the list as it is now, the lines before gone")
        expectEqual(bar.palette.asked, 2)
    },
    test("choosing a line runs its item; the one chosen is checked the next time") {
        let bar = try PaletteBar()
        var menu = bar.open()
        menu.performActionForItem(at: 1)
        expectEqual(bar.palette.chosen, ["Green"])
        menu = bar.open()
        expectEqual(menu.items.map(\.state), [.off, .on, .off, .off])
        menu.performActionForItem(at: 0)
        expectEqual(bar.palette.chosen, ["Green", "Red"])
    },
    test("a plain click on the segment still picks the tool, and asks for no menu") {
        let bar = try PaletteBar()
        bar.click(bar.paletteSegment)
        expectEqual(bar.h.editor.currentToolID, PalettePlugin.palette)
        expectEqual(bar.control.selectedSegment, bar.paletteSegment)
        expectEqual(bar.palette.asked, 0)
        bar.click(0)
        expectEqual(bar.h.editor.currentToolID, .hand)
    },
])
