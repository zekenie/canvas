import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import StickyNotes
import TestKit
import Validation

@MainActor let stickyNotesTests = Suite("Sticky notes", [
    test("registers its kind, the N tool and the double-click claim") {
        let registry = try Registry(plugins: [StickyNotesPlugin(), ValidationPlugin()])
        expectEqual(registry.kinds, [StickyNote.kind])
        expectEqual(registry.tool(forShortcut: "n"), ToolID(placing: StickyNote.kind))
        expect(registry.definition(for: StickyNote.kind) is any Editable)
    },
    test("can't be installed without the validation plugin it contributes to") {
        expectThrows(RegistryError.ownerNotInstalled(point: "ValidationRules", owner: .validation, contributor: .stickyNotes)) {
            _ = try Registry(plugins: [StickyNotesPlugin()])
        }
    },
    test("N then a click places a note centered there, editing, and back in select") {
        let h = try EditorHarness(plugins: [StickyNotesPlugin(), ValidationPlugin()])
        h.key("n")
        h.press(at: CGPoint(x: 300, y: 300)); h.release()
        let note = try require(h.editor.document.shapes.first)
        expectEqual(note.box, CGRect(x: 200, y: 200, width: 200, height: 200))
        expectEqual(h.editor.editingShapeID, note.id)
        expectEqual(h.editor.currentToolID, .select)
    },
    test("an empty note warns; typing into its editor clears the warning; Escape ends editing") {
        let h = try EditorHarness(plugins: [StickyNotesPlugin(), ValidationPlugin()])
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
