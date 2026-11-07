import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import LanguageModels
import Locking
import Selection
import ShippedTesting
import SlashCommands
import Stickers
import StickyNotes
import TestKit
import Validation

// Kits as shipped (Kits.swift): the example kit, Stickers, off in a new file, every way in it gives gone (its
// tools, its Insert items in their submenu, `/sticker`, Change Sticker ▸, its paste reader); File ▸ Kits ▸ Stickers
// turning it on in one step, checked while it's on, and every way in back; and a sticker drawn while it was on
// staying drawn, changed and checked with it off; a real board saved, opened and reverted with it on.

@MainActor let kitsShippedTests = Suite("Kits, as shipped", [
    test("Stickers is off in a new file, its ways in gone; turned on in one step they're back; turned off, gone again, its sticker drawn, changed and checked") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let editor = h.editor, registry = editor.registry
        editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let tools = registry.tools.filter { registry.kit(ofTool: $0.id) == StickersKit.id }.map(\.id)
        expectEqual(tools.count, 4)
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: registry, editor: { editor })
        let insert = try require(menus.main.item(withTitle: "Insert")?.submenu)
        @MainActor func sticker(_ x: CGFloat) -> ShapeID { editor.add(Sticker(frame: CGRect(x: x, y: 500, width: 96, height: 96), emoji: "🎉")) }
        @MainActor func listed(_ id: ShapeID) -> [String] { editor.slashCommands?.commands(for: .selection([id])).map { $0.name } ?? [] }
        @MainActor func menu(at id: ShapeID) -> [String] {
            guard let box = editor.document[id]?.box else { return [] }
            return h.secondaryClick(at: CGPoint(x: box.midX, y: box.midY))?.outline ?? []
        }

        // Off in a new file.
        expect(!editor.isOn(StickersKit.self))
        expect(tools.allSatisfy { !editor.isToolEnabled($0) && !editor.claims(.insert($0)) })
        BoardMenus.showCommands(of: editor, in: menus.main, registry: registry)
        expectEqual(insert.items.filter { !$0.isHidden }.map(\.title), ["Note", "Subboard", "Frame", "Reference"], "no Insert ▸ Stickers")
        let first = sticker(100)
        expect(!listed(first).contains("sticker"))
        expect(!menu(at: first).contains("Change Sticker ▸"))
        pasteboard.clearContents()
        pasteboard.setString("🎉", forType: .string)
        expect(!editor.canPaste)

        // On, in one step: File ▸ Kits ▸ Stickers.
        expect(editor.perform(.kit(StickersKit.id)))
        expectEqual(editor.undoHistory.undoName, "Turn On Stickers")
        expect(tools.allSatisfy { editor.isToolEnabled($0) && editor.claims(.insert($0)) })
        BoardMenus.showCommands(of: editor, in: menus.main, registry: registry)
        expectEqual(insert.items.filter { !$0.isHidden }.map(\.title), ["Note", "Subboard", "Frame", "Reference", "Stickers"])
        expect(listed(first).contains("sticker"))
        expect(menu(at: first).contains("Change Sticker ▸"))
        expect(editor.canPaste)
        editor.paste()
        expectEqual(editor.document.shapes.filter { $0.kind == Sticker.kind }.count, 2, "the emoji pasted as a sticker")

        // Off again, in one step: what was drawn stays drawn, changed as any shape and checked.
        expect(editor.perform(.kit(StickersKit.id)))
        expectEqual(editor.undoHistory.undoName, "Turn Off Stickers")
        expect(!listed(first).contains("sticker") && !editor.canPaste)
        expectEqual(editor.document.shapes.filter { $0.kind == Sticker.kind }.count, 2, "both stickers still there")
        editor.selectedShapeIDs = [first]
        expect(editor.perform(.lock), "locked as any shape")
        expect(editor.isReadOnly(first))
        editor.undo()
        editor.transact("Empty") { $0.update(first, as: Sticker.self) { $0.props.emoji = "" } }
        expect(!(editor.validation?.result(for: first)?.issues ?? []).isEmpty, "checked against its schema: an empty sticker warns")
        editor.undo()
        editor.undo()
        expect(editor.isOn(StickersKit.self), "Turn Off Stickers undone")
    },
    test("a board saved with Stickers on opens with it on, a revert puts back the kits it was saved with, and with every kit off it saves as it did before") {
        try configureBoards()
        let url = scratchURL("kits.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
        let plain = try board.data(ofType: boardType)
        let tool = try require(board.editor.registry.tools.first { board.editor.registry.kit(ofTool: $0.id) == StickersKit.id }?.id)
        board.editor.turn(StickersKit.self, on: true)
        expect(board.isDocumentEdited, "turning a kit on edits the board")
        let data = try board.data(ofType: boardType)
        expect(String(decoding: data, as: UTF8.self).contains(#""kits" : {"#), "the file keeps the kits on")
        let reopened = BoardDocument()
        defer { reopened.close() }
        try reopened.read(from: data, ofType: boardType)
        expect(reopened.editor.isOn(StickersKit.self))
        expect(reopened.editor.isToolEnabled(tool))
        expect(reopened.loadReport.isEmpty)
        settleRunLoop()
        expect(!reopened.isDocumentEdited)

        // Saved with it on, turned off and reverted: on again, its tool back, unedited.
        try data.write(to: url)
        board.fileURL = url
        board.editor.turn(StickersKit.self, on: false)
        expect(!board.editor.isToolEnabled(tool))
        try board.revert(toContentsOf: url, ofType: boardType)
        expect(board.editor.isOn(StickersKit.self))
        expect(board.editor.isToolEnabled(tool))
        settleRunLoop()
        expect(!board.isDocumentEdited)

        // Turned off, the board saves as it did with no kit on; undone, it reads unedited.
        reopened.editor.turn(StickersKit.self, on: false)
        expectEqual(try reopened.data(ofType: boardType), plain)
        reopened.editor.undo()
        expect(!reopened.isDocumentEdited, "undone to what was read, it reads unedited")
    },
    test("File ▸ Kits ▸ Stickers is checked while the kit is on in the window's file, and runs from the window") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let controller = try require(w.board.windowControllers.first as? BoardWindowController)
        let item = commandItem(.kit(StickersKit.id), title: "Stickers")
        expect(controller.validateMenuItem(item))
        expectEqual(item.state, .off)
        controller.runCommand(item)
        expect(w.editor.isOn(StickersKit.self))
        expect(controller.validateMenuItem(item))
        expectEqual(item.state, .on)
    },
])
