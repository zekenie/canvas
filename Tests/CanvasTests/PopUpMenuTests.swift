@_spi(Host) import Canvas
import CanvasTesting
import AppKit
import CoreGraphics
import TestKit

// A menu a canvas button asks for waits for the host to pop it up.

/// A host that notes each time the menu waiting changed.
@MainActor private final class Host {
    var menus = 0
}

extension Host: CanvasEditorDelegate {
    func editorNeedsDisplay(_ editor: CanvasEditor) {}
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
    func editorMenuToPopUpDidChange(_ editor: CanvasEditor) { menus += 1 }
}

@MainActor let popUpMenuTests = Suite("Menus popped up from the canvas", [
    test("a menu asked for waits for the host, with the rect it opens below; the host says it popped it up") {
        let h = try EditorHarness(plugins: [FixturesPlugin()]), host = Host()
        h.editor.delegate = host
        expect(h.editor.menuToPopUp == nil)
        let menu = NSMenu(title: "Types")
        let rect = CGRect(x: 10, y: 20, width: 30, height: 12)
        h.editor.popUpMenu(menu, below: rect)
        expect(h.editor.menuToPopUp?.menu === menu)
        expectEqual(h.editor.menuToPopUp?.rect, rect)
        expectEqual(host.menus, 1)
        h.editor.menuDidPopUp()
        expect(h.editor.menuToPopUp == nil)
    },
    test("a second menu asked for while one waits replaces it") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let first = NSMenu(title: "1"), second = NSMenu(title: "2")
        h.editor.popUpMenu(first, below: .zero)
        h.editor.popUpMenu(second, below: CGRect(x: 1, y: 1, width: 1, height: 1))
        expect(h.editor.menuToPopUp?.menu === second)
    },
    test("a press that begins drops a menu that waits, and so does a file put in place") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.popUpMenu(NSMenu(title: "1"), below: .zero)
        h.press(at: CGPoint(x: 50, y: 50))
        expect(h.editor.menuToPopUp == nil)
        h.release()
        h.editor.popUpMenu(NSMenu(title: "2"), below: .zero)
        h.release()
        expect(h.editor.menuToPopUp != nil, "a release isn't a press")
        h.editor.replaceDocument(with: CanvasDocument())
        expect(h.editor.menuToPopUp == nil)
    },
    test("a pan from a middle-button press drops it too") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.popUpMenu(NSMenu(title: "1"), below: .zero)
        _ = h.editor.panPointerDown(PointerEvent(location: .zero, timestamp: 1, modifiers: [], clickCount: 1))
        expect(h.editor.menuToPopUp == nil)
    },
    test("a menu asked for with an item to highlight waits with it; asked for without, with none") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let menu = NSMenu(title: "Types")
        _ = menu.addItem(withTitle: "One", action: nil, keyEquivalent: "")
        let two = menu.addItem(withTitle: "Two", action: nil, keyEquivalent: "")
        h.editor.popUpMenu(menu, below: .zero)
        expect(h.editor.menuItemToHighlight == nil)
        h.editor.popUpMenu(menu, below: .zero, highlighting: two)
        expect(h.editor.menuItemToHighlight === two)
        expect(h.editor.menuToPopUp?.menu === menu)
    },
    test("a menu asked for with an item waits with it; asked again without, the item is gone; a press drops both") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let e = h.editor
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "One", action: nil, keyEquivalent: "")
        e.popUpMenu(menu, below: CGRect(x: 10, y: 10, width: 20, height: 20), highlighting: item)
        expect(e.menuItemToHighlight === item)
        expect(e.menuToPopUp?.menu === menu)
        e.popUpMenu(menu, below: CGRect(x: 10, y: 10, width: 20, height: 20))
        expect(e.menuItemToHighlight == nil, "today's call carries none")
        e.popUpMenu(menu, below: CGRect(x: 10, y: 10, width: 20, height: 20), highlighting: item)
        h.press(at: CGPoint(x: 500, y: 500))
        expect(e.menuToPopUp == nil)
        expect(e.menuItemToHighlight == nil)
        h.release()
        e.popUpMenu(menu, below: CGRect(x: 10, y: 10, width: 20, height: 20), highlighting: item)
        e.menuDidPopUp()
        expect(e.menuItemToHighlight == nil)
    },
    test("NSMenuItem(title:run:) runs its closure when chosen, its target kept alive by the item alone") {
        var ran = 0
        let menu = NSMenu()
        autoreleasepool { menu.addItem(NSMenuItem(title: "Go") { ran += 1 }) }
        let item = try require(menu.items.first)
        expectEqual(item.title, "Go")
        expect(item.target != nil, "nothing but the item holds the target, which outlives the pool it was made in")
        try menu.choose("Go")
        try menu.choose("Go")
        expectEqual(ran, 2)
    },
])
