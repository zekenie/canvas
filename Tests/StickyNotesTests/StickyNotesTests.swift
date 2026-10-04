import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import StickyNotes
import TestKit
import Titles
import Topology

/// The note, every plugin it opts into, and Adornments, which lays out what Titles shows on it.
@MainActor var notePlugins: [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), StickyNotesPlugin(), AdornmentsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(), PortsPlugin()]
}

@MainActor let stickyNotesTests = Suite("Sticky notes", [
    test("registers its kind, the N tool and the double-click claim") {
        let registry = try Registry(plugins: notePlugins)
        expectEqual(registry.kinds, [StickyNote.kind])
        expectEqual(registry.shortcut(forTool: ToolID(placing: StickyNote.kind))?.chord, "n")
        expect(registry.definition(for: StickyNote.kind) is any Editable)
        expectEqual(registry.contributions(to: DoubleClickPlacement.self).map(\.value.kind), [StickyNote.kind])
    },
    test("can't be installed without the keyboard, selection, titles, ports and mentions plugins it opts into, the panel and the table of contents") {
        expectThrows(RegistryError.ownerNotInstalled(point: "KeyboardShortcuts", owner: .keyboard, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [StickyNotesPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "DoubleClickPlacement", owner: .selection, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), StickyNotesPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeTitles", owner: .titles, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), DetailPanelPlugin(), TableOfContentsPlugin()])
        }
        // A title names the note's row, so titles need the table of contents too.
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsTitles", owner: .tableOfContents, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), DetailPanelPlugin(), SlashCommandsPlugin(), TitlesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapePorts", owner: .ports, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), DetailPanelPlugin(),
                                       SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "MentionTexts", owner: .mentions, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), StickyNotesPlugin(), DetailPanelPlugin(),
                                       SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), PortsPlugin()])
        }
    },
    test("its row in the table of contents: its text on one line, or Empty Note") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        editor.transact {
            $0.insert(ShapeRecord(StickyNote(frame: frame, text: "Shopping\nlist")))
            $0.insert(ShapeRecord(StickyNote(frame: frame)))
        }
        let entries = try require(editor.tableOfContents).entries
        expectEqual(entries.map { $0.label?.text }, ["Shopping list", "Empty Note"])
        expectEqual(entries.map { $0.label?.badge }, [nil, nil])
        expectEqual(entries.map(\.symbol), ["note.text", "note.text"], "the Note tool's")
    },
    test("a note's panel is its header, where it's named, and no tab of its own") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Shopping"))
        editor.transact { $0.insert(note) }
        let layout = try require(editor.detailPanel).layout(for: try require(editor.document[note.id]))
        expectEqual(layout.header(as: TitleHeader.self)?.title, "", "an untitled note's header, where it's named")
        expectEqual(layout.tabs, [])
    },
    test("N then a click places a note centered there, editing, and back in select") {
        let h = try EditorHarness(plugins: notePlugins)
        h.key("n")
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let note = try require(h.editor.document.shapes.first)
        expectEqual(note.box, CGRect(x: 200, y: 200, width: 200, height: 200))
        expectEqual(h.editor.editingShapeID, note.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("typing into a new note's editor writes its text; Escape ends editing") {
        let h = try EditorHarness(plugins: notePlugins)
        h.press(at: CGPoint(x: 300, y: 300), clickCount: 2); h.release()
        let id = try require(h.editor.editingShapeID)
        let editing = try require(h.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        textView.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(h.editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Hello")
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.editingShapeID, nil)
    },
    test("a note grows with its text as it's typed, in the same step, and shrinks back, no shorter than a new one") {
        let h = try EditorHarness(plugins: notePlugins)
        let id = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        h.editor.replaceDocument(with: h.editor.document)
        h.editor.selection = id
        expect(h.key("\r"))
        let editing = try require(h.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        @MainActor func height() -> CGFloat? { h.editor.document[id]?.box?.height }
        textView.insertText("1\n2\n3\n4\n5\n6\n7\n8", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(height(), 200, "eight lines fit a new note")
        textView.insertText("\n9\n10\n11\n12", replacementRange: NSRange(location: textView.string.count, length: 0))
        // Twelve lines of 19 points, half a point spare, and 16 above and below.
        expectEqual(height(), 12 * 19 + 1 + 32)
        expectEqual(h.editor.document[id]?.box?.origin, .zero, "from its top")
        textView.insertText("\n", replacementRange: NSRange(location: textView.string.count, length: 0))
        expectEqual(height(), 13 * 19 + 1 + 32, "a last Return: room for the caret's line")
        // The editor over it grows with it, as the canvas lays it out.
        editing.view.frame = CGRect(x: 0, y: 0, width: 200, height: 13 * 19 + 33)
        editing.view.bounds = CGRect(x: 0, y: 0, width: 200, height: 13 * 19 + 33)
        expectEqual(textView.frame.height, 13 * 19 + 33)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.undoHistory.undoName, "Typing", "growing is part of the typing's step")
        h.editor.undo()
        expectEqual(height(), 200)
        expectEqual(h.editor.document[id]?.typed(as: StickyNote.self)?.props.text, "")
        h.editor.redo()
        expectEqual(height(), 13 * 19 + 33)
        expect(h.key("\r"))
        let again = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        again.selectAll(nil)
        again.insertText("Short", replacementRange: again.selectedRange())
        expectEqual(height(), 200, "back to a new note's")
    },
    test("a note made or given text from properties (the command line's draw) is as tall as its text; a board read keeps what it saved") {
        let registry = try Registry(plugins: notePlugins)
        let long = (1...12).map(String.init).joined(separator: "\n")
        let made = try registry.shape(StickyNote.kind, properties: ["frame": [[40, 60], [200, 200]], "text": .string(long)])
        expectEqual(made.box, CGRect(x: 40, y: 60, width: 200, height: 12 * 19 + 33))
        let short = try registry.shape(made, setting: ["text": "Hi"])
        expectEqual(short.box?.height, 200)
        let wide = try registry.shape(StickyNote.kind, properties: ["frame": [[0, 0], [400, 200]], "text": .string(String(repeating: "word ", count: 60))])
        let narrow = try registry.shape(StickyNote.kind, properties: ["frame": [[0, 0], [200, 200]], "text": .string(String(repeating: "word ", count: 60))])
        expect(try require(narrow.box?.height) > require(wide.box?.height), "wrapped at its width")
        let codec = BoardCodec(registry: registry)
        var tall = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: long)))
        tall.props.frame.size.height = 200
        let read = try codec.decode(codec.encode(CanvasDocument(shapes: [AnyShapeRecord(tall)]))).document
        expectEqual(read.shapes.first?.box?.height, 200, "read as saved: nothing a person did")
    },
    test("a note too short for its text (saved before notes grew, or drawn with a size) grows to it as editing begins, as part of the editing's step; never shrinks") {
        let h = try EditorHarness(plugins: notePlugins)
        let long = (1...12).map(String.init).joined(separator: "\n")
        let id = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: long)))
        let tall = h.add(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 400), text: MentionText(plain: "Hi")))
        h.editor.replaceDocument(with: h.editor.document)
        @MainActor func height(_ id: ShapeID) -> CGFloat? { h.editor.document[id]?.box?.height }
        expectEqual(height(id), 200, "cut off")
        h.editor.selection = id
        expect(h.key("\r"))
        let editing = try require(h.editor.makeEditingView())
        expectEqual(height(id), 12 * 19 + 33, "all of it, before anything's typed")
        let textView = try require(editing.firstResponder as? NSTextView)
        expectEqual(textView.frame.height, 12 * 19 + 33)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        h.editor.undo()
        expectEqual(height(id), 200)
        h.editor.selection = tall
        expect(h.key("\r"))
        _ = try require(h.editor.makeEditingView())
        expectEqual(height(tall), 400, "a note drawn taller keeps its height until it's typed into")
        h.editor.endEditing()
        expect(!h.editor.canUndo, "a note that fits wrote nothing")
    },
    test("a note fitted to its text draws its last line") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let long = (1...12).map { "Line \($0)" }.joined(separator: "\n")
        let fitted = try editor.registry.shape(StickyNote.kind, properties: ["frame": [[0, 0], [200, 200]], "text": .string(long)])
        editor.transact { $0.insert(fitted) }
        let rep = renderBitmap(editor, size: CGSize(width: 220, height: 300))
        // The twelfth line: 16 + 11 × 19 down, 19 tall; its text is dark on the note's yellow.
        let band = CGRect(x: 16, y: 16 + 11 * 19, width: 60, height: 19)
        var ink = 0
        for y in stride(from: band.minY, to: band.maxY, by: 1) {
            for x in stride(from: band.minX, to: band.maxX, by: 1) where pixel(rep, at: CGPoint(x: x, y: y))[0] < 120 { ink += 1 }
        }
        expect(ink > 20, "the last line's text: \(ink) dark pixels")
    },
    test("⌘↩ ends editing a note, keeping what's typed, as it's done in the panel's boxes; Return is a new line") {
        let h = try EditorHarness(plugins: notePlugins)
        h.press(at: CGPoint(x: 300, y: 300), clickCount: 2); h.release()
        let id = try require(h.editor.editingShapeID)
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        @MainActor func key(_ modifiers: NSEvent.ModifierFlags) {
            textView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0, context: nil,
                                                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        }
        textView.insertText("Milk", replacementRange: NSRange(location: 0, length: 0))
        key([])
        expectEqual(h.editor.editingShapeID, id, "Return is the text's")
        textView.insertText("Bread", replacementRange: NSRange(location: textView.string.count, length: 0))
        key(.command)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Milk\nBread")
        expectEqual(h.editor.undoHistory.undoName, "Add Note", "one step, placing and typing")
    },
    test("typing into a note's editor is one undo step; placing the note and typing into it are one too") {
        let h = try EditorHarness(plugins: notePlugins)
        let id = h.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        h.editor.replaceDocument(with: h.editor.document)
        h.editor.selection = id
        expect(h.key("\r"))
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        for word in ["Hello", ",", " world"] { textView.insertText(word, replacementRange: NSRange(location: textView.string.count, length: 0)) }
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Hello, world")
        expectEqual(h.editor.undoHistory.undoName, "Typing")
        h.editor.undo()
        expectEqual(h.editor.document[id]?.typed(as: StickyNote.self)?.props.text, "")
        expect(!h.editor.canUndo)

        h.key("n")
        h.press(at: CGPoint(x: 600, y: 300)); h.release()
        let note = try require(h.editor.editingShapeID)
        let placed = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        placed.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Add Note")
        h.editor.undo()
        expectEqual(h.editor.document[note], nil, "one undo takes the note and its text")
    },
    test("a note has no title until it's named; then a pill above its top-left corner shows it, and its row is called by it") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 40, y: 60, width: 200, height: 200), text: "Buy milk"))
        editor.transact { $0.insert(note) }
        expectEqual(editor.registry.title(of: try require(editor.document[note.id])), nil)
        expectEqual(try require(editor.tableOfContents).entries.map { $0.label?.text }, ["Buy milk"])
        let untitled = renderBitmap(editor, size: CGSize(width: 300, height: 300))

        editor.transact { $0.update(note.id) { $0[TitleProperty.self] = "Groceries" } }
        expectEqual(editor.registry.title(of: try require(editor.document[note.id])), "Groceries")
        let row = try require(editor.tableOfContents?.entries.first?.label)
        expectEqual(row.text, "Groceries")
        expectEqual(row.systemImage, nil, "still the Note tool's symbol")
        let titled = renderBitmap(editor, size: CGSize(width: 300, height: 300))
        expect(changedPixels(untitled, titled, in: CGRect(x: 40, y: 35, width: 60, height: 12)) > 300, "the pill, above the note")
        expectEqual(changedPixels(untitled, titled, in: CGRect(x: 40, y: 60, width: 200, height: 200)), 0, "nothing in the note")
    },
])
