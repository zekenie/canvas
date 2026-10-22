import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import DetailPanel
import LanguageModels
import Mentions
import Selection
import StickyNotes
import SwiftUI
import TestKit
import Titles
import Types

// A relationship type's words, in its panel: a pill draws none, so its Schema tab has a Description section above the JSON,
// mention text in the panel's box, and what is typed there the model turns into fields, as a type's words on its note are.

/// The canvas and the panel side by side in an unshown window, as the app places them. Real time, so SwiftUI's updates
/// and the model's answers land while the main run loop runs.
@MainActor
private final class DescriptionWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let hosting: NSView

    init(_ editor: CanvasEditor) {
        self.editor = editor
        let canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 900 - DetailStyle.idealWidth, height: 600)
        let window = window
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: { [weak window, weak canvas] in
            if let canvas { window?.makeFirstResponder(canvas) }
        }))
        hosting.frame = CGRect(x: 900 - DetailStyle.idealWidth, y: 0, width: DetailStyle.idealWidth, height: 600)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.settle()
    }

    /// The description's box: the panel's one mention text.
    var box: MentionTextView<AnyMentionable>? { hosting.descendants(MentionTextView<AnyMentionable>.self).first }
}

/// A relationship type called `owner`, as a drag between two types leaves one: the starter schema, the mark, no words.
@MainActor private func addOwner(_ editor: CanvasEditor) -> ShapeID {
    var note = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200)))
    note[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
    note[RelationshipProperty.self] = true
    note[TitleProperty.self] = "owner"
    let record = AnyShapeRecord(note)
    editor.transact { $0.insert(record) }
    return record.id
}

@MainActor private func sections(of id: ShapeID, in editor: CanvasEditor) throws -> [String] {
    let state = try require(editor.detailPanel)
    return state.layout(for: try require(editor.document[id])).sections(in: .of(TypeSchemaTab.self)).map(\.section)
}

private let ownerSchema = #"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}"#

@MainActor let relationshipDescriptionTests = Suite("A relationship type's description", [
    test("a relationship type's Schema tab has a Description section above its JSON; a plain type's has none, and the mark taken off takes it away") {
        let editor = try CanvasEditor(registry: Registry(plugins: notePlugins + [LanguageModelsPlugin(model: ScriptedLanguageModel()), TypeDetailsPlugin()]), scheduler: ManualScheduler())
        let id = addOwner(editor)
        expectEqual(try sections(of: id, in: editor), ["Description", "JSON", "type-autofill"], "the kind's own section first")
        editor.makePlainTypes([id])
        expectEqual(try sections(of: id, in: editor), ["JSON", "type-autofill"], "a plain type's words are on its note")
        editor.makeRelationshipTypes([id])
        expectEqual(try sections(of: id, in: editor), ["Description", "JSON", "type-autofill"])
    },
    test("typing a description and Return writes the type's words, one step Change Description, and the model writes its fields from them, told it is a relationship type; the box is the panel's mention text") {
        let model = ScriptedLanguageModel()
        let editor = try CanvasEditor(registry: Registry(plugins: notePlugins + [LanguageModelsPlugin(model: model), TypeDetailsPlugin()]), scheduler: TaskScheduler())
        let id = addOwner(editor)
        editor.selection = id
        let w = DescriptionWindow(editor)
        defer { w.window.close() }
        w.window.spin { w.box != nil }
        let box = try require(w.box)
        expectEqual(box.owner, id)
        model.queue(ownerSchema)
        w.window.makeFirstResponder(box)
        w.window.settle()
        w.window.type("who owns the car, and since when")
        expectEqual(editor.document[id]?.typed(as: StickyNote.self)?.props.text.stored, "who owns the car, and since when", "written as it is typed")
        expectEqual(model.requests.count, 0, "nothing asked while it is typed")
        expectEqual(editor.undoHistory.undoName, "Change Description")
        w.window.pressReturn()
        w.window.spin { model.requests.count == 1 && editor.typeSync?.status(of: id) == .idle }
        expect(model.lastRequest?.system?.contains("A relationship type\n") == true, "told what a relationship type holds")
        expectEqual(editor.fieldDefiner?.fields(of: id).map(\.key), ["since"], "the fields the model wrote")
        expectEqual(editor.document[id]?.typed(as: StickyNote.self)?.props.text.stored, "who owns the car, and since when", "the words kept")
    },
])
