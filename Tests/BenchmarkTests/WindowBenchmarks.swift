import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import LanguageModels
import ShippedTesting
import SwiftUI
import TableOfContents
import TestKit

// A board document's own window, made as the app makes it (an NSHostingController for the window's
// content: the canvas, and `BoardChrome`'s sidebar, which shows the table of contents, and inspector),
// unshown: from making its controllers to the window, and from there to the table of
// contents' rows in its outline, one for each row listed at the top. Reported, not held to a budget:
// the list's first showing was quadratic while it was SwiftUI's `List` (some 88 s at 10,000 shapes),
// and the outline costs the rows in view and a pass over those listed.

/// The window's content as the app's (`ContentView`, which the app keeps to itself), less its toolbar
/// and the minimap.
struct BoardWindowBench: View {
    let editor: CanvasEditor
    let focus: CanvasFocus

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus, showsMinimap: false)
            .frame(minWidth: 480, minHeight: 320)
            .modifier(BoardChrome(editor: editor, showsSidebar: .constant(true), showsInspector: .constant(true), onExit: focus.take))
            .transaction { $0.disablesAnimations = true }
    }
}

@MainActor let windowBenchmarks = Suite("Window benchmarks", [
    test("a board's own window made, and the table of contents' rows shown in it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        BoardDocument.configuration = BoardConfiguration(registry: try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: ScriptedLanguageModel())),
                                                         imagePasteboard: pasteboard) { board in
            AnyView(BoardWindowBench(editor: board.editor, focus: board.focus))
        }
        for size in sizes {
            let board = BoardDocument()
            defer { board.close() }
            board.editor.replaceFile(with: CanvasFile(root: generatedBoard(shapes: size)))
            let clock = ContinuousClock()
            var window: NSWindow?
            let listed = board.editor.tableOfContents?.entries.count ?? -1
            // The outline's rows, less its header.
            let rows = { max(0, (window?.contentView?.descendants(NSTableView.self).first?.numberOfRows ?? 0) - 1) }
            let made = clock.measure {
                board.makeWindowControllers()
                window = board.windowControllers.first?.window
            }.milliseconds
            let shown = clock.measure { window?.spin(until: { rows() == listed }, timeout: 120) }.milliseconds
            expect(rows() == listed, "the table of contents lists every row at the top")
            report(String(format: "%6d shapes, a board's own window made %.0f ms, the table of contents' %d rows shown in it %.0f ms after (reported)", size, made, listed, shown))
        }
    },
])
