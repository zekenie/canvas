import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import SwiftUI
import TestKit

// A kit in the window (Kits.swift): File ▸ Kits, an item for each kit, the core's; the menu bar showing the items
// of the key window's file's commands, an off kit's hidden with the lines and submenus left with nothing; and the
// toolbar's one segment for a kit that's on. Fixtures only: CanvasTesting's workshop, and pegs of the test's own.

/// A peg: a kind with two tools, so a kit's segment has more than one to show.
private struct Peg: BoxShapeProps {
    static let kind: ShapeKind = "peg"
    static let properties = Properties<Peg> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

private struct PegDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Peg>, in context: RenderContext) {}
}

/// Pegs, in the workshop: Peg and Big Peg, two tools.
@MainActor private let pegs = Contributor(id: "pegs") { r in
    r.join(Workshop.self)
    r.shape(PegDefinition()) { peg in
        peg.tool(label: "Peg", systemImage: "circle", placing: peg.placement(size: CGSize(width: 20, height: 20)) { Peg() })
        peg.tool(ToolID("big-peg"), label: "Big Peg", systemImage: "circle.fill", placing: peg.placement(size: CGSize(width: 60, height: 60)) { Peg() })
    }
}

/// The titles of a menu's items that show.
private func shown(_ menu: NSMenu) -> [String] {
    menu.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
}

/// The toolbar hosted as the app hosts it, over the workshop and its pegs.
@MainActor private final class KitBar {
    let h: EditorHarness
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 40), styleMask: [.titled], backing: .buffered, defer: false)

    init() throws {
        h = try EditorHarness(plugins: [FixturesPlugin(), TilesPlugin(), WorkshopPlugin(), pegs])
        window.contentView = NSHostingView(rootView: ToolPicker(editor: h.editor))
        window.settle()
    }

    var control: NSSegmentedControl { window.contentView!.descendants(NSSegmentedControl.self)[0] }
    var last: Int { control.segmentCount - 1 }

    /// A click on a segment: its action sent, as AppKit sends it once the segment is selected.
    func click(_ segment: Int) {
        control.selectedSegment = segment
        _ = (control.target as? NSObject)?.perform(control.action, with: control)
        window.settle()
    }

    /// A pick from a segment's menu, as AppKit sends it.
    func pick(_ title: String, from segment: Int) throws {
        let menu = try require(control.menu(forSegment: segment))
        let item = try require(menu.item(withTitle: title))
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        window.settle()
    }
}

@MainActor let kitWindowTests = Suite("A kit in the window", [
    test("File ▸ Kits has an item for each kit, the core's command; the menu bar shows an off kit's items hidden, lines and submenus with them, and an on kit's back") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), WorkshopPlugin(), pegs])
        let menus = BoardMenus.make(appName: "Canvas", registry: h.editor.registry, editor: { h.editor })
        let file = try require(menus.main.item(withTitle: "File")?.submenu)
        let kits = try require(file.item(withTitle: "Kits")?.submenu)
        expectEqual(kits.items.map(\.title), ["Workshop"])
        expectEqual(kits.items.compactMap(BoardMenus.command(of:)), [.kit(Workshop.id)])
        let insert = try require(menus.main.item(withTitle: "Insert")?.submenu)
        let edit = try require(menus.main.item(withTitle: "Edit")?.submenu)
        expectEqual(try require(insert.item(withTitle: "Workshop")?.submenu).items.map(\.title), ["Plank", "Peg", "Big Peg"], "the kit's tools in its submenu")
        expect(shown(edit).contains("Carve"), "as made, everything shows")
        BoardMenus.showCommands(of: h.editor, in: menus.main, registry: h.editor.registry)
        expect(menus.main.item(withTitle: "Insert")?.isHidden == true, "Insert held only the kit's submenu, so it goes")
        expect(!shown(edit).contains("Carve"), "\(shown(edit))")
        expect(shown(edit).first != "—" && shown(edit).last != "—" && !zip(shown(edit), shown(edit).dropFirst()).contains { $0 == "—" && $1 == "—" },
               "no line left at an end or beside another: \(shown(edit))")
        expectEqual(shown(kits), ["Workshop"], "File ▸ Kits stays")
        h.editor.turn(Workshop.self, on: true)
        BoardMenus.showCommands(of: h.editor, in: menus.main, registry: h.editor.registry)
        expect(menus.main.item(withTitle: "Insert")?.isHidden == false)
        expect(shown(edit).contains("Carve"))
        BoardMenus.showCommands(of: nil, in: menus.main, registry: h.editor.registry)
        expect(!shown(edit).contains("Carve"), "with no board's window every kit is off")
    },
    test("the toolbar has no segment for a kit that's off; on, one, showing the last of its tools used, its menu every tool of it") {
        let bar = try KitBar()
        let loose = bar.h.editor.registry.tools.filter { bar.h.editor.registry.kit(ofTool: $0.id) == nil }
        expectEqual(bar.control.segmentCount, loose.count, "a segment a tool in no kit")
        bar.h.editor.turn(Workshop.self, on: true)
        bar.window.settle()
        expectEqual(bar.control.segmentCount, loose.count + 1, "and one for the kit")
        expectEqual(bar.control.menu(forSegment: bar.last)?.items.map(\.title), ["Plank", "Peg", "Big Peg"])
        expect(bar.control.showsMenuIndicator(forSegment: bar.last))
        expectEqual(bar.control.image(forSegment: bar.last)?.accessibilityDescription, "Workshop, Plank", "its first tool, until one is used")
        bar.click(bar.last)
        expectEqual(bar.h.editor.currentToolID, ToolID(placing: Plank.kind), "a click takes the tool it shows")
        try bar.pick("Big Peg", from: bar.last)
        expectEqual(bar.h.editor.currentToolID, "big-peg")
        expectEqual(bar.control.selectedSegment, bar.last)
        expectEqual(bar.control.image(forSegment: bar.last)?.accessibilityDescription, "Workshop, Big Peg")
        bar.h.editor.setTool(.hand)
        bar.window.settle()
        expectEqual(bar.control.image(forSegment: bar.last)?.accessibilityDescription, "Workshop, Big Peg", "the last used, with another tool current")
        bar.click(bar.last)
        expectEqual(bar.h.editor.currentToolID, "big-peg")
        bar.h.editor.turn(Workshop.self, on: false)
        bar.window.settle()
        expectEqual(bar.control.segmentCount, loose.count, "off, its segment goes")
        expectEqual(bar.h.editor.currentToolID, .hand, "and its tool")
    },
])
