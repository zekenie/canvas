import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import Composition
import Foundation
import Geometry
import LanguageModels
import Mentions
import Selection
import StickyNotes
import SwiftUI
import TestKit

/// Boards as the app configures them, with the app's content less its toolbar, and their clipboard
/// on `pasteboard` (a test that copies passes its own).
@MainActor func configureBoards(pasteboard: NSPasteboard = .general) throws {
    BoardDocument.configuration = BoardConfiguration(registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()),
                                                     coveredTop: ShippedPlugins.coveredTop(on:), boardName: ShippedPlugins.boardName(of:)) { board in
        AnyView(InspectorHost(editor: board.editor, focus: board.focus, showsDetails: board.view.showsDetails, showsMinimap: board.view.showsMinimap,
                              view: board.view))
    }
}

/// A board's canvas as the app shows it, with the minimap as the board's view says.
struct MinimapHost: View {
    let editor: CanvasEditor
    let focus: CanvasFocus
    let view: BoardViewState

    var body: some View {
        CanvasRepresentable(editor: editor, focus: focus, showsMinimap: view.showsMinimap)
    }
}

/// Runs the main run loop until `done`, for up to a second.
@MainActor func runLoop(until done: () -> Bool) {
    let deadline = Date(timeIntervalSinceNow: 1)
    while !done(), Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
}

