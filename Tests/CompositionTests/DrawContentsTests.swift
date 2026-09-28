import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Composition
import LanguageModels
import SwiftUI
import TableOfContents
import TestKit

// `canvas draw` beside the table of contents, as the app shows it: a draw is one commit, which may
// bring rows in at several places at once (a new shape at the end, and edges nested under the
// shapes they start from, wherever those are listed).

/// The app's window over an empty board, unshown: the canvas with the shipped detail panel, which
/// lists the board with nothing selected.
@MainActor
final class DrawingWindow {
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: TaskScheduler(), model: ScriptedLanguageModel())
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    let focus = CanvasFocus()
    let host: NSHostingView<InspectorHost>

    init() {
        host = NSHostingView(rootView: InspectorHost(editor: editor, focus: focus, showsDetails: true))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.settle()
    }

    /// The table of contents' list, if the panel shows it.
    var contents: NSTableView? { host.descendants(NSTableView.self).first { $0.isTableOfContents } }
    /// Its rows, less its header.
    var rows: Int { max(0, (contents?.numberOfRows ?? 0) - 1) }

    /// Runs `canvas draw` on this board as the app's command server does, and says what it drew.
    @discardableResult
    func draw(_ script: String) throws -> JSON {
        let commands = ShippedPlugins.commands(in: editor.registry)
        let spec = try require(commands.specs.first { $0.name == "draw" })
        let params = try spec.params(from: ["-"], standardInput: { script })
        return try commands.run(spec.name, .object(params), editor)
    }
}

@MainActor let drawContentsTests = Suite("canvas draw beside the table of contents", [
    test("a draw that adds a shape, and edges from two shapes far apart in the list, logs no reentrant update") {
        let w = DrawingWindow()
        let middle = (1...24).map { #"sticky-note "Note \#($0)" below "First" text: "\#($0)""# }
        try w.draw(([#"sticky-note "First" text: "the first""#] + middle + [#"sticky-note "Last" right of "First" text: "the last""#])
            .joined(separator: "\n"))
        w.window.spin { w.rows == 26 }
        let log = try standardError {
            let result = try w.draw("""
                sticky-note "New" below "Last" text: "the newest"
                edge "First" -> "Last"
                edge "Last" -> "New"
                edge "Note 12" -> "New"
                """)
            expectEqual(result["changes"]?.arrayValue?.map { $0["did"] }, ["created", "connected", "connected", "connected"])
            w.window.spin { w.rows >= 27 }
            w.window.settle()
        }
        expect(!log.contains(tableReentrancyWarning), "AppKit logged: \(log)")
        let entries = try require(w.editor.tableOfContents).entries
        expectEqual(entries.count, 27, "each note, the arrows under the notes they start from")
        expectEqual(entries.filter { $0.children != nil }.count, 3)
    },
])
