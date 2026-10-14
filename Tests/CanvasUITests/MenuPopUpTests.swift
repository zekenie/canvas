import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import TestKit

// The editor's menu is a pop-up under a rect: where it is queued is tested here, since a menu's
// tracking doesn't run in an unshown window.

@MainActor private func canvasInWindow() throws -> (h: EditorHarness, canvas: CanvasView, window: NSWindow) {
    let h = try EditorHarness(plugins: [FixturesPlugin()])
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: h.editor)
    window.contentView = canvas
    return (h, canvas, window)
}

@MainActor let menuPopUpTests = Suite("The menu popped up from the canvas", [
    test("a queued menu is popped up on the next turn of the run loop, under the rect it was asked for, and not before") {
        let (h, canvas, window) = try canvasInWindow()
        var shown: [(String, CGPoint)] = []
        canvas.menuPresenter = { menu, point, _ in shown.append((menu.title, point)) }
        h.editor.camera = Camera(origin: CGPoint(x: 10, y: 20), zoom: 2)
        h.editor.popUpMenu(NSMenu(title: "Types"), below: CGRect(x: 100, y: 100, width: 40, height: 10))
        expectEqual(shown.count, 0, "not inside the click that asked")
        expect(h.editor.menuToPopUp != nil)
        window.settle()
        expectEqual(shown.map(\.0), ["Types"])
        expectEqual(shown.first?.1, h.editor.camera.toView(CGPoint(x: 100, y: 110)), "the rect's bottom-left, in the view")
        expect(h.editor.menuToPopUp == nil)
        window.settle()
        expectEqual(shown.count, 1, "once")
    },
    test("a press that begins before the turn drops it; the next request is popped up") {
        let (h, canvas, window) = try canvasInWindow()
        var shown: [String] = []
        canvas.menuPresenter = { menu, _, _ in shown.append(menu.title) }
        h.editor.popUpMenu(NSMenu(title: "First"), below: .zero)
        h.press(at: CGPoint(x: 5, y: 5))
        window.settle()
        h.release()
        expectEqual(shown, [])
        h.editor.popUpMenu(NSMenu(title: "Second"), below: .zero)
        window.settle()
        expectEqual(shown, ["Second"])
    },
    test("a menu asked for twice before the turn is popped up once: the second") {
        let (h, canvas, window) = try canvasInWindow()
        var shown: [String] = []
        canvas.menuPresenter = { menu, _, _ in shown.append(menu.title) }
        h.editor.popUpMenu(NSMenu(title: "First"), below: .zero)
        h.editor.popUpMenu(NSMenu(title: "Second"), below: .zero)
        window.settle()
        expectEqual(shown, ["Second"])
    },
    test("the item to highlight reaches the host with the menu and the point; a menu with none reaches it with none; the second request's item replaces the first's") {
        let (h, canvas, window) = try canvasInWindow()
        var shown: [(String, NSMenuItem?)] = []
        canvas.menuPresenter = { menu, _, item in shown.append((menu.title, item)) }
        let menu = NSMenu(title: "Types")
        let first = menu.addItem(withTitle: "First", action: nil, keyEquivalent: "")
        let second = menu.addItem(withTitle: "Second", action: nil, keyEquivalent: "")
        h.editor.popUpMenu(menu, below: CGRect(x: 100, y: 100, width: 40, height: 10), highlighting: second)
        expect(h.editor.menuItemToHighlight === second, "queued with it")
        window.settle()
        expectEqual(shown.map(\.0), ["Types"])
        expect(shown.first?.1 === second, "the host pops the menu up with the item")
        h.editor.popUpMenu(menu, below: .zero)
        window.settle()
        expect(shown.last?.1 == nil, "asked for with none, popped up with none")
        h.editor.popUpMenu(menu, below: .zero, highlighting: first)
        h.editor.popUpMenu(menu, below: .zero, highlighting: second)
        window.settle()
        expectEqual(shown.count, 3, "once")
        expect(shown.last?.1 === second, "the second request's item")
    },
])
