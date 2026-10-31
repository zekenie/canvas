import AppKit
import Canvas
import CanvasTesting
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// The sidebar the plugin gives the window (the host's slot), alone in an unshown window.
@MainActor
private final class SidebarWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: listWidth, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let hosting: NSView

    init(_ editor: CanvasEditor) throws {
        let sidebar = try require(editor.registry.hostSidebar, "no sidebar")
        hosting = NSHostingView(rootView: sidebar.view(for: editor, onExit: {}))
        hosting.frame = CGRect(x: 0, y: 0, width: listWidth, height: 700)
        window.contentView = hosting
        window.settle()
    }

    var table: NSTableView? { hosting.descendants(NSTableView.self).first }
    /// The list's rows, less its header; nil while it shows no list.
    var rows: Int? { table.map { max(0, $0.numberOfRows - 1) } }
}

@MainActor let sidebarTests = Suite("The table of contents as the window's sidebar", [
    test("the plugin gives the window's sidebar its list, every shape whatever is selected") {
        let (file, _) = pocketFile(outside: ["A", "B", "C"], inside: [])
        let editor = try contentsEditor([PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let w = try SidebarWindow(editor)
        w.window.spin { w.rows == 4 }
        let (a, b) = (editor.document.shapes[0].id, editor.document.shapes[1].id)
        editor.selection = a
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        expectEqual(w.rows, 4)
        editor.selectedShapeIDs = [a, b]
        w.window.spin { w.table?.selectedRowIndexes.count == 2 }
        expectEqual(w.rows, 4)
    },
    test("the list's outline takes the keyboard when the window gives the sidebar it") {
        let (file, _) = pocketFile(outside: ["A"], inside: [])
        let editor = try contentsEditor([PocketsPlugin()], file: file, scheduler: TaskScheduler())
        let sidebar = try require(editor.registry.hostSidebar)
        expect(sidebar.keyboardEntry?(editor) == nil, "no list yet")
        let w = try SidebarWindow(editor)
        w.window.spin { w.table != nil }
        expect(sidebar.keyboardEntry?(editor) === w.table)
    },
    test("the report says it") {
        let report = try contentsRegistry().report
        expect(report.contains("host sidebar"), report)
    },
])
