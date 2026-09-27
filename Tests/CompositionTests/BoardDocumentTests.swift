import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import Composition
import Foundation
import Geometry
import Selection
import StickyNotes
import SwiftUI
import TestKit

/// Boards as the app configures them, with the app's content less its toolbar.
@MainActor func configureBoards() throws {
    BoardDocument.configuration = BoardConfiguration(registry: try ShippedPlugins.registry()) { board in
        AnyView(InspectorHost(editor: board.editor, focus: board.focus, showsDetails: board.view.showsDetails))
    }
}

/// Runs the main run loop until `done`, for up to a second.
@MainActor func runLoop(until done: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 1)
    while !done(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
}

@MainActor func scratchURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("BoardDocumentTests-\(UUID().uuidString)-\(name)")
}

let boardType = "com.example.InfiniteCanvas.board"

@MainActor let boardDocumentTests = Suite("Board documents", [
    test("editing marks a board edited; the camera, the selection and a new board's shapes don't") {
        try configureBoards()
        let board = BoardDocument()
        board.start(with: WelcomeBoard.document())
        expect(!board.isDocumentEdited)
        board.editor.camera = Camera(origin: CGPoint(x: 40, y: 40), zoom: 2)
        board.editor.selection = board.editor.document.shapes.first?.id
        expect(!board.isDocumentEdited)
        board.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "New"))
        expect(board.isDocumentEdited)
    },
    test("a board saves as the codec writes it, and opens as the same document, unedited") {
        try configureBoards()
        let board = BoardDocument()
        board.start(with: WelcomeBoard.document())
        let data = try board.data(ofType: boardType)
        expectEqual(data, try BoardCodec(registry: board.editor.registry).encode(board.editor.document))
        let reopened = BoardDocument()
        try reopened.read(from: data, ofType: boardType)
        expectEqual(reopened.editor.document, board.editor.document)
        expect(reopened.loadReport.isEmpty)
        runLoop { false }
        expect(!reopened.isDocumentEdited)
    },
    test("a board that needed repairs opens edited, and says what it kept aside") {
        try configureBoards()
        let id = ShapeID()
        let json = """
        { "format" : 1, "schema" : { "ellipse" : 0 }, "shapes" : [
          { "id" : "\(id)", "index" : "a0", "kind" : "ellipse", "props" : { "frame" : [[0, 0], [10, 10]] } },
          { "id" : "\(id)", "index" : "a1", "kind" : "ellipse", "props" : { "frame" : [[20, 0], [10, 10]] } },
          { "id" : "\(ShapeID())", "index" : "a2", "kind" : "gadget", "props" : { } } ] }
        """
        let board = BoardDocument()
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(board.editor.document.shapes.count, 3)
        expectEqual(board.loadReport.repairs.count, 1)
        expectEqual(board.loadReport.keptAside.map(\.kind.rawValue), ["gadget"])
        runLoop { board.isDocumentEdited }
        expect(board.isDocumentEdited, "its repairs are saved with it")
        let summary = try require(board.loadReport.summary)
        expect(summary.message.contains("can’t be shown"), summary.message)
        expect(summary.details.contains("1 shape is kept as it was but hidden: 1 shape of a kind this app doesn’t have (gadget)"), summary.details)
        expect(summary.details.contains("1 repair was made"), summary.details)
        expect(LoadReport().summary == nil)
    },
    test("a file that isn't a board won't open, says why, and offers an earlier version when there is one") {
        try configureBoards()
        do {
            try BoardDocument().read(from: Data("not a board".utf8), ofType: boardType)
            expect(false, "it opened")
        } catch let error as NSError {
            expectEqual(error.domain, NSCocoaErrorDomain)
            expectEqual(error.code, NSFileReadCorruptFileError)
            expect(error.localizedFailureReason?.contains("isn't a board") == true, "\(error.localizedFailureReason ?? "")")
            expectEqual(error.localizedRecoveryOptions, nil)
        }
        let newer = BoardDocument.openError(BoardReadError.newerFormat(9), earlierVersion: URL(fileURLWithPath: "/tmp/earlier.canvasboard"))
        expect(newer.localizedFailureReason?.contains("newer version") == true, "\(newer.localizedFailureReason ?? "")")
        expectEqual(newer.localizedRecoveryOptions, ["Open Earlier Version", "Cancel"])
        expect(newer.recoveryAttempter != nil)
    },
    test("reverting puts the saved board back, unedited") {
        try configureBoards()
        let url = scratchURL("revert.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let board = BoardDocument()
        board.start(with: WelcomeBoard.document())
        try board.data(ofType: boardType).write(to: url)
        board.fileURL = url
        let saved = board.editor.document
        board.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Unsaved"))
        expect(board.isDocumentEdited)
        try board.revert(toContentsOf: url, ofType: boardType)
        expectEqual(board.editor.document, saved)
        runLoop { false }
        expect(!board.isDocumentEdited)
    },
    test("a board's window hosts its canvas, and the zoom and inspector commands reach it") {
        try configureBoards()
        let board = BoardDocument()
        board.makeWindowControllers()
        defer { board.close() }
        let controller = try require(board.windowControllers.first as? BoardWindowController)
        let window = try require(controller.window)
        window.settle()
        expect(board.focus.canvas != nil, "the window's content made the canvas")
        expect(window.windowController === controller, "the controller is in the window's responder chain")
        let zoom = board.editor.camera.zoom
        controller.zoomIn(nil)
        expect(board.editor.camera.zoom > zoom)
        controller.zoomToActualSize(nil)
        expectEqual(board.editor.camera.zoom, 1)
        let item = NSMenuItem(title: "", action: #selector(BoardWindowController.toggleDetails(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        expectEqual(item.title, "Hide Inspector")
        controller.toggleDetails(nil)
        expect(!board.viewState.showsDetails)
        _ = controller.validateMenuItem(item)
        expectEqual(item.title, "Show Inspector")
    },
    test("each board's view is remembered by its file, most recent first, and restored when its window opens") {
        try configureBoards()
        let suite = "BoardDocumentTests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = BoardViewMemory(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/a.canvasboard"), b = URL(fileURLWithPath: "/tmp/b.canvasboard")
        memory.remember(.init(x: 1, y: 2, zoom: 3, showsDetails: false), for: a)
        memory.remember(.init(x: 4, y: 5, zoom: 6, showsDetails: true), for: b)
        expectEqual(memory.recall(for: a), .init(x: 1, y: 2, zoom: 3, showsDetails: false))
        expectEqual(memory.recall(for: URL(fileURLWithPath: "/tmp/c.canvasboard")), nil)
        for i in 0..<BoardViewMemory.limit { memory.remember(.init(x: 0, y: 0, zoom: 1, showsDetails: true), for: URL(fileURLWithPath: "/tmp/\(i).canvasboard")) }
        expectEqual(memory.recall(for: a), nil, "the oldest are forgotten")

        memory.remember(.init(x: 100, y: 50, zoom: 0.5, showsDetails: false), for: a)
        let board = BoardDocument()
        board.viewMemory = memory
        board.fileURL = a
        board.makeWindowControllers()
        expectEqual(board.editor.camera.origin, CGPoint(x: 100, y: 50))
        expectEqual(board.editor.camera.zoom, 0.5)
        expect(!board.viewState.showsDetails)
        board.editor.camera = Camera(origin: CGPoint(x: 7, y: 8), zoom: 2)
        board.close()
        expectEqual(memory.recall(for: a), .init(x: 7, y: 8, zoom: 2, showsDetails: false), "closing remembers it")
    },
    test("the menus send a document app's standard actions, with their shortcuts") {
        let menus = BoardMenus.make(appName: "Infinite Canvas")
        @MainActor func item(_ menu: String, _ title: String) throws -> NSMenuItem {
            let submenu = try require(menus.main.item(withTitle: menu)?.submenu, menu)
            return try require(submenu.item(withTitle: title), "\(menu) › \(title)")
        }
        @MainActor func check(_ menu: String, _ title: String, _ action: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) throws {
            let found = try item(menu, title)
            expectEqual(found.action.map(NSStringFromSelector), action, "\(menu) › \(title)")
            expectEqual(found.keyEquivalent, key, "\(menu) › \(title)")
            if !key.isEmpty { expectEqual(found.keyEquivalentModifierMask, modifiers, "\(menu) › \(title)") }
        }
        try check("File", "New", "newDocument:", "n")
        try check("File", "Open…", "openDocument:", "o")
        try check("File", "Close", "performClose:", "w")
        try check("File", "Save…", "saveDocument:", "s")
        try check("File", "Revert to Saved", "revertDocumentToSaved:")
        let recent = try require(item("File", "Open Recent").submenu)
        expectEqual(recent.items.map { $0.action.map(NSStringFromSelector) }, ["clearRecentDocuments:"])
        try check("Edit", "Delete", "delete:")
        try check("Edit", "Select All", "selectAll:", "a")
        try check("View", "Show Inspector", "toggleDetails:", "i", [.command, .control])
        try check("View", "Zoom In", "zoomIn:", "=")
        try check("View", "Zoom Out", "zoomOut:", "-")
        try check("View", "Actual Size", "zoomToActualSize:", "0")
        try check("Infinite Canvas", "Quit Infinite Canvas", "terminate:", "q")
        expectEqual(menus.windows.title, "Window")
    },
    test("Edit › Delete deletes the selection, as the Delete key does") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler())
        let canvas = CanvasView(editor: editor)
        let id = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Doomed"))
        editor.selection = id
        canvas.delete(nil)
        expectEqual(editor.document[id], nil)
    },
])
