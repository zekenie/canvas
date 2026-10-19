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

    /// `withTips`: a plugin says each tool's tip, its label and " tool" (the host's slot for tool
    /// tips); without it a tip is the tool's label.
    init(withTips: Bool = true) throws {
        var locked = AnyShapeRecord(ShapeRecord(id: frozen, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        locked[Frozen.self] = true
        let free = AnyShapeRecord(ShapeRecord(id: plain, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100))))
        let file = CanvasFile(root: CanvasDocument(shapes: [locked, free]),
                              children: [frozen: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 30))))])])
        let tips = Contributor(id: "tips") { $0.toolTips { tool, _ in "\(tool.label) tool" } }
        h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), TilesPlugin(), FreezingPlugin()] + (withTips ? [tips] : []), file: file)
        window.contentView = NSHostingView(rootView: ToolPicker(editor: h.editor))
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
        expectEqual((0..<tools.count).map { control.toolTip(forSegment: $0) }, tools.map { "\($0.label) tool" }, "what a plugin says of each")
        let plain = try ToolBar(withTips: false)
        expectEqual((0..<tools.count).map { plain.control.toolTip(forSegment: $0) }, tools.map(\.label), "its label, where no plugin says more")
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
    test("while the tool is locked the selected segment's symbol carries a lock and its tooltip says so, on whichever tool is selected; the others stay as they were, and it all follows the lock off") {
        let bar = try ToolBar()
        let control = bar.control, tools = bar.tools
        let plain = (0..<tools.count).map { control.image(forSegment: $0) }
        let tips = (0..<tools.count).map { control.toolTip(forSegment: $0) }
        expect(plain.allSatisfy { $0 != nil })
        let room = control.intrinsicContentSize
        bar.h.editor.isToolLocked = true
        bar.window.spin { control.toolTip(forSegment: 0) == "\(tools[0].label) tool, locked" }
        let locked = control.image(forSegment: 0)
        expect(locked !== plain[0] && locked?.tiffRepresentation != plain[0]?.tiffRepresentation, "the Hand's symbol has a lock on it")
        let widest = plain.compactMap { $0?.size.width }.max() ?? 0
        expectEqual(locked?.size.height, plain[0]?.size.height, "as tall as the symbol")
        expect((locked?.size.width ?? 0) >= (plain[0]?.size.width ?? 0) && (locked?.size.width ?? .infinity) <= widest,
               "as wide as the widest symbol at most, the room every segment has: \(String(describing: locked?.size))")
        expectEqual(control.intrinsicContentSize, room, "so the control is no wider")
        expectEqual(locked?.isTemplate, true, "tinted as the control tints any segment's")
        expectEqual(locked?.accessibilityDescription, "\(tools[0].label), locked")
        for index in 1..<tools.count {
            expect(control.image(forSegment: index) === plain[index], "segment \(index) is as it was")
            expectEqual(control.toolTip(forSegment: index), tips[index])
        }
        bar.h.editor.setTool(bar.tile)
        bar.window.spin { control.toolTip(forSegment: bar.tileSegment) == "\(bar.tools[bar.tileSegment].label) tool, locked" }
        expectEqual(control.toolTip(forSegment: 0), tips[0], "the lock moves with the selection")
        expect(control.image(forSegment: 0)?.tiffRepresentation == plain[0]?.tiffRepresentation)
        expect(control.image(forSegment: bar.tileSegment)?.tiffRepresentation != plain[bar.tileSegment]?.tiffRepresentation)
        expectEqual(control.selectedSegment, bar.tileSegment)
        bar.h.editor.isToolLocked = false
        bar.window.spin { control.toolTip(forSegment: bar.tileSegment) == tips[bar.tileSegment] }
        expectEqual((0..<tools.count).map { control.image(forSegment: $0)?.tiffRepresentation }, plain.map { $0?.tiffRepresentation })
        expectEqual((0..<tools.count).map { control.image(forSegment: $0)?.accessibilityDescription }, tools.map(\.label))
    },
])
