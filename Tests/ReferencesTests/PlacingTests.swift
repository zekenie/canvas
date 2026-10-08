import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import References
import Selection
import TestKit
import Topology

// The Reference tool (R): a click places an empty pill, 120 by 32, centered on it, and types into it.
// What's typed writes words and refits the pill; one left empty is discarded; Return and Escape end
// editing; the steps are named for what the person did.

@MainActor private func place(_ h: EditorHarness, at point: CGPoint) throws -> ShapeID {
    expect(h.key("r"), "R is the Reference tool's key")
    expectEqual(h.editor.currentToolID, ToolID(placing: Reference.kind))
    h.press(at: point)
    h.release()
    return try require(h.editor.editingShapeID, "editing begins at once")
}

@MainActor let placingTests = Suite("Placing and typing into a reference", [
    test("the tool is the toolbar's last, after the other kinds' (Schema, then Reference), and R switches to it") {
        let h = try referenceHarness()
        let tools = h.editor.registry.tools.map(\.label)
        expectEqual(tools.last, "Reference")
        let tool = try require(h.editor.registry.tools.first { $0.label == "Reference" })
        expectEqual(tool.systemImage, "arrow.turn.up.right")
    },
    test("a click places an empty pill 120 by 32, centered on the click, and edits it: one step, \"Add Reference\"") {
        let h = try referenceHarness()
        let id = try place(h, at: CGPoint(x: 300, y: 300))
        expectEqual(h.editor.document[id]?.box, CGRect(x: 240, y: 284, width: 120, height: 32))
        expectEqual(h.reference(id)?.mode, .empty)
        expectEqual(h.editor.currentToolID, .select, "back to the select tool")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
    },
    test("typing writes the words, as the pill's, and refits its width with each keystroke, from its left edge, in the placement's step") {
        let h = try referenceHarness()
        let id = try place(h, at: CGPoint(x: 300, y: 300))
        let editing = try require(h.editor.makeEditingView())
        let textView = try require(editing.firstResponder as? NSTextView)
        textView.insertText("pay", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(h.reference(id)?.words, "pay")
        expectEqual(h.reference(id)?.mode, .dynamic)
        let short = try require(h.editor.document[id]?.box)
        expectEqual(short.minX, 240, "it grows rightward")
        textView.insertText("ment notes about the launch", replacementRange: NSRange(location: 3, length: 0))
        let long = try require(h.editor.document[id]?.box)
        expect(long.width > short.width, "wider as it's typed: \(short.width) then \(long.width)")
        expectEqual(long.minX, 240)
        expectEqual(long.height, 32)
        expectEqual(h.reference(id)?.query, nil)
        textView.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        expectEqual(h.editor.editingShapeID, nil, "Return ends editing")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference", "placing and typing are one step")
        h.editor.undo()
        expectEqual(h.editor.document[id], nil)
    },
    test("a new pill left empty is discarded as editing ends, and leaves no step") {
        let h = try referenceHarness()
        let steps = h.editor.undoHistory.undoName
        let id = try place(h, at: CGPoint(x: 300, y: 300))
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document[id], nil, "nothing was asked of it")
        expectEqual(h.editor.undoHistory.undoName, steps, "and no step is left")
    },
    test("an existing pill is edited as \"Edit Reference\": it starts with what it says, selected; emptied, it's put back and kept; unchanged, no step") {
        let h = try referenceHarness()
        let id = h.addReference(words: "blocked work")
        h.editor.selectedShapeIDs = [id]
        expect(h.key("\r"), "Return edits it")
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        expectEqual(textView.string, "blocked work")
        expectEqual(textView.selectedRange(), NSRange(location: 0, length: 12), "all selected, so typing replaces it")
        let before = h.editor.undoHistory.undoName
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expectEqual(h.editor.undoHistory.undoName, before, "nothing changed, no step")
        expect(h.key("\r"))
        let again = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        again.insertText("every note", replacementRange: again.selectedRange())
        expectEqual(h.reference(id)?.words, "every note")
        expectEqual(h.editor.undoHistory.undoName, "Edit Reference")
        again.insertText("", replacementRange: NSRange(location: 0, length: again.string.count))
        expectEqual(h.reference(id)?.words, "blocked work", "emptied, it's put back as it was")
        again.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        expect(h.editor.document[id] != nil, "and kept")
    },
    test("typing over a direct reference's name stands for those words instead, and the shape it named lets go of it") {
        let h = try referenceHarness()
        let box = h.addBox("shapes")
        let id = h.addReference(to: box, label: "shapes")
        h.editor.selectedShapeIDs = [id]
        expect(h.key("\r"))
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        expectEqual(textView.string, "shapes", "it starts with what it says")
        textView.insertText("every note", replacementRange: textView.selectedRange())
        expectEqual(h.reference(id)?.target, nil)
        expectEqual(h.reference(id)?.words, "every note")
        expectEqual(h.editor.topology?.standIns(for: box), [])
    },
    test("newlines pasted in become spaces: a pill is one line") {
        let h = try referenceHarness()
        let id = try place(h, at: CGPoint(x: 300, y: 300))
        let textView = try require(h.editor.makeEditingView()?.firstResponder as? NSTextView)
        textView.insertText("two\nlines", replacementRange: NSRange(location: 0, length: 0))
        expectEqual(h.reference(id)?.words, "two lines")
    },
])
