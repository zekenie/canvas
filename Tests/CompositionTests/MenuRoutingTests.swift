import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import Selection
import StickyNotes
import TaskCards
import TestKit

/// The menus a test saw open, each closed as soon as it opened.
@MainActor final class OpenedMenus {
    var outlines: [[String]] = []
    var last: NSMenu?
}

// What the Control-click handling relies on: AppKit asks the view for a Control-click's menu
// before sending mouseDown, and sends mouseDown only when there's none. A context menu is a window
// of its own, so this puts one on screen for a moment: opt-in, with TEST_UI_MENUS=1.
@MainActor let menuRoutingTests = Suite("Context menu routing, on screen", [
    test("a Control-click goes to the menu first: shown, it never presses; with none, the select tool ignores it; a right-click opens it too") {
        NSApplication.shared.setActivationPolicy(.accessory)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard)
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: 800, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let canvas = CanvasView(editor: editor)
        window.contentView = canvas
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        let task = editor.add(TaskCard(frame: CGRect(x: 400, y: 40, width: 240, height: 200), title: "Ship"))

        let opened = OpenedMenus()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            nonisolated(unsafe) let object = note.object          // posted on the main thread, as tracking begins
            MainActor.assumeIsolated {
                guard let menu = object as? NSMenu else { return }
                opened.outlines.append(menu.outline)
                opened.last = menu
                RunLoop.main.perform(inModes: [.eventTracking, .common]) { MainActor.assumeIsolated { opened.last?.cancelTracking() } }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        @MainActor func click(_ down: NSEvent.EventType, _ up: NSEvent.EventType, at point: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
            let time = ProcessInfo.processInfo.systemUptime
            window.sendEvent(window.mouse(down, at: point, modifiers: modifiers, time: time))
            window.sendEvent(window.mouse(up, at: point, modifiers: modifiers, time: time + 0.05))
        }

        click(.leftMouseDown, .leftMouseUp, at: CGPoint(x: 520, y: 140), .control)
        expectEqual(opened.outlines.first?.first, "Status ▸")
        expectEqual(editor.selectedShapeIDs, [task])
        expect(editor.session == nil)

        click(.leftMouseDown, .leftMouseUp, at: CGPoint(x: 190, y: 500), .control)
        expectEqual(opened.outlines.count, 1, "empty canvas has nothing to offer")
        expectEqual(editor.selectedShapeIDs, [task], "and the Control-click that reached mouseDown didn't deselect")

        click(.rightMouseDown, .rightMouseUp, at: CGPoint(x: 520, y: 140), [])
        expectEqual(opened.outlines.count, 2)
    },
])
