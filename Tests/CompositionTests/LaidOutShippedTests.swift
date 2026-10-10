import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import Connections
import CoreGraphics
import Frames
import LanguageModels
import Locking
import Mentions
import References
import Selection
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// Laid out as shipped: no shipped plugin provides a layout input yet, so every shipped shape is as
// big as it stores, however the board is made. (Types provides one for a typed note's rows in a later
// slice, which deletes this test.)

@MainActor let laidOutShippedTests = Suite("Laid out, as shipped", [
    test("every shape of the shipped list, a type and its instance among them, is laid out as big as it stores") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        // A note too short for its words, as a rename or a draw leaves one, and one that says a lot.
        _ = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 40), text: MentionText(plain: (1...12).map { "line \($0)" }.joined(separator: "\n"))))
        let type = editor.addTypeNote(#"{"type": "object", "properties": {"name": {"type": "string"}, "species": {"type": "string"}}}"#,
                                      text: "A pet and its name", title: "Pet", frame: CGRect(x: 300, y: 0, width: 200, height: 200))
        var instance = ShapeRecord(StickyNote(frame: CGRect(x: 600, y: 0, width: 200, height: 100), text: "Rex"))
        instance[IsAProperty.self] = [TypeLink(type)]
        editor.transact { $0.insert(instance) }
        _ = editor.add(StickyNote(frame: CGRect(x: 900, y: 0, width: 200, height: 200), text: MentionText([.text("Ask "), .mention(type, label: "Pet")])))
        var locked = ShapeRecord(StickyNote(frame: CGRect(x: 0, y: 300, width: 160, height: 120), text: ""))
        locked[LockedProperty.self] = true
        editor.transact { $0.insert(locked) }
        _ = editor.add(Frame(frame: CGRect(x: 300, y: 300, width: 300, height: 200)))
        _ = editor.add(Subboard(frame: CGRect(x: 700, y: 300, width: 240, height: 160)))
        _ = editor.add(Reference(frame: CGRect(x: 1000, y: 300, width: 160, height: 32)))
        _ = editor.add(Arrow(start: .free(CGPoint(x: 0, y: 600)), end: .free(CGPoint(x: 200, y: 700)), bend: 0))
        _ = renderBitmap(editor, size: CGSize(width: 1200, height: 800))
        let context = editor.shapeContext
        expect(editor.document.shapes.count >= 9, "one of every shipped kind")
        for record in editor.document.shapes {
            guard let box = record.box else { continue }
            expectEqual(context.frame(of: record), box, "\(record.kind) is as big as it stores")
            expectEqual(context.geometry(of: record.id)?.bounds, box, "\(record.kind)'s geometry is its box")
            expectEqual(editor.frame(inFile: record.id), box, "\(record.kind) anywhere in the file")
        }
    },
])
