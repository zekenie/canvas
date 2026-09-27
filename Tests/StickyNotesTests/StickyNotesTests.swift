import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Checklists
import ContextMenus
import DetailPanel
import Keyboard
import Ports
import Selection
import TableOfContents
import StickyNotes
import TestKit
import Titles
import Validation

/// The note and every plugin it opts into.
@MainActor var notePlugins: [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
     TableOfContentsPlugin(), TitlesPlugin(), PortsPlugin()]
}

extension ShapeRecord where Props == StickyNote {
    /// The note with `items` in its checklist, the property Checklists adds.
    func withChecklist(_ items: [ChecklistItem]) -> Self {
        var note = self
        note[ChecklistProperty.self] = items
        return note
    }
}

@MainActor let stickyNotesTests = Suite("Sticky notes", [
    test("registers its kind, the N tool and the double-click claim") {
        let registry = try Registry(plugins: notePlugins)
        expectEqual(registry.kinds, [StickyNote.kind])
        expectEqual(registry.shortcut(forTool: ToolID(placing: StickyNote.kind))?.chord, "n")
        expect(registry.definition(for: StickyNote.kind) is any Editable)
        expectEqual(registry.contributions(to: DoubleClickPlacement.self).map(\.value.kind), [StickyNote.kind])
    },
    test("can't be installed without the keyboard, selection, validation, checklists, titles and ports plugins it opts into, the panel, context menus and the table of contents") {
        expectThrows(RegistryError.ownerNotInstalled(point: "KeyboardShortcuts", owner: .keyboard, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "DoubleClickPlacement", owner: .selection, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ValidationRules", owner: .validation, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeChecklists", owner: .checklists, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeContextMenus", owner: .contextMenus, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeTitles", owner: .titles, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin(),
                                       ContextMenusPlugin(), TableOfContentsPlugin()])
        }
        // A title names the note's row, so titles need the table of contents too.
        expectThrows(RegistryError.ownerNotInstalled(point: "ContentsTitles", owner: .tableOfContents, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin(),
                                       ContextMenusPlugin(), TitlesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapePorts", owner: .ports, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin(),
                                       ContextMenusPlugin(), TableOfContentsPlugin(), TitlesPlugin()])
        }
    },
    test("its row in the table of contents: its text on one line, or Empty Note, and its checklist's tally") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        editor.transact {
            $0.insert(ShapeRecord(StickyNote(frame: frame, text: "Shopping\nlist")).withChecklist([ChecklistItem(text: "milk", isDone: true),
                                                                                                  ChecklistItem(text: "eggs")]))
            $0.insert(ShapeRecord(StickyNote(frame: frame)))
        }
        let entries = try require(editor.tableOfContents).entries
        expectEqual(entries.map { $0.label?.text }, ["Shopping list", "Empty Note"])
        expectEqual(entries.map { $0.label?.badge }, ["1/2", nil])
        expectEqual(entries.map(\.symbol), ["note.text", "note.text"], "the Note tool's")
    },
    test("a note has a checklist: the registry reads it, and the panel shows it in a Checklist tab") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let items = [ChecklistItem(text: "milk", isDone: true), ChecklistItem(text: "eggs")]
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Shopping")).withChecklist(items)
        let blank = ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200)))
        editor.transact { $0.insert(note); $0.insert(blank) }
        let record = try require(editor.document[note.id])
        expectEqual(editor.registry.checklist(of: record), items)
        let layout = try require(editor.detailPanel).layout(for: record)
        expectEqual(layout.header(as: TitleHeader.self)?.title, "", "an untitled note's header, where it's named")
        expectEqual(layout.tabs, [.of(ChecklistTab.self), .of(ArrangeTab.self)])
        expectEqual(layout.sections(in: .of(ChecklistTab.self)).map(\.section), ["Items", "Progress"])
        expectEqual(editor.document[blank.id]?[ChecklistProperty.self], [], "a new note's checklist is empty")
    },
    test("a note with no text but a checklist isn't empty; one with neither warns") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let listed = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: " ")).withChecklist([ChecklistItem(text: "milk")])
        let empty = ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200), text: " "))
        editor.transact { $0.insert(listed); $0.insert(empty) }
        expect(editor.validation?.result(for: listed.id) == nil)
        expectEqual(editor.validation?.result(for: empty.id)?.worst, .warning)
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
    test("an empty note warns; typing into its editor clears the warning; Escape ends editing") {
        let h = try EditorHarness(plugins: notePlugins)
        h.press(at: CGPoint(x: 300, y: 300), clickCount: 2); h.release()
        let id = try require(h.editor.editingShapeID)
        expectEqual(h.editor.validation?.result(for: id)?.worst, .warning)
        expectEqual(h.editor.validation?.result(for: id)?.isValid, true)
        let editing = try require(h.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        textView.insertText("Hello", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(h.editor.document[id]?.typed(as: StickyNote.self)?.props.text, "Hello")
        expect(h.editor.validation?.result(for: id) == nil)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.editingShapeID, nil)
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
    test("a note with only a title isn't empty") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        var named = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        named[TitleProperty.self] = "Ideas"
        var blank = ShapeRecord(StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200)))
        blank[TitleProperty.self] = "  "
        editor.transact { $0.insert(named); $0.insert(blank) }
        expect(editor.validation?.result(for: named.id) == nil)
        expectEqual(editor.validation?.result(for: blank.id)?.issues, [.warning("This note is empty.")])
    },
    test("a title longer than 80 characters is a warning on the title, from its schema; one of 80 isn't") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        var note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Buy milk"))
        note[TitleProperty.self] = String(repeating: "a", count: 80)
        editor.transact { $0.insert(note) }
        expect(editor.validation?.result(for: note.id) == nil)
        editor.transact { $0.update(note.id) { $0[TitleProperty.self] = String(repeating: "a", count: 81) } }
        expectEqual(editor.validation?.result(for: note.id)?.issues,
                    [.warning("Title is 81 characters long, and should be at most 80.", field: "title")])
        expectEqual(editor.validation?.result(for: note.id)?.isValid, true, "a warning, not an error")
    },
])
