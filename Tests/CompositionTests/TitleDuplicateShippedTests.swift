import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import LanguageModels
import Mentions
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Types
import Validation

// A note's title written from the field that titles it is a title like any other: what the path warning (Boards'
// `PathValidationPlugin`) says of two notes given one name by their field, and of a copy, as the app has them.

@MainActor let titleDuplicateShippedTests = Suite("A title copied from a field is a title, as shipped", [
    test("two Persons given one name both warn, a duplicate does, and renaming one clears both") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let person = FieldFixtures.namedPerson, name = FieldPath(field: "name")
        editor.addTypeNote(person.schema, text: MentionText(plain: person.words), title: person.title, frame: CGRect(x: 900, y: 40, width: 200, height: 200), id: person.id)
        @MainActor func addPerson(at x: CGFloat, title: String? = nil, name: String? = nil) -> ShapeID {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: x, y: 400, width: 200, height: 200), text: ""))
            note[IsAProperty.self] = [TypeLink(person.id)]
            note[TitleProperty.self] = title
            if let name { note[FieldValuesProperty.self] = FieldValues(["name": .string(name)]) }
            editor.transact("Add Note") { $0.insert(AnyShapeRecord(note)) }
            return note.id
        }
        @MainActor func issues(_ id: ShapeID) -> [ValidationIssue] { editor.validation?.result(for: id)?.issues ?? [] }
        let writer = try require(editor.fieldWriter)
        let ann = addPerson(at: 40), other = addPerson(at: 300)
        expect(writer.setTyped("Ann Lee", as: .text, at: name, of: ann))
        expectEqual(issues(ann), [])
        expect(writer.setTyped("Ann Lee", as: .text, at: name, of: other))
        let words = "“Ann Lee” is another shape’s title too."
        expectEqual(issues(ann).map(\.message), [words])
        expectEqual(issues(other).map(\.message), [words])
        expectEqual(issues(ann).map(\.field), ["title"])
        // A copy carries its title and its value (what a paste or a duplicate makes), and warns as any title does.
        let copy = addPerson(at: 600, title: "Ann Lee", name: "Ann Lee")
        expectEqual(issues(copy).map(\.message), [words])
        expect(writer.setTyped("Ann Lees", as: .text, at: name, of: other))
        expectEqual(issues(other), [])
        expectEqual(issues(ann).map(\.message), [words], "the copy still shares it")
        editor.transact { $0.delete([copy]) }
        expectEqual(issues(ann), [])
    },
])
