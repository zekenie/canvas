import AppKit
import Arrows
import Canvas
import CanvasTesting
import CanvasUI
import Checklists
import Clipboard
import Composition
import CoreGraphics
import Selection
import StickyNotes
import TableOfContents
import TestKit

/// The welcome board, its clipboard on a pasteboard of the test's own.
@MainActor func welcomeBoard(_ pasteboard: NSPasteboard) -> EditorHarness {
    EditorHarness { ShippedPlugins.makeEditor(scheduler: $0, pasteboard: pasteboard) }
}

@MainActor let copyPasteTests = Suite("Copy and paste, as shipped", [
    test("two notes and the arrow between them paste as two notes and an arrow between the copies, listed under the first") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = welcomeBoard(pasteboard)
        let notes = h.editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
        let arrow = try require(h.editor.document.shapes.first { $0.typed(as: Arrow.self)?.props.end.binding?.shapeID == notes[1] }?.id)
        h.editor.selectedShapeIDs = [notes[0], notes[1], arrow]
        h.hold(.command)
        expect(h.key("c"))
        let before = h.editor.document
        expect(h.key("v"))
        h.hold([])
        let copies = h.editor.shapes(since: before)
        let byOriginal = Dictionary(uniqueKeysWithValues: copies.map { ($0.copiedFrom!, $0.id) })
        expectEqual(Set(byOriginal.keys), [notes[0], notes[1], arrow])
        let pasted = try require(h.editor.document[byOriginal[arrow]!]?.typed(as: Arrow.self)?.props)
        let original = try require(h.editor.document[arrow]?.typed(as: Arrow.self)?.props)
        expectEqual(pasted.start.binding?.shapeID, byOriginal[notes[0]])
        expectEqual(pasted.end.binding?.shapeID, byOriginal[notes[1]])
        expectEqual(pasted.start.binding?.normalizedAnchor, original.start.binding?.normalizedAnchor)
        expectEqual(h.editor.arrowGeometry(of: byOriginal[arrow]!)?.bodyPath.boundingBoxOfPath,
                    h.editor.arrowGeometry(of: arrow)?.bodyPath.boundingBoxOfPath, "pasted in place, over the original")
        // Selected, so the table of contents lists just the copies: the arrow under the note it starts from.
        let entries = try require(h.editor.tableOfContents).entries
        expectEqual(entries.map(\.id), [byOriginal[notes[0]]!, byOriginal[notes[1]]!])
        expectEqual(entries.first?.children?.map(\.id), [byOriginal[arrow]!])
    },
    test("an arrow copied alone pastes free, ending where it was drawn: as the original does once its notes are deleted") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = welcomeBoard(pasteboard)
        let bent = try require(h.editor.document.shapes.first { ($0.typed(as: Arrow.self)?.props.bend ?? 0) != 0 })
        let arrow = try require(bent.typed(as: Arrow.self)?.props)
        h.editor.selection = bent.id
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste()
        let copy = try require(h.editor.shapes(since: before).first?.typed(as: Arrow.self)?.props)
        expectEqual(copy.start.binding, nil)
        expectEqual(copy.end.binding, nil)
        h.editor.transact { $0.delete([arrow.start.binding!.shapeID, arrow.end.binding!.shapeID]) }
        expectEqual(copy, h.editor.document[bent.id]?.typed(as: Arrow.self)?.props)
    },
    test("where a shape was copied from is saved with the board, and read back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = welcomeBoard(pasteboard)
        let note = try require(h.editor.document.shapes.first?.id)
        h.editor.transact { $0.update(note) { $0[ChecklistProperty.self] = [ChecklistItem(text: "Oat milk")] } }
        h.editor.selection = note
        h.editor.copySelection()
        h.editor.paste()
        let copy = try require(h.editor.selection)
        expectEqual(h.editor.document[copy]?[ChecklistProperty.self]?.map(\.text), ["Oat milk"], "a pasted note keeps its checklist")
        let codec = BoardCodec(registry: h.editor.registry)
        let data = try codec.encode(h.editor.document)
        let json = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        expectEqual(json["format"] as? Int, 3, "a board with added values (the notes' checklists) and metadata, which an app from before either would drop")
        let shapes = try require(json["shapes"] as? [[String: Any]])
        let meta = try require(shapes.last?["meta"] as? [String: [String: Any]])
        expectEqual((meta["clipboard"]?["copiedFrom"] as? [String: Any])?["shape"] as? String, note.description)
        let read = try codec.decode(data)
        expectEqual(read.report, LoadReport())
        expectEqual(read.document[copy]?.copiedFrom, note)
        expectEqual(read.document, h.editor.document)
    },
    test("Edit › Cut, Copy and Paste reach the board's editor from its window, dimmed when they can't run") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        defer { try? configureBoards() }
        let board = BoardDocument()
        board.makeWindowControllers()
        defer { board.close() }
        let controller = try require(board.windowControllers.first as? BoardWindowController)
        let cut = NSMenuItem(title: "Cut", action: #selector(BoardWindowController.cut(_:)), keyEquivalent: "x")
        let copy = NSMenuItem(title: "Copy", action: #selector(BoardWindowController.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(BoardWindowController.paste(_:)), keyEquivalent: "v")
        expectEqual([cut, copy, paste].map(controller.validateMenuItem), [false, false, false])
        let note = board.editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Copy me"))
        board.editor.selection = note
        expectEqual([cut, copy, paste].map(controller.validateMenuItem), [true, true, false])
        controller.copy(nil)
        expect(controller.validateMenuItem(paste))
        controller.paste(nil)
        let pasted = try require(board.editor.selection)
        expectEqual(board.editor.document[pasted]?.copiedFrom, note)
        controller.cut(nil)
        expectEqual(board.editor.document.shapes.map(\.id), [note])
    },
    test("with the table of contents' list focused, Edit › Cut, Copy and Paste go through the responder chain to the board's editor") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        defer { try? configureBoards() }
        let board = BoardDocument()
        board.start(with: WelcomeBoard.document())
        board.makeWindowControllers()
        defer { board.close() }
        let window = try require(board.windowControllers.first?.window)
        window.settle()
        let notes = board.editor.document.shapes.filter { $0.kind == StickyNote.kind }.map(\.id)
        board.editor.selectedShapeIDs = [notes[0], notes[1]]          // the panel lists just these
        // The list is made again for the new selection: find the one in the window, once it's there.
        @MainActor func contents() -> NSTableView? {
            window.contentView?.descendants(NSTableView.self).first { $0.isTableOfContents && $0.window === window && $0.numberOfRows == 3 }
        }
        window.spin { contents() != nil }
        let list = try require(contents())
        expect(window.makeFirstResponder(list))
        expect(window.firstResponder === list)
        // Edit › Copy goes to the first responder's chain: through the panel's views to the window and its controller.
        expect(list.tryToPerform(#selector(BoardWindowController.copy(_:)), with: nil), "something in the chain answers copy:")
        expect(board.editor.canPaste, "and it was the board's: the notes are on the pasteboard")
        let before = board.editor.document
        expect(list.tryToPerform(#selector(BoardWindowController.paste(_:)), with: nil))
        expectEqual(Set(board.editor.shapes(since: before).compactMap(\.copiedFrom)), Set(notes.prefix(2)))
        expect(list.tryToPerform(#selector(BoardWindowController.cut(_:)), with: nil))
        expectEqual(board.editor.document.shapes.filter { before[$0.id] == nil }, [], "the pasted copies, selected, are cut")
    },
    test("the menus send cut:, copy: and paste: with ⌘X, ⌘C and ⌘V") {
        let edit = try require(BoardMenus.make(appName: "Infinite Canvas").main.item(withTitle: "Edit")?.submenu)
        let items = ["Cut", "Copy", "Paste"].compactMap { edit.item(withTitle: $0) }
        expectEqual(items.map { $0.action.map(NSStringFromSelector) }, ["cut:", "copy:", "paste:"])
        expectEqual(items.map(\.keyEquivalent), ["x", "c", "v"])
    },
])

extension CanvasEditor {
    /// The shapes added since `before`, back to front.
    func shapes(since before: CanvasDocument) -> [AnyShapeRecord] {
        document.shapes.filter { before[$0.id] == nil }
    }
}
