import AppKit
import Boards
import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import DetailPanel
import Find
import Foundation
import Geometry
import Grouping
import JumpTo
import LanguageModels
import Mentions
import Reordering
import Selection
import ShippedTesting
import Stickers
import StickyNotes
import SwiftUI
import TestKit
import Validation

/// Boards as the app configures them, with the app's content less its toolbar, and their clipboard
/// and Copy as Image's pasteboard on `pasteboard` (the test's own unless it passes one).
/// `extra`: plugins after the shipped list.
@MainActor func configureBoards(pasteboard: NSPasteboard = ShippedPlugins.pasteboard, model: ScriptedLanguageModel = ScriptedLanguageModel(),
                                extra: [any CanvasPlugin] = [], sidebar: Bool = false) throws {
    BoardDocument.configuration = BoardConfiguration(registry: try Registry(plugins: ShippedPlugins.plugins(pasteboard: pasteboard, model: model) + extra),
                                                     imagePasteboard: pasteboard) { board in
        // A window opens with its sidebar hidden unless the test is about it, so the canvas starts at the
        // window's left edge, where the tests' points take it (a view remembered for its file still says).
        board.view.showsSidebar = sidebar
        return AnyView(InspectorHost(editor: board.editor, focus: board.focus, showsDetails: board.view.showsDetails, showsMinimap: board.view.showsMinimap,
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

/// After each test (main.swift's `afterEach`): the boards it left open are closed, and one it left
/// with changes fails it. AppKit autosaves an edited board 15 s after its last change, or after the
/// last event sent through NSApp, if that's later, in whatever test is running then; a test's board
/// has no file type (NSDocumentController gives the app's theirs), so one given a file throws
/// "inTypeName is nil" there, and the run ends. Whether those 15 s passed before the run ended
/// depended on how busy the machine was.
@MainActor func closeBoardsLeftOpen() {
    for board in BoardDocument.unclosed {
        expect(!board.isDocumentEdited, "board \(board.number), \(board.displayName ?? ""), was left open with changes: close it")
        board.close()
    }
}

@MainActor func scratchURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("BoardDocumentTests-\(UUID().uuidString)-\(name)")
}

let boardType = "com.example.InfiniteCanvas.board"

@MainActor let boardDocumentTests = Suite("Board documents", [
    test("editing marks a board edited; the camera, the selection and a new board's shapes don't") {
        try configureBoards()
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
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
        board.start(with: SampleBoard.document())
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
        { "format" : 1, "schema" : { "subboard" : 0 }, "shapes" : [
          { "id" : "\(id)", "index" : "a0", "kind" : "subboard", "props" : { "frame" : [[0, 0], [10, 10]] } },
          { "id" : "\(id)", "index" : "a1", "kind" : "subboard", "props" : { "frame" : [[20, 0], [10, 10]] } },
          { "id" : "\(ShapeID())", "index" : "a2", "kind" : "gadget", "props" : { } } ] }
        """
        let board = BoardDocument()
        defer { board.close() }
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
        { "format" : 3, "versions" : { "kinds" : { "subboard" : 0 } }, "shapes" : [
          { "added" : { "confetti" : { "velocity" : 240 } }, "id" : "\(id)", "index" : "a0", "kind" : "subboard",
            "props" : { "frame" : [[0, 0], [10, 10]] } } ] }
        """
        let board = BoardDocument()
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(board.loadReport.keptValues.map(\.key), ["confetti"])
        expect(board.loadReport.keptAside.isEmpty, "the subboard itself shows")
        expectEqual(board.editor.document[id]?.keptProperties, ["confetti"])
        settleRunLoop()
        expect(!board.isDocumentEdited)
        let summary = try require(board.loadReport.summary)
        expectEqual(summary.message, "Some of this board can’t be used here.")
        expectEqual(summary.details, "1 shape holds a property this app can’t use (confetti), kept as it was; the shape shows without it. Saving keeps it.")
    },
    test("a file with other boards saves every one of them, those it can't show too, and Delete Hidden Shapes reaches them") {
        try configureBoards()
        // A note owns no board, so the board filed under one is kept, with the gadget on it, and
        // so are a board no shape owns and an entry that isn't a board.
        let note = ShapeID(), inside = ShapeID(), gadget = ShapeID(), orphan = ShapeID(), stray = ShapeID()
        func record(_ id: ShapeID, _ kind: String = "sticky-note", _ index: String = "a0") -> String {
            #"{ "id" : "\#(id)", "index" : "\#(index)", "kind" : "\#(kind)", "props" : { "frame" : [[0, 0], [10, 10]] } }"#
        }
        let json = """
        { "format" : 4, "versions" : { "kinds" : { "sticky-note" : 3 } }, "shapes" : [ \(record(note)) ],
          "boards" : { "\(note)" : { "shapes" : [ \(record(inside)), \(record(gadget, "gadget", "a1")) ] },
                       "\(orphan)" : { "shapes" : [ \(record(stray)) ] },
                       "nope" : 7 } }
        """
        let board = BoardDocument()
        try board.read(from: Data(json.utf8), ofType: boardType)
        expectEqual(Set(board.loadReport.keptBoards.map(\.key)), [note.description, orphan.description, "nope"])
        expectEqual(board.loadReport.keptAside.map(\.id), [gadget])
        let summary = try require(board.loadReport.summary)
        expectEqual(summary.message, "Some of this board can’t be shown.")
        expect(summary.details.contains("3 boards in this file can’t be opened (3 shapes on them), kept as they were but hidden. Saving keeps them."), summary.details)
        runLoop { false }
        expect(!board.isDocumentEdited)

        let saved = try board.data(ofType: boardType)
        let reopened = BoardDocument()
        defer { reopened.close() }
        try reopened.read(from: saved, ofType: boardType)
        expectEqual(reopened.editor.file, board.editor.file, "every board, as it was")
        expectEqual(reopened.loadReport, board.loadReport)
        expectEqual(try reopened.data(ofType: boardType), saved)

        reopened.deleteHiddenShapes()
        expectEqual(reopened.editor.file.children, [:])
        expectEqual(reopened.editor.file.unreadableBoards, [:])
        expectEqual(reopened.editor.document.shapes.map(\.id), [note])
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
        defer { board.close() }
        board.start(with: SampleBoard.document())
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
    test("a value a plugin keeps on the file saves with the board, opens with it, and goes back on a revert") {
        try configureBoards(extra: [LetterheadPlugin()])
        defer { try? configureBoards() }
        let url = scratchURL("headed.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
        let plain = try board.data(ofType: boardType)
        board.editor.transact("Head File") { $0.setFileValue(Letterhead.self, to: "Acme") }
        expect(board.isDocumentEdited, "a file value edits the board")
        let data = try board.data(ofType: boardType)
        expectEqual(data, try BoardCodec(registry: board.editor.registry).encode(board.editor.file))
        expect(data != plain)
        let reopened = BoardDocument()
        defer { reopened.close() }
        try reopened.read(from: data, ofType: boardType)
        expectEqual(reopened.editor.file[Letterhead.self], "Acme")
        expectEqual(reopened.editor.file, board.editor.file)
        expect(reopened.loadReport.isEmpty)
        settleRunLoop()
        expect(!reopened.isDocumentEdited)
        expectEqual(try reopened.data(ofType: boardType), data)

        // Saved with it, changed, and reverted: the saved value is back, unedited.
        try data.write(to: url)
        board.fileURL = url
        board.editor.transact("Head File") { $0.setFileValue(Letterhead.self, to: "Apex") }
        try board.revert(toContentsOf: url, ofType: boardType)
        expectEqual(board.editor.file[Letterhead.self], "Acme")
        settleRunLoop()
        expect(!board.isDocumentEdited)
        // Undone to none, the board saves as it did before it had one.
        reopened.editor.transact("Head File") { $0.setFileValue(Letterhead.self, to: "") }
        expectEqual(try reopened.data(ofType: boardType), plain)
        reopened.editor.undo()
        expect(!reopened.isDocumentEdited, "undone to what was read, it reads unedited")

        // One the app can't use is kept, said, and saved back.
        let unknown = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #""letterhead" : {"#, with: #""confetti" : {"#)
        let kept = BoardDocument()
        try kept.read(from: Data(unknown.utf8), ofType: boardType)
        expectEqual(kept.loadReport.keptFileValues.map(\.key), ["confetti"])
        expectEqual(kept.editor.file.keptFileValues, ["confetti"])
        let summary = try require(kept.loadReport.summary)
        expectEqual(summary.message, "Some of this board can’t be used here.")
        expectEqual(summary.details, "The file holds a value this app can’t use (confetti), kept as it was. Saving keeps it.")
        settleRunLoop()
        expect(!kept.isDocumentEdited)
        expectEqual(String(decoding: try kept.data(ofType: boardType), as: UTF8.self), unknown)
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
        controller.runCommand(commandItem(.zoomIn))
        window.spin { board.editor.camera.zoom > zoom }
        expectEqual(board.editor.cameraTarget.zoom, 2, "the next stop")
        controller.runCommand(commandItem(.zoomToActualSize))
        window.spin { board.editor.camera.zoom == 1 }
        let back = commandItem(.goBack, title: "Back")
        expect(!controller.validateMenuItem(back), "nothing to go back to")
        board.editor.goTo([board.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Here"))])
        expect(controller.validateMenuItem(back))
        controller.runCommand(back)
        expectEqual(board.editor.selectedShapeIDs, [])
        expect(!controller.validateMenuItem(back))

        let item = NSMenuItem(title: "", action: #selector(BoardWindowController.toggleDetails(_:)), keyEquivalent: "")
        expect(!controller.validateMenuItem(item), "nothing selected: nothing to show")
        expectEqual(item.title, "Show Inspector")
        let shown = board.editor.add(StickyNote(frame: CGRect(x: 0, y: 300, width: 200, height: 200), text: "Shown"))
        board.editor.selection = shown
        expect(controller.validateMenuItem(item))
        expectEqual(item.title, "Hide Inspector")
        controller.toggleDetails(nil)
        expect(!board.viewState.showsDetails)
        expect(controller.validateMenuItem(item))
        expectEqual(item.title, "Show Inspector")
        board.editor.selection = nil
        let sidebar = NSMenuItem(title: "", action: #selector(BoardWindowController.toggleSidebarShown(_:)), keyEquivalent: "")
        board.viewState.showsSidebar = true
        expect(controller.validateMenuItem(sidebar))
        expectEqual(sidebar.title, "Hide Sidebar")
        controller.toggleSidebarShown(nil)
        expect(!board.viewState.showsSidebar)
        _ = controller.validateMenuItem(sidebar)
        expectEqual(sidebar.title, "Show Sidebar")
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
        let canvas = try require(board.focus.canvas)
        expect(!canvas.zoomIndicator.isShowing, "opening at 50% isn't a change of zoom")
        expect(!board.viewState.showsDetails)
        expect(!board.viewState.showsMinimap)
        board.editor.camera = Camera(origin: CGPoint(x: 7, y: 8), zoom: 2)
        board.viewState.showsMinimap = true
        board.close()
        expectEqual(memory.recall(for: a), .init(x: 7, y: 8, zoom: 2, showsDetails: false, showsMinimap: true), "closing remembers it")
    },
    test("a view remembered before boards had a minimap or a sidebar still reads, with both showing") {
        let suite = "BoardDocumentTests-\(UUID().uuidString)"
        let defaults = try require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = #"[{ "path" : "/tmp/old.canvasboard", "view" : { "x" : 1, "y" : 2, "zoom" : 3, "showsDetails" : false } }]"#
        defaults.set(Data(old.utf8), forKey: "BoardViews")
        let memory = BoardViewMemory(defaults: defaults)
        expectEqual(memory.recall(for: URL(fileURLWithPath: "/tmp/old.canvasboard")), .init(x: 1, y: 2, zoom: 3, showsDetails: false, showsMinimap: true))
        expectEqual(memory.recall(for: URL(fileURLWithPath: "/tmp/old.canvasboard"))?.showsSidebar, true)
        expect(BoardViewState().showsMinimap && BoardViewState().showsSidebar, "a new board shows them")
    },
    test("the menus send a document app's standard actions, with their shortcuts, and the plugins' commands, each where it says, with its key") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: try ShippedPlugins.registry(pasteboard: pasteboard, model: ScriptedLanguageModel()))
        @MainActor func item(_ menu: String, _ title: String) throws -> NSMenuItem {
            let submenu = try require(menus.main.item(withTitle: menu)?.submenu, menu)
            return try require(submenu.item(withTitle: title), "\(menu) › \(title)")
        }
        @MainActor func check(_ menu: String, _ title: String, _ action: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                              runs command: CanvasCommand? = nil) throws {
            let found = try item(menu, title)
            expectEqual(found.action.map(NSStringFromSelector), action, "\(menu) › \(title)")
            expectEqual(found.keyEquivalent, key, "\(menu) › \(title)")
            if !key.isEmpty { expectEqual(found.keyEquivalentModifierMask, modifiers, "\(menu) › \(title)") }
            expectEqual(BoardMenus.command(of: found), command, "\(menu) › \(title)")
        }
        /// A plugin's command: the one action that runs whichever command its item carries.
        @MainActor func command(_ menu: String, _ title: String, _ command: CanvasCommand, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) throws {
            try check(menu, title, "runCommand:", key, modifiers, runs: command)
        }
        try check("File", "New", "newDocument:", "n")
        try check("File", "Open…", "openDocument:", "o")
        try check("File", "Close", "performClose:", "w")
        try check("File", "Save…", "saveDocument:", "s")
        try check("File", "Revert to Saved", "revertDocumentToSaved:")
        let recent = try require(item("File", "Open Recent").submenu)
        expectEqual(recent.items.map { $0.action.map(NSStringFromSelector) }, ["clearRecentDocuments:"])
        let file = try require(menus.main.item(withTitle: "File")?.submenu)
        expectEqual(file.items.map(\.title), ["New", "Open…", "Open Recent", "", "Close", "Save…", "Save As…", "Revert to Saved", "", "Kits"])
        // File ▸ Kits: the core's item for each kit, the example's Stickers, which turns it on or off.
        let kits = try require(file.item(withTitle: "Kits")?.submenu)
        expectEqual(kits.items.map(\.title), ["Stickers"])
        expectEqual(kits.items.map { $0.action.map(NSStringFromSelector) }, ["runCommand:"])
        expectEqual(kits.items.compactMap(BoardMenus.command(of:)), [.kit(StickersKit.id)])
        // AppKit's own items, which text answers first, carrying the command that answers each on the board.
        try check("Edit", "Undo", "undo:", "z", runs: .undo)
        try check("Edit", "Redo", "redo:", "z", [.command, .shift], runs: .redo)
        try check("Edit", "Cut", "cut:", "x", runs: .cut)
        try check("Edit", "Copy", "copy:", "c", runs: .copy)
        try check("Edit", "Paste", "paste:", "v", runs: .paste)
        try check("Edit", "Delete", "delete:", runs: .delete)
        try check("Edit", "Select All", "selectAll:", "a", runs: .selectAll)
        try check("Edit", "Copy as Image", "copyAsImage:", "c", [.command, .shift])
        try command("Edit", "Paste at Pointer", .pasteAtPointer, "v", [.command, .shift])
        try command("Edit", "Duplicate", .duplicate, "d")
        let edit = try require(menus.main.item(withTitle: "Edit")?.submenu)
        expectEqual(edit.items.map(\.title), ["Undo", "Redo", "", "Cut", "Copy", "Copy as Image", "Paste", "Paste at Pointer", "Duplicate", "Delete",
                                              "Select All", "Remove Mention", "", "Find", "Spelling and Grammar"], "the window's own items and Clipboard's and Find's, each at its order")
        // Insert: an item for each tool that places a shape, in the toolbar's order, Note with ⇧Return.
        try command("Insert", "Note", .insert(ToolID(placing: StickyNote.kind)), "\r", .shift)
        let insert = try require(menus.main.item(withTitle: "Insert")?.submenu)
        expectEqual(insert.items.map(\.title), ["Note", "Subboard", "Frame", "Reference", "Stickers", "", "Connect"], "and the example kit's tools in a submenu named for it, then Connect (⌘L) in a section of its own")
        expectEqual(try require(insert.item(withTitle: "Stickers")?.submenu).items.map(\.title), ["Thumbs Up", "Heart", "Star", "Party"])
        let find = try require(edit.item(withTitle: "Find")?.submenu)
        expectEqual(find.items.map(\.title), ["Find…", "Find Next", "Find Previous"])
        expectEqual(find.items.compactMap(BoardMenus.command(of:)), [.find, .findNext, .findPrevious], "never an AppKit find action, which a text view answers")
        expectEqual(find.items.map(\.keyEquivalent), ["f", "g", "g"])
        expectEqual(find.items.map(\.keyEquivalentModifierMask), [.command, .command, [.command, .shift]])
        let go = try require(menus.main.item(withTitle: "Go")?.submenu)
        expectEqual(go.items.filter { !$0.isHidden }.map(\.title), ["Back", "Forward", "Enclosing Board", "Open Selection", "Go to Mention", "Show What Mentions", "", "Next Issue", "Previous Issue", "Issue List", "Ignore Issue", "End Issue Walk", "", "Jump To…", "Board Path"],
                     "the issue walk's section follows Navigation's, Jump To follows it after a separator, and Board Path follows Jump To")
        try command("Go", "Next Issue", .nextIssue, "'")
        try command("Go", "Previous Issue", .previousIssue, "\"")
        try command("Go", "Issue List", .issueList, "'", [.command, .control])
        try command("Go", "Ignore Issue", .ignoreIssue, "'", [.command, .option])
        try command("Go", "End Issue Walk", .endIssueWalk, "")
        expectEqual(go.items.filter(\.isHidden).map { "\($0.title) \(KeyboardShortcutSection.key(of: $0) ?? "")" }, ["Back ⌃-", "Forward ⌃_"],
                    "VS Code's keys, each a hidden item after the one it's another key of")
        try command("Go", "Jump To…", .jumpTo, "k")
        try command("Go", "Back", .goBack, "[")
        try command("Go", "Forward", .goForward, "]")
        try command("Go", "Enclosing Board", .enclosingBoard, "\u{F700}")
        try command("Go", "Open Selection", .openSelection, "\u{F701}")
        try check("View", "Show Sidebar", "toggleSidebarShown:", "s", [.command, .control])
        try check("View", "Focus Sidebar", "focusSidebar:", "s", [.command, .option])
        try check("View", "Show Inspector", "toggleDetails:", "i", [.command, .control])
        try check("View", "Show Minimap", "toggleMinimap:", "m", [.command, .control])
        try command("View", "Next Inspector Tab", .nextInspectorTab, "]", [.command, .option])
        try command("View", "Previous Inspector Tab", .previousInspectorTab, "[", [.command, .option])
        try command("View", "Zoom In", .zoomIn, "=")
        try command("View", "Zoom Out", .zoomOut, "-")
        try command("View", "Actual Size", .zoomToActualSize, "0")
        try command("View", "Zoom to Fit", .zoomToFit, "1", .shift)
        try command("View", "Zoom to Selection", .zoomToSelection, "2", .shift)
        let view = try require(menus.main.item(withTitle: "View")?.submenu)
        expectEqual(view.items.map(\.title), ["Show Toolbar", "Show Sidebar", "Focus Sidebar", "Show Inspector", "Focus Inspector", "Next Inspector Tab", "Previous Inspector Tab", "Focus Next Pane", "Focus Previous Pane", "Show Minimap", "", "Zoom In", "Zoom Out", "Actual Size",
                                              "Zoom to Fit", "Zoom to Selection", "", "Enter Full Screen"])
        expectEqual(menus.main.items.map(\.title), ["Infinite Canvas", "File", "Edit", "Insert", "Shape", "Arrange", "View", "Go", "Window", "Help"])
        expect(try require(menus.main.item(withTitle: "Shape")?.submenu).items.isEmpty, "Shape fills itself as it opens")
        try command("Arrange", "Group", .group, "g", [.command, .option])
        try command("Arrange", "Ungroup", .ungroup, "g", [.command, .option, .shift])
        try command("Arrange", "Bring to Front", .bringToFront, "]", [])
        try command("Arrange", "Bring Forward", .bringForward, "]", .option)
        try command("Arrange", "Send Backward", .sendBackward, "[", .option)
        try command("Arrange", "Send to Back", .sendToBack, "[", [])
        let arrange = try require(menus.main.item(withTitle: "Arrange")?.submenu)
        expectEqual(arrange.items.map(\.title), ["Group", "Ungroup", "", "Bring to Front", "Bring Forward", "Send Backward", "Send to Back"], "after a separator")
        try check("Infinite Canvas", "Settings…", "showSettings:", ",")
        let app = try require(menus.main.item(withTitle: "Infinite Canvas")?.submenu)
        expectEqual(app.items.prefix(4).map(\.title), ["About Infinite Canvas", "", "Settings…", ""], "Settings… follows About")
        try check("Infinite Canvas", "Quit Infinite Canvas", "terminate:", "q")
        expectEqual(menus.windows.title, "Window")
        expectEqual(menus.windows.items.map(\.title), ["Minimize", "Zoom", "", "Bring All to Front"])
        expectEqual(menus.help.title, "Help")
        expectEqual(menus.help.items.map(\.title), ["Keyboard Shortcuts"])
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
