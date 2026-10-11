import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Selection
import SwiftUI
import TableOfContents
import TestKit

/// The detail panel alone in an unshown window, its overview the editor's plugins'.
@MainActor
private final class OverviewWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: listWidth, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
    let hosting: NSView

    init(_ editor: CanvasEditor) {
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor))
        hosting.frame = CGRect(x: 0, y: 0, width: listWidth, height: 700)
        window.contentView = hosting
        window.settle()
    }

    /// The list's rows, less its header; nil while the panel shows no list.
    var rows: Int? { hosting.descendants(NSTableView.self).first.map { max(0, $0.numberOfRows - 1) } }
}

@MainActor let overviewTests = Suite("The table of contents as the detail panel's overview", [
    test("ContentsOverviewPlugin puts the list in the panel where it has no one shape to show: nothing selected, and under several") {
        let (file, _) = pocketFile(outside: ["A", "B", "C"], inside: [])
        let editor = try contentsEditor([PocketsPlugin(), DetailPanelPlugin(), ContentsOverviewPlugin()], file: file, scheduler: TaskScheduler())
        let w = OverviewWindow(editor)
        w.window.spin { w.rows == 4 }
        let (a, b) = (editor.document.shapes[0].id, editor.document.shapes[1].id)
        editor.selection = a
        w.window.spin { w.rows == nil }
        editor.selectedShapeIDs = [a, b]
        w.window.spin { w.rows == 2 }
    },
    test("without it the panel has no list, and the table of contents is as it was") {
        let (file, _) = pocketFile(outside: ["A"], inside: [])
        let editor = try contentsEditor([PocketsPlugin(), DetailPanelPlugin()], file: file, scheduler: TaskScheduler())
        let w = OverviewWindow(editor)
        w.window.settle()
        expectEqual(w.rows, nil)
        expectEqual(editor.contents.entries.outline, ["A", "pocket"])
    },
    test("it needs the detail panel, whose overview it gives") {
        expectThrows(RegistryError.ownerNotInstalled(point: "DetailOverviews", owner: .detailPanel, contributor: .contentsOverview)) {
            _ = try contentsRegistry([ContentsOverviewPlugin()])
        }
    },
])
