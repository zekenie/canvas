import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Checklists
import DetailPanel
import StickyNotes
import TestKit
import Validation

/// The note and every plugin it opts into.
@MainActor var notePlugins: [any CanvasPlugin] { [StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin(), DetailPanelPlugin()] }

@MainActor let stickyNotesTests = Suite("Sticky notes", [
    test("registers its kind, the N tool and the double-click claim") {
        let registry = try Registry(plugins: notePlugins)
        expectEqual(registry.kinds, [StickyNote.kind])
        expectEqual(registry.tool(forShortcut: "n"), ToolID(placing: StickyNote.kind))
        expect(registry.definition(for: StickyNote.kind) is any Editable)
    },
    test("can't be installed without the validation and checklists plugins it opts into, and the panel") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ValidationRules", owner: .validation, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [StickyNotesPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeChecklists", owner: .checklists, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [StickyNotesPlugin(), ValidationPlugin(), DetailPanelPlugin()])
        }
        expectThrows(RegistryError.ownerNotInstalled(point: "ShapeDetails", owner: .detailPanel, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [StickyNotesPlugin(), ValidationPlugin(), ChecklistsPlugin()])
        }
    },
    test("a note has a checklist: the registry reads it, and the panel shows it in a Checklist tab") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let items = [ChecklistItem(text: "milk", isDone: true), ChecklistItem(text: "eggs")]
        let note = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Shopping", checklist: items))
        editor.transact { $0.insert(note) }
        let record = try require(editor.document[note.id])
        expectEqual(editor.registry.checklist(of: record), items)
        let layout = try require(editor.detailPanel).layout(for: record)
        expectEqual(layout.header, DetailHeader("Note", systemImage: "note.text"))
        expectEqual(layout.tabs, [.of(ChecklistTab.self), .of(ArrangeTab.self)])
        expectEqual(layout.sections(in: .of(ChecklistTab.self)).map(\.section), ["Items", "Progress"])
        expectEqual(StickyNote().checklist, [], "a new note's checklist is empty")
    },
    test("a note with no text but a checklist isn't empty; one with neither warns") {
        let editor = CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
        let listed = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: " ", checklist: [ChecklistItem(text: "milk")]))
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
])
