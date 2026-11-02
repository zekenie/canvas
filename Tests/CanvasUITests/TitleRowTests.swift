import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Chrome
import TestKit

// The window's title bar's row, which the canvas and the panes' sheets run under: what a press there does (`TitleRow`).

/// A canvas filling an unshown window whose content runs under its title bar and toolbar, as the app's does, with the probe
/// tool, which logs what it hears; and what the window was asked to do with a press in the row (`TitleRow.perform`, put back as
/// the test ends: a drag of an unshown window would wait for a release).
@MainActor private func rowCanvas() throws -> (canvas: CanvasView, window: NSWindow, log: PointerLog) {
    let log = PointerLog()
    let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "probe") {
        $0.tool(ToolDescriptor(id: .probe, label: "Probe", systemImage: "circle")) { _ in ProbeTool(log: log) }
        $0.defaultTool(.probe)
    }])
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.toolbar = NSToolbar(identifier: "row")
    window.toolbarStyle = .unified
    let canvas = CanvasView(editor: h.editor)
    window.contentView = canvas
    let perform = TitleRow.perform
    TitleRow.perform = { action, _, _ in log.events.append("window \(action)") }
    afterThisTest { TitleRow.perform = perform }
    return (canvas, window, log)
}

@MainActor let titleRowTests = Suite("The title bar's row", [
    test("a press there is the window's: a drag, and a double-click as the person set it, where the toolbar doesn't answer it itself") {
        expectEqual(TitleRow.action(clickCount: 1, underToolbar: false, setting: nil), .drag)
        expectEqual(TitleRow.action(clickCount: 1, underToolbar: true, setting: "Minimize"), .drag, "a drag whatever is under it")
        expectEqual(TitleRow.action(clickCount: 2, underToolbar: false, setting: nil), .zoom, "unset reads as zoom, the system's own")
        expectEqual(TitleRow.action(clickCount: 2, underToolbar: false, setting: "Maximize"), .zoom)
        expectEqual(TitleRow.action(clickCount: 2, underToolbar: false, setting: "Minimize"), .miniaturize)
        expectEqual(TitleRow.action(clickCount: 2, underToolbar: false, setting: "None"), .nothing)
        expectEqual(TitleRow.action(clickCount: 2, underToolbar: true, setting: nil), .nothing, "the toolbar's own view answers it")
    },
    test("a press on the board under the title bar's row is the window's, and the board hears none of it; under the row it's the board's") {
        let (canvas, window, log) = try rowCanvas()
        let row = window.frame.height - window.contentLayoutRect.maxY
        expect(row > 0, "the window has a title bar's row over its content: \(row)")
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 400, y: row / 2), time: 1))
        canvas.mouseDragged(with: window.mouse(.leftMouseDragged, at: CGPoint(x: 420, y: row / 2), time: 1.05))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 420, y: row / 2), time: 1.1))
        expectEqual(log.events.filter { $0 == "down" }, [], "the board hears no press")
        expectEqual(log.events.filter { $0.hasPrefix("window") }, ["window drag"])
        canvas.mouseDown(with: window.mouse(.leftMouseDown, at: CGPoint(x: 400, y: row + 40), time: 2))
        canvas.mouseUp(with: window.mouse(.leftMouseUp, at: CGPoint(x: 400, y: row + 40), time: 2.05))
        expectEqual(log.events.filter { $0 == "down" }, ["down"], "under the row, the board's")
        expectEqual(log.events.filter { $0.hasPrefix("window") }, ["window drag"])
    },
])
