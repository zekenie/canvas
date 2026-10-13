import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Colors
import ContextMenus
import Selection
import TestKit

// Color ▸ in a selection's menu, read with a secondary click and chosen as a click would: nothing
// goes on screen.

@MainActor private struct Bench {
    let h: EditorHarness
    let log: RefusalLog
    var editor: CanvasEditor { h.editor }

    init() throws {
        let log = RefusalLog()
        self.log = log
        h = try EditorHarness(plugins: colorPlugins([FreezingPlugin(log: log)]))
    }

    func middle(_ id: ShapeID) -> CGPoint {
        let frame = editor.document[id]?.box ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func menu(on id: ShapeID, selecting ids: [ShapeID]? = nil) throws -> NSMenu {
        editor.selectedShapeIDs = ids ?? [id]
        return try require(h.secondaryClick(at: middle(id)))
    }

    /// Three sheets in a row.
    func sheets(_ count: Int = 3) -> [ShapeID] {
        (0..<count).map { h.add(Sheet(CGRect(x: 40 + Double($0) * 200, y: 100, width: 100, height: 100))) }
    }

    /// The lines of the Color submenu, indented once.
    func colorItems(_ menu: NSMenu) throws -> [String] {
        let outline = menu.outline
        let at = try require(outline.firstIndex { $0.hasSuffix("Color ▸") }, "\(outline)")
        return Array(outline[(at + 1)...].prefix { $0.hasPrefix("  ") }).map { String($0.dropFirst(2)) }
    }
}

private let names = ["Gray", "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Indigo", "Purple", "Pink"]

@MainActor let colorMenuTests = Suite("Color ▸", [
    test("the submenu holds the built-in colors capitalized, a line, and None, in the menu of a shape with colors; nothing is checked") {
        let b = try Bench()
        let sheet = b.sheets(1)[0]
        let items = try b.colorItems(try b.menu(on: sheet))
        expectEqual(items, names + ["—", "None"].map { $0 == "None" ? "✓ None" : $0 }, "no shape has a color: None is checked")
        expect(!items.contains { $0.hasPrefix("(") }, "never dimmed")
    },
    test("checks: a color every selected shape has is checked; none when they differ; None when no shape has one") {
        let b = try Bench()
        let ids = b.sheets()
        b.editor.setColor(.blue, of: ids)
        var items = try b.colorItems(try b.menu(on: ids[0], selecting: ids))
        expect(items.contains("✓ Blue") && !items.contains("✓ None"), "\(items)")
        b.editor.setColor(.red, of: [ids[2]])
        items = try b.colorItems(try b.menu(on: ids[0], selecting: ids))
        expect(!items.contains { $0.hasPrefix("✓") }, "they differ: \(items)")
        expect(try b.colorItems(try b.menu(on: ids[0])).contains("✓ Blue"), "one shape alone")
        b.editor.setColor(nil, of: [ids[0]])
        items = try b.colorItems(try b.menu(on: ids[0], selecting: ids))
        expect(!items.contains { $0.hasPrefix("✓") }, "one has none: \(items)")
        b.editor.setColor(nil, of: ids)
        items = try b.colorItems(try b.menu(on: ids[0], selecting: ids))
        expectEqual(items.filter { $0.hasPrefix("✓") }, ["✓ None"])
    },
    test("choosing a color for three selected shapes is one step, Change Color; undo puts all three back") {
        let b = try Bench()
        let ids = b.sheets()
        b.editor.setColor(.red, of: [ids[1]])
        let before = b.editor.revision
        try b.menu(on: ids[0], selecting: ids).choose("Color", "Green")
        for id in ids { expectEqual(b.editor.document[id]?.ownColor, .named("green")) }
        expectEqual(b.editor.undoHistory.undoName, "Change Color")
        expect(b.editor.revision > before)
        b.editor.undo()
        expectEqual(b.editor.document[ids[0]]?.ownColor, nil)
        expectEqual(b.editor.document[ids[1]]?.ownColor, .named("red"), "the one that had a color has it back")
        expectEqual(b.editor.document[ids[2]]?.ownColor, nil)
    },
    test("None takes the color away from all of them, in one step") {
        let b = try Bench()
        let ids = b.sheets()
        b.editor.setColor(.blue, of: ids)
        try b.menu(on: ids[0], selecting: ids).choose("Color", "None")
        for id in ids { expectEqual(b.editor.document[id]?.ownColor, nil) }
        expectEqual(b.editor.undoHistory.undoName, "Change Color")
        b.editor.undo()
        for id in ids { expectEqual(b.editor.document[id]?.ownColor, .named("blue")) }
    },
    test("no Color ▸ for a selection with a shape that has no colors, nor for an empty selection") {
        let b = try Bench()
        let sheet = b.sheets(1)[0]
        let box = b.h.add(Box(CGRect(x: 500, y: 100, width: 100, height: 100)))
        expect(!(try b.menu(on: box).outline).contains { $0.hasSuffix("Color ▸") })
        expect(!(try b.menu(on: sheet, selecting: [sheet, box]).outline).contains { $0.hasSuffix("Color ▸") })
        b.editor.selectedShapeIDs = []
        let canvas = try require(b.h.secondaryClick(at: CGPoint(x: 900, y: 700)))
        expect(!canvas.outline.contains { $0.hasSuffix("Color ▸") }, "\(canvas.outline)")
    },
    test("a pane's menu has it too") {
        let b = try Bench()
        let pane = b.h.add(Pane(CGRect(x: 40, y: 100, width: 100, height: 100)))
        try b.menu(on: pane).choose("Color", "Teal")
        expectEqual(b.editor.document[pane]?.ownColor, .named("teal"))
    },
    test("read-only: the items show, a pick changes nothing and the shape shakes; with others selected they change in one step") {
        let b = try Bench()
        let ids = b.sheets()
        b.editor.freeze([ids[2]])
        let items = try b.colorItems(try b.menu(on: ids[2]))
        expect(!items.contains { $0.hasPrefix("(") }, "not dimmed: \(items)")
        try b.menu(on: ids[2]).choose("Color", "Blue")
        expectEqual(b.editor.document[ids[2]]?.ownColor, nil)
        expect(b.log.refusals.contains { $0.contains(ids[2]) }, "it shakes")
        b.log.refusals = []
        try b.menu(on: ids[0], selecting: ids).choose("Color", "Blue")
        expectEqual(b.editor.document[ids[0]]?.ownColor, .named("blue"))
        expectEqual(b.editor.document[ids[1]]?.ownColor, .named("blue"))
        expectEqual(b.editor.document[ids[2]]?.ownColor, nil, "the read-only one is refused")
        expect(b.log.refusals.contains { $0.contains(ids[2]) }, "and shakes")
        expectEqual(b.editor.undoHistory.undoName, "Change Color")
        b.editor.undo()
        expectEqual(b.editor.document[ids[0]]?.ownColor, nil, "the two changed in one step")
        expectEqual(b.editor.document[ids[1]]?.ownColor, nil)
    },
])