/// A few turns of the main run loop, as `NSWindow.settle()` runs it, for a test whose point is
/// that nothing more happens: what a read sets off after it's over (a Task, an action scheduled
/// after zero) lands in the first. Nothing a board does once it's read is on a timer, so waiting
/// longer shows nothing more.
@MainActor func settleRunLoop() {
    for _ in 0..<5 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
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
        settleRunLoop()
        expect(!reopened.isDocumentEdited)
    },
    test("a board that needed repairs opens edited, and says what it kept aside") {
        try configureBoards()
        let id = ShapeID()
        let json = """
        { "format" : 1, "schema" : { "rectangle" : 0 }, "shapes" : [
          { "id" : "\(id)", "index" : "a0", "kind" : "rectangle", "props" : { "frame" : [[0, 0], [10, 10]] } },
          { "id" : "\(id)", "index" : "a1", "kind" : "rectangle", "props" : { "frame" : [[20, 0], [10, 10]] } },
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
    test("a board whose shapes hold properties the app can't use opens as it was, unedited, and says so") {
        try configureBoards()
        let id = ShapeID()
        let json = """
        { "format" : 3, "versions" : { "kinds" : { "rectangle" : 0 } }, "shapes" : [
          { "added" : { "confetti" : { "velocity" : 240 } }, "id" : "\(id)", "index" : "a0", "kind" : "rectangle",
            "props" : { "frame" : [[0, 0], [10, 10]] } } ] }
        """
        let board = BoardDocument()
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(board.loadReport.keptValues.map(\.key), ["confetti"])
        expect(board.loadReport.keptAside.isEmpty, "the rectangle itself shows")
        expectEqual(board.editor.document[id]?.keptProperties, ["confetti"])
        settleRunLoop()
        expect(!board.isDocumentEdited)
        let summary = try require(board.loadReport.summary)
        expectEqual(summary.message, "Some of this board can’t be used here.")
        expectEqual(summary.details, "1 shape holds a property this app can’t use (confetti), kept as it was; the shape shows without it. Saving keeps it.")
    },
    test("a file with other boards saves every one of them, those it can't show too, and Delete Hidden Shapes reaches them") {
        try configureBoards()
        // A rectangle owns no board, so the board filed under one is kept, with the gadget on it, and
        // so are a board no shape owns and an entry that isn't a board.
        let rectangle = ShapeID(), inside = ShapeID(), gadget = ShapeID(), orphan = ShapeID(), stray = ShapeID()
        func record(_ id: ShapeID, _ kind: String = "rectangle", _ index: String = "a0") -> String {
            #"{ "id" : "\#(id)", "index" : "\#(index)", "kind" : "\#(kind)", "props" : { "frame" : [[0, 0], [10, 10]] } }"#
        }
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "rectangle" : 0 } }, "shapes" : [ \(record(rectangle)) ],
          "boards" : { "\(rectangle)" : { "shapes" : [ \(record(inside)), \(record(gadget, "gadget", "a1")) ] },
                       "\(orphan)" : { "shapes" : [ \(record(stray)) ] },
                       "nope" : 7 } }
        """
        let board = BoardDocument()
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(Set(board.loadReport.keptBoards.map(\.key)), [rectangle.description, orphan.description, "nope"])
        expectEqual(board.loadReport.keptAside.map(\.id), [gadget])
        let summary = try require(board.loadReport.summary)
        expectEqual(summary.message, "Some of this board can’t be shown.")
        expect(summary.details.contains("3 boards in this file can’t be opened (3 shapes on them), kept as they were but hidden. Saving keeps them."), summary.details)
        runLoop { false }
        expect(!board.isDocumentEdited)

        let saved = try board.data(ofType: boardType)
        let reopened = BoardDocument()
        try reopened.read(from: saved, ofType: boardType)
        expectEqual(reopened.editor.file, board.editor.file, "every board, as it was")
        expectEqual(reopened.loadReport, board.loadReport)
        expectEqual(try reopened.data(ofType: boardType), saved)

        reopened.deleteHiddenShapes()
        expectEqual(reopened.editor.file.children, [:])
        expectEqual(reopened.editor.file.unreadableBoards, [:])
        expectEqual(reopened.editor.document.shapes.map(\.id), [rectangle])
        expect(reopened.isDocumentEdited)
    },
    test("a file that isn't a board won't open, says why, and offers an earlier version when there is one") {
        try configureBoards()
        do {
            try BoardDocument().read(from: Data("not a board".utf8), ofType: boardType)
            expect(false, "it opened")
        } catch let error as NSError {
            expectEqual(error.domain, NSCocoaErrorDomain)
            expectEqual(error.code, NSFileReadCorruptFileError)
            expect(error.localizedFailureReason?.contains("isn’t a board") == true, "\(error.localizedFailureReason ?? "")")
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
        settleRunLoop()
        expect(!board.isDocumentEdited)
    },
    test("a board's window hosts its canvas, and the zoom, inspector and back commands reach it") {
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
        window.spin { board.editor.camera.zoom > zoom }
        expectEqual(board.editor.cameraTarget.zoom, 2, "the next stop")
        controller.zoomToActualSize(nil)
        window.spin { board.editor.camera.zoom == 1 }
        let item = NSMenuItem(title: "", action: #selector(BoardWindowController.toggleDetails(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        expectEqual(item.title, "Hide Inspector")
        controller.toggleDetails(nil)
        expect(!board.viewState.showsDetails)
        _ = controller.validateMenuItem(item)
        expectEqual(item.title, "Show Inspector")

        let back = NSMenuItem(title: "Back", action: #selector(BoardWindowController.goBack(_:)), keyEquivalent: "[")
        expect(!controller.validateMenuItem(back), "nothing to go back to")
        board.editor.selection = board.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Here"))
        expect(controller.validateMenuItem(back))
        controller.goBack(nil)
        expectEqual(board.editor.selectedShapeIDs, [])
        expect(!controller.validateMenuItem(back))
    },
    test("View › Hide Minimap takes the minimap off the board's canvas, and Show Minimap puts it back") {
        BoardDocument.configuration = BoardConfiguration(registry: try ShippedPlugins.registry(model: ScriptedLanguageModel())) { board in
            AnyView(MinimapHost(editor: board.editor, focus: board.focus, view: board.view))
        }
        let board = BoardDocument()
        board.makeWindowControllers()
        defer { board.close() }
        let controller = try require(board.windowControllers.first as? BoardWindowController)
        let window = try require(controller.window)
        window.settle()
        let canvas = try require(board.focus.canvas)
        expect(canvas.minimap != nil, "a new board shows it")
        let item = NSMenuItem(title: "", action: #selector(BoardWindowController.toggleMinimap(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        expectEqual(item.title, "Hide Minimap")
        controller.toggleMinimap(nil)
        window.spin { canvas.minimap == nil }
        _ = controller.validateMenuItem(item)
        expectEqual(item.title, "Show Minimap")
        controller.toggleMinimap(nil)
        window.spin { canvas.minimap != nil }
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

        memory.remember(.init(x: 100, y: 50, zoom: 0.5, showsDetails: false, showsMinimap: false), for: a)
        let board = BoardDocument()
        board.viewMemory = memory
        board.fileURL = a
        board.makeWindowControllers()
        expectEqual(board.editor.camera.origin, CGPoint(x: 100, y: 50))
        expectEqual(board.editor.camera.zoom, 0.5)
        expect(!board.viewState.showsDetails)
        expect(!board.viewState.showsMinimap)
        board.editor.camera = Camera(origin: CGPoint(x: 7, y: 8), zoom: 2)
        board.viewState.showsMinimap = true
        board.close()
        expectEqual(memory.recall(for: a), .init(x: 7, y: 8, zoom: 2, showsDetails: false, showsMinimap: true), "closing remembers it")
    },
    test("a view remembered before boards had a minimap still reads, with the minimap showing") {
        let suite = "BoardDocumentTests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"[{ "path" : "/tmp/old.canvasboard", "view" : { "x" : 1, "y" : 2, "zoom" : 3, "showsDetails" : false } }]"#
        defaults.set(Data(old.utf8), forKey: "BoardViews")
        let memory = BoardViewMemory(defaults: defaults)
        expectEqual(memory.recall(for: URL(fileURLWithPath: "/tmp/old.canvasboard")), .init(x: 1, y: 2, zoom: 3, showsDetails: false, showsMinimap: true))
        expect(BoardViewState().showsMinimap, "a new board shows it")
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
        try check("View", "Show Minimap", "toggleMinimap:", "m", [.command, .control])
        try check("View", "Zoom In", "zoomIn:", "=")
        try check("View", "Zoom Out", "zoomOut:", "-")
        try check("View", "Actual Size", "zoomToActualSize:", "0")
        try check("View", "Zoom to Fit", "zoomToFit:", "1", .shift)
        try check("View", "Zoom to Selection", "zoomToSelection:", "2", .shift)
        try check("Go", "Back", "goBack:", "[")
        try check("Go", "Enclosing Board", "enclosingBoard:", "\u{F700}")
        try check("Go", "Open Selection", "openSelection:", "\u{F701}")
        expectEqual(menus.main.items.map(\.title), ["Infinite Canvas", "File", "Edit", "View", "Go", "Window", "Help"])
        try check("Infinite Canvas", "Settings…", "showSettings:", ",")
        let app = try require(menus.main.item(withTitle: "Infinite Canvas")?.submenu)
        expectEqual(app.items.prefix(4).map(\.title), ["About Infinite Canvas", "", "Settings…", ""], "Settings… follows About")
        try check("Infinite Canvas", "Quit Infinite Canvas", "terminate:", "q")
        expectEqual(menus.windows.title, "Window")
    },
    test("Edit › Delete deletes the selection, as the Delete key does") {
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel())
        let canvas = CanvasView(editor: editor)
        let id = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Doomed"))
        editor.selection = id
        canvas.delete(nil)
        expectEqual(editor.document[id], nil)
    },
])
