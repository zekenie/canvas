import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// Editable's two hooks, `discardsWhenEditingEnds` and `editingStepName`, on a fixture kind of this
// file's own, a slip that's thrown away when its text is empty.

struct Slip: BoxShapeProps {
    static let kind: ShapeKind = "slip"
    static let properties = Properties<Slip> {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame: CGRect
    var text = ""
    init(_ frame: CGRect, text: String = "") {
        self.frame = frame
        self.text = text
    }
}

extension Slip {
    init() { self.init(.zero) }
}

final class SlipField: NSView {
    let context: EditContext<Slip>
    init(context: EditContext<Slip>) {
        self.context = context
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class AskLog {
    var asked: [String] = []
}

struct SlipDefinition {
    var log = AskLog()
    var named = true
}

extension SlipDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slip>, in context: RenderContext) {}
}

extension SlipDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Slip>, context: EditContext<Slip>) -> EditingView {
        let view = SlipField(context: context)
        return EditingView(view: view, firstResponder: view)
    }
    func discardsWhenEditingEnds(_ props: Slip) -> Bool {
        log.asked.append(props.text)
        return props.text.isEmpty
    }
    var editingStepName: String? { named ? "Edit Slip" : nil }
}

@MainActor private func slips(named: Bool = true, _ more: [any CanvasPlugin] = []) throws -> (EditorHarness, AskLog) {
    let log = AskLog()
    let plugins: [any CanvasPlugin] = [
        Contributor(id: "slips") { r in
            r.shape(SlipDefinition(log: log, named: named)) { slip in
                slip.tool(label: "Slip", systemImage: "rectangle", placing: slip.editingPlacement(size: CGSize(width: 100, height: 60)) { Slip() })
            }
        },
    ]
    let registry = try Registry(plugins: plugins + more)
    return (EditorHarness { CanvasEditor(registry: registry, scheduler: $0, stackingKeys: .sequential) }, log)
}

@MainActor private func type(_ editor: CanvasEditor, _ text: String) throws {
    let field = try require(editor.makeEditingView()?.view as? SlipField, "editing")
    field.context.update { $0.text += text }
}

@MainActor private func setText(_ editor: CanvasEditor, _ text: String) throws {
    let field = try require(editor.makeEditingView()?.view as? SlipField, "editing")
    field.context.update { $0.text = text }
}

private let frame = CGRect(x: 0, y: 0, width: 100, height: 60)

@MainActor let editingHooksTests = Suite("Editing hooks", [
    test("a slip placed and left empty is discarded inside the editing step: no shape and no step") {
        let (h, log) = try slips()
        let before = h.editor.undoHistory.undoName
        let events = UndoEventLog(h.editor)
        h.editor.setTool(ToolID(placing: Slip.kind))
        h.click(at: CGPoint(x: 100, y: 100))
        expect(h.editor.editingShapeID != nil)
        h.editor.endEditing()
        expectEqual(log.asked, [""])
        expectEqual(h.editor.document.shapes, [])
        expectEqual(h.editor.undoHistory.undoName, before, "the placement's step netted to nothing")
        expect(!h.editor.canUndo)
        expect(events.events.contains(.discarded))
        expect(!events.events.contains(.closed))
    },
    test("a placed slip with text is kept, its step the placement's") {
        let (h, log) = try slips()
        h.editor.setTool(ToolID(placing: Slip.kind))
        h.click(at: CGPoint(x: 100, y: 100))
        try type(h.editor, "hi")
        h.editor.endEditing()
        expectEqual(log.asked, ["hi"])
        expectEqual(h.editor.document.shapes.count, 1)
        expectEqual(h.editor.undoHistory.undoName, "Add Slip")
        h.editor.undo()
        expectEqual(h.editor.document.shapes, [])
    },
    test("a click elsewhere ends the session and discards too") {
        let (h, _) = try slips()
        h.editor.setTool(ToolID(placing: Slip.kind))
        h.click(at: CGPoint(x: 100, y: 100))
        h.click(at: CGPoint(x: 600, y: 600))
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.editor.document.shapes, [])
        expect(!h.editor.canUndo)
    },
    test("an existing slip emptied is discarded in a step of its own, which undo brings back") {
        let (h, _) = try slips()
        let slip = h.add(Slip(frame, text: "keep"))
        h.editor.undoHistory.clear()
        h.editor.beginEditing(slip)
        try setText(h.editor, "")
        h.editor.endEditing()
        expectEqual(h.editor.document.shapes, [])
        expectEqual(h.editor.undoHistory.undoName, "Edit Slip")
        h.editor.undo()
        expectEqual(h.editor.document[slip]?.typed(as: Slip.self)?.props.text, "keep")
    },
    test("the step an editing session opens is named by the kind, else Typing") {
        let (h, _) = try slips()
        let slip = h.add(Slip(frame, text: "a"))
        h.editor.undoHistory.clear()
        h.editor.beginEditing(slip)
        try type(h.editor, "b")
        expectEqual(h.editor.undoHistory.undoName, "Edit Slip")
        h.editor.endEditing()
        expectEqual(h.editor.undoHistory.undoName, "Edit Slip")
        let (plain, _) = try slips(named: false)
        let other = plain.add(Slip(frame, text: "a"))
        plain.editor.undoHistory.clear()
        plain.editor.beginEditing(other)
        try type(plain.editor, "b")
        expectEqual(plain.editor.undoHistory.undoName, "Typing")
    },
    test("undo, redo, a command, a draw or a replaced file ending the session never ask, and keep the empty slip") {
        let (h, log) = try slips([Contributor(id: "cmd") { r in
            r.command("end-editing") { $0.endEditing() }
        }])
        // undo
        let slip = h.add(Slip(frame, text: "x"))
        h.editor.undoHistory.clear()
        h.editor.beginEditing(slip)
        try setText(h.editor, "")
        h.editor.undo()
        expectEqual(log.asked, [], "undo owns the step")
        expectEqual(h.editor.document[slip]?.typed(as: Slip.self)?.props.text, "x")
        // a command (an action) under way
        h.editor.beginEditing(slip)
        expect(h.editor.perform("end-editing"))
        expectEqual(log.asked, [], "an action under way owns the step")
        // a draw
        h.editor.beginEditing(slip)
        h.editor.endEditing(discarding: false)
        expectEqual(log.asked, [])
        // a replaced file
        h.editor.beginEditing(slip)
        h.editor.replaceDocument(with: h.editor.document)
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(log.asked, [], "a file put in place")
        expect(h.editor.document[slip] != nil)
    },
])

/// Every event the history sends its host.
@MainActor final class UndoEventLog {
    var events: [UndoEvent] = []
    init(_ editor: CanvasEditor) { editor.undoHistory.didChange = { [unowned self] in events.append($0) } }
}
