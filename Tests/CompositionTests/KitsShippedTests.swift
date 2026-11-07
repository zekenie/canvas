import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Engineering
import LanguageModels
import Locking
import Selection
import ShippedTesting
import SlashCommands
import TestKit
import Titles
import Validation

// Kits as shipped (Kits.swift): the engineering kit, off in a new file, every way in it gives gone (its tools, their
// Insert items in Insert ▸ Engineering, `/table` and `/database`, Create Database in a table's menu); File ▸ Kits ▸
// Engineering turning it on in one step, checked while it's on, and every way in back; a table drawn while it was on
// staying drawn, changed and checked with it off; a real board saved, opened and reverted with it on.

@MainActor let kitsShippedTests = Suite("Kits, as shipped", [
    test("Engineering is off in a new file, its ways in gone; turned on in one step they're back; turned off, gone again, its table drawn, changed and checked") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        let editor = h.editor, registry = editor.registry
        editor.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let tools = registry.tools.filter { registry.kit(ofTool: $0.id) == EngineeringKit.id }.map(\.id)
        expectEqual(tools, [ToolID(placing: DatabaseTable.kind), ToolID(placing: DatabaseEnum.kind), ToolID(placing: Database.kind)])
        let menus = BoardMenus.make(appName: "Infinite Canvas", registry: registry, editor: { editor })
        let insert = try require(menus.main.item(withTitle: "Insert")?.submenu)
        @MainActor func table(_ x: CGFloat) -> ShapeID {
            editor.add(DatabaseTable(frame: CGRect(x: x, y: 300, width: 260, height: 44), columns: DatabaseTable.starter().columns))
        }
        @MainActor func listed(_ ids: [ShapeID]) -> [String] { editor.slashCommands?.commands(for: .selection(ids)).map { $0.name } ?? [] }
        @MainActor func menu(at id: ShapeID) -> [String] {
            guard let box = editor.shapeContext.geometry(of: id)?.bounds else { return [] }
            return h.secondaryClick(at: CGPoint(x: box.midX, y: box.midY))?.outline ?? []
        }

        // Off in a new file.
        expect(!editor.isOn(EngineeringKit.self))
        expect(tools.allSatisfy { !editor.isToolEnabled($0) && !editor.claims(.insert($0)) })
        BoardMenus.showCommands(of: editor, in: menus.main, registry: registry)
        expectEqual(insert.items.filter { !$0.isHidden }.map(\.title), ["New Shape Beside", "Note", "Subboard", "Frame", "Reference", "", "Connect"],
                    "no Insert ▸ Engineering")
        let first = table(100)
        expect(!listed([first]).contains("table") && !listed([first]).contains("database"))
        expect(!menu(at: first).contains("Create Database"))
        expect(!editor.claims(.createDatabase))

        // On, in one step: File ▸ Kits ▸ Engineering.
        expect(editor.perform(.kit(EngineeringKit.id)))
        expectEqual(editor.undoHistory.undoName, "Turn On Engineering")
        expect(tools.allSatisfy { editor.isToolEnabled($0) && editor.claims(.insert($0)) })
        BoardMenus.showCommands(of: editor, in: menus.main, registry: registry)
        expectEqual(insert.items.filter { !$0.isHidden }.map(\.title), ["New Shape Beside", "Note", "Subboard", "Frame", "Reference", "Engineering", "", "Connect"])
        expectEqual(try require(insert.item(withTitle: "Engineering")?.submenu).items.map(\.title), ["Table", "Enum", "Database"])
        expect(listed([first]).contains("table") && listed([first]).contains("database"))
        expect(menu(at: first).contains("Create Database"))

        // Off again, in one step: what was drawn stays drawn, changed as any shape and checked.
        expect(editor.perform(.kit(EngineeringKit.id)))
        expectEqual(editor.undoHistory.undoName, "Turn Off Engineering")
        expect(!listed([first]).contains("table") && !menu(at: first).contains("Create Database"))
        expectEqual(editor.document.shapes.filter { $0.kind == DatabaseTable.kind }.count, 1, "the table still there")
        editor.selectedShapeIDs = [first]
        expect(editor.perform(.lock), "locked as any shape")
        expect(editor.isReadOnly(first))
        editor.undo()
        editor.transact("Rename") { $0.update(first) { $0[TitleProperty.self] = String(repeating: "orders", count: 20) } }
        expect(!(editor.validation?.result(for: first)?.issues ?? []).isEmpty, "checked against its schema: a title too long warns")
        editor.undo()
        editor.undo()
        expect(editor.isOn(EngineeringKit.self), "Turn Off Engineering undone")
    },
    test("a board saved with Engineering on opens with it on, a revert puts back the kits it was saved with, and with every kit off it saves as it did before") {
        try configureBoards()
        let url = scratchURL("kits.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
        let plain = try board.data(ofType: boardType)
        let tool = try require(board.editor.registry.tools.first { board.editor.registry.kit(ofTool: $0.id) == EngineeringKit.id }?.id)
        board.editor.turn(EngineeringKit.self, on: true)
        expect(board.isDocumentEdited, "turning a kit on edits the board")
        let data = try board.data(ofType: boardType)
        expect(String(decoding: data, as: UTF8.self).contains(#""kits" : {"#), "the file keeps the kits on")
        let reopened = BoardDocument()
        defer { reopened.close() }
        try reopened.read(from: data, ofType: boardType)
        expect(reopened.editor.isOn(EngineeringKit.self))
        expect(reopened.editor.isToolEnabled(tool))
        expect(reopened.loadReport.isEmpty)
        settleRunLoop()
        expect(!reopened.isDocumentEdited)

        // Saved with it on, turned off and reverted: on again, its tool back, unedited.
        try data.write(to: url)
        board.fileURL = url
        board.editor.turn(EngineeringKit.self, on: false)
        expect(!board.editor.isToolEnabled(tool))
        try board.revert(toContentsOf: url, ofType: boardType)
        expect(board.editor.isOn(EngineeringKit.self))
        expect(board.editor.isToolEnabled(tool))
        settleRunLoop()
        expect(!board.isDocumentEdited)

        // Turned off, the board saves as it did with no kit on; undone, it reads unedited.
        reopened.editor.turn(EngineeringKit.self, on: false)
        expectEqual(try reopened.data(ofType: boardType), plain)
        reopened.editor.undo()
        expect(!reopened.isDocumentEdited, "undone to what was read, it reads unedited")
    },
    test("File ▸ Kits ▸ Engineering is checked while the kit is on in the window's file, and runs from the window") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        let controller = try require(w.board.windowControllers.first as? BoardWindowController)
        let item = commandItem(.kit(EngineeringKit.id), title: "Engineering")
        expect(controller.validateMenuItem(item))
        expectEqual(item.state, .off)
        controller.runCommand(item)
        expect(w.editor.isOn(EngineeringKit.self))
        expect(controller.validateMenuItem(item))
        expectEqual(item.state, .on)
    },
])
