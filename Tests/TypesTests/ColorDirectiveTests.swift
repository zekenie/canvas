@_spi(Host) import Canvas
import CanvasTesting
import Colors
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Palette
import TestKit
import Titles
import Types
import Validation

// A type's color in its schema, `"$color": {"const": "blue"}`: what a text says, how one is written
// into a text as typed, and the rule that keeps it and the type's own color saying one thing through
// every write (the panel's, the JSON's, a file's colors', a paste's, the model's).

private typealias Directive = TypeColorDirective

/// The starter with a color, as the rule writes one into it.
private let blueStarter = """
{
  "type": "object",
  "properties": {
    "$color": {"const": "blue"}
  }
}
"""

/// Memos have colors, and the book of colors is in the list (as `ColorTests`' editor has it).
@MainActor private func colorEditor(_ more: [any CanvasPlugin] = [], document: CanvasDocument = CanvasDocument()) throws -> CanvasEditor {
    try typeEditor(document: document, more: [Contributor(id: "memo-colors") { $0.colorable(Memo.self) }, ColorsPlugin()] + more)
}

extension CanvasEditor {
    fileprivate func color(_ id: ShapeID) -> ShapeColor? { document[id]?.ownColor }
}

@MainActor let colorDirectiveTests = Suite("A type's color in its schema", [
    test("a schema says a color, none, or one that isn't; nothing while it isn't a JSON object") {
        expectEqual(Directive.reading(of: blueStarter), .color(.blue))
        expectEqual(Directive.reading(of: TypeSchemaProperty.starter), Directive.Reading.none)
        expectEqual(Directive.reading(of: #"{"type": "object"}"#), Directive.Reading.none, "no properties")
        expectEqual(Directive.reading(of: ##"{"properties": {"$color": {"const": "#46e"}}}"##), .color(.value(RGB(hex: 0x4466EE))), "a hex value")
        expectEqual(Directive.reading(of: #"{"properties": {"$color": {"const": "Brand Blue"}}}"#), .color(.named("Brand Blue")), "a file's name")
        expectEqual(Directive.reading(of: #"{"properties": {"$color": "blue"}}"#), .notAColor, "a bare string")
        expectEqual(Directive.reading(of: #"{"properties": {"$color": {"const": ""}}}"#), .notAColor, "nothing")
        expectEqual(Directive.reading(of: ##"{"properties": {"$color": {"const": "#12"}}}"##), .notAColor, "a # that is no hex")
        expectEqual(Directive.reading(of: #"{"properties": {"$color": {"const": 3}}}"#), .notAColor)
        expectEqual(Directive.reading(of: #"{"properties": {"$color": {"const": "red"}, "$color": {"const": "teal"}}}"#), .color(.teal), "the last")
        expectEqual(Directive.reading(of: #"{"properties": {"g": {"properties": {"$color": {"const": "red"}}}}}"#), Directive.Reading.none, "a group's member is a field's")
        expectEqual(Directive.reading(of: #"{"properties": {"#), nil)
        expectEqual(Directive.reading(of: "[1]"), nil)
    },
    test("a reading says a shape's color: none for none, a name whatever its case, a value for itself") {
        expect(Directive.says(.none, nil))
        expect(Directive.says(.color(.named("BLUE")), .blue))
        expect(Directive.says(.color(.value(RGB(hex: 0x4466EE))), .value(RGB(hex: 0x4466EE))))
        expect(!Directive.says(.color(.blue), nil))
        expect(!Directive.says(.none, .blue))
        expect(!Directive.says(.notAColor, nil), "one that isn't a color says nothing")
    },
    test("a color is written into a text as typed: first in the root's properties, on a line of its own; its const replaced after") {
        expectEqual(Directive.text(TypeSchemaProperty.starter, saying: .blue), blueStarter, "into the starter's empty properties")
        expectEqual(Directive.text(blueStarter, saying: .value(RGB(hex: 0x4465E9))), blueStarter.replacingOccurrences(of: "\"blue\"", with: "\"#4465E9\""),
                    "its const alone replaced")
        expectEqual(Directive.text(blueStarter, saying: .blue), blueStarter, "the same text, already saying it")
        let pretty = """
        {
            "type": "object",
            "properties": {
                "name": {"type": "string"}
            }
        }
        """
        expectEqual(Directive.text(pretty, saying: .teal), """
        {
            "type": "object",
            "properties": {
                "$color": {"const": "teal"},
                "name": {"type": "string"}
            }
        }
        """, "indented as the member after it")
        expectEqual(Directive.text(#"{"properties":{"a":{}}}"#, saying: .red), #"{"properties":{"$color": {"const": "red"},"a":{}}}"#, "compact")
        expectEqual(Directive.text(#"{"type": "object"}"#, saying: .red), #"{"properties": {"$color": {"const": "red"}}, "type": "object"}"#,
                    "a properties put in the root")
        expectEqual(Directive.text(#"{"properties": {"$color": "red"}}"#, saying: .pink), #"{"properties": {"$color": {"const": "pink"}}}"#,
                    "one that isn't a color made one")
        expectEqual(Directive.text(#"{"properties": 3}"#, saying: .red), nil, "properties that aren't an object")
        expectEqual(Directive.text(#"{"properties": {"#, saying: .red), nil, "a text being typed")
    },
    test("none takes every $color out, with its comma; the starter comes back as it was") {
        expectEqual(Directive.text(blueStarter, saying: nil), TypeSchemaProperty.starter)
        expectEqual(Directive.text(#"{"properties": {"$color": {"const": "red"}, "a": {}}}"#, saying: nil), #"{"properties": {"a": {}}}"#, "first")
        expectEqual(Directive.text(#"{"properties": {"a": {}, "$color": {"const": "red"}}}"#, saying: nil), #"{"properties": {"a": {}}}"#, "last")
        expectEqual(Directive.text(#"{"properties": {"$color": 1, "a": {}, "$color": {"const": "red"}}}"#, saying: nil), #"{"properties": {"a": {}}}"#, "both")
        expectEqual(Directive.text(TypeSchemaProperty.starter, saying: nil), TypeSchemaProperty.starter, "none to take")
        expectEqual(Directive.stripped(blueStarter), TypeSchemaProperty.starter)
        expectEqual(Directive.stripped(#"{"properties": {"#), #"{"properties": {"#, "a text being typed, as it is")
        let pretty = try require(Directive.text(#"{"type": "object", "properties": {"name": {}}}"#, saying: .red))
        expectEqual(Directive.text(pretty, saying: nil), #"{"type": "object", "properties": {"name": {}}}"#, "there and back")
    },
    test("a schema written whole keeps the $color of the one it replaces, as written, unless it says one") {
        let held = #"{"properties": {"$color": { "const" : "teal" }, "a": {}}}"#
        expectEqual(Directive.carried(from: held, into: #"{"properties": {"b": {}}}"#), #"{"properties": {"$color": { "const" : "teal" }, "b": {}}}"#)
        expectEqual(Directive.carried(from: held, into: #"{"properties": {"$color": {"const": "red"}}}"#), #"{"properties": {"$color": {"const": "red"}}}"#,
                    "it says one")
        expectEqual(Directive.carried(from: #"{"properties": {"$color": 4}}"#, into: "{}"), #"{"properties": {"$color": 4}}"#, "even one that isn't a color")
        expectEqual(Directive.carried(from: TypeSchemaProperty.starter, into: "{}"), "{}", "none held")
        expectEqual(Directive.carried(from: nil, into: "{}"), "{}")
        expectEqual(Directive.carried(from: held, into: #"{"properties": {"#), #"{"properties": {"#, "written being typed")
        // What the rule writes and what is carried into the text it was written into are the same text.
        let script = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        let kept = try require(Directive.text(script, saying: .blue))
        expectEqual(Directive.carried(from: kept, into: script), kept)
    },
])

@MainActor let typeColorStepTests = Suite("A type's color kept in its schema", [
    test("a color given to a type is written in its JSON in the same step; none takes it out; undo puts both back") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        editor.setColor(.blue, of: [person])
        expectEqual(editor.schema(person), blueStarter)
        expectEqual(editor.undoHistory.undoName, ColorsStyle.changeColor)
        editor.setColor(.value(RGB(hex: 0x4465E9)), of: [person])
        expectEqual(editor.schema(person), blueStarter.replacingOccurrences(of: "\"blue\"", with: "\"#4465E9\""))
        editor.setColor(nil, of: [person])
        expectEqual(editor.schema(person), TypeSchemaProperty.starter)
        expectEqual(editor.color(person), nil)
        editor.undo()
        expectEqual(editor.color(person), .value(RGB(hex: 0x4465E9)))
        expect(editor.schema(person)?.contains("#4465E9") == true)
        editor.undo()
        expectEqual(editor.color(person), .blue)
        expectEqual(editor.schema(person), blueStarter)
        editor.undo()
        expectEqual(editor.schema(person), TypeSchemaProperty.starter)
    },
    test("a color given to a type, written in its JSON, is a color change alone: no revision moves and no type is told changed") {
        let editor = try colorEditor()
        let types = try require(editor.types)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        _ = editor.addInstance("Ann", of: [person], title: "Ann")
        let revision = types.revision(of: person)
        let told = Counter()
        types.onChange { change in if !change.types.isEmpty { told.count += 1 } }
        editor.setColor(.blue, of: [person])
        editor.setColor(.value(RGB(hex: 0x4465E9)), of: [person])
        editor.setColor(nil, of: [person])
        expectEqual(types.revision(of: person), revision)
        expectEqual(told.count, 0)
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {"a": {}}}"#) } }
        expect(types.revision(of: person) != revision, "a field is a change")
        expectEqual(told.count, 1)
    },
    test("a $color written in the JSON is the type's color, its pill and its instances' chips; taken out, the color goes") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        _ = editor.addInstance("Ann", of: [person], title: "Ann")
        let byId = try require(editor.types).look(of: person)
        let other: ShapeColor = TypeColors.name(of: person) == .teal ? .pink : .teal
        let written = try require(Directive.text(TypeSchemaProperty.starter, saying: other))
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(written) } }
        expectEqual(editor.color(person), other)
        expectEqual(try require(editor.types).look(of: person).swatch, BuiltInColors.named(try require(other.name))?.swatch)
        expectEqual(editor.schema(person), written, "the text as typed")
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {"$color": {"const": "TEAL"}}}"#) } }
        expectEqual(editor.color(person), .teal, "a built-in name in its list's spelling")
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) } }
        expectEqual(editor.color(person), nil)
        expectEqual(try require(editor.types).look(of: person).swatch, byId.swatch, "its id's again")
    },
    test("a $color that isn't a color changes no color and warns; one being typed changes nothing; a color picked then replaces it") {
        let editor = try colorEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        editor.setColor(.green, of: [person])
        let wrong = #"{"properties": {"$color": "green"}}"#
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(wrong) } }
        expectEqual(editor.color(person), .green)
        expect(editor.issues(person).map(\.message).contains("“$color” isn’t a color."), "\(editor.issues(person).map(\.message))")
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(##"{"properties": {"$color": {"const": "#4"##) } }
        expectEqual(editor.color(person), .green, "a text being typed")
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(#"{"properties": {}}"#) } }
        expectEqual(editor.color(person), nil, "a member typed away keystroke by keystroke, through text that isn't JSON, takes the color")
        editor.setColor(.green, of: [person])
        editor.transact("Change JSON") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(wrong) } }
        editor.setColor(.pink, of: [person])
        expectEqual(editor.schema(person), #"{"properties": {"$color": {"const": "pink"}}}"#)
        expect(!editor.issues(person).map(\.message).contains("“$color” isn’t a color."))
    },
    test("a $color naming a color the file lacks is held as the name, and Colors warns of it") {
        let editor = try colorEditor([ColorValidationPlugin()])
        let person = editor.addType(#"{"properties": {"$color": {"const": "Brand"}}}"#, title: "Person")
        expectEqual(editor.color(person), .named("Brand"))
        expect(editor.issues(person).contains { $0.field == "color" }, "\(editor.issues(person).map(\.message))")
        expect(editor.defineColor(named: "Brand", value: RGB(hex: 0x4465E9)))
        expectEqual(try require(editor.types).look(of: person).swatch, Swatch(RGB(hex: 0x4465E9)))
    },
    test("a type put in, or a note made one, says one color both ways: its JSON's, else its own written into the JSON") {
        let editor = try colorEditor()
        var colored = typeRecord(TypeSchemaProperty.starter, title: "Pasted")
        colored[ColorProperty.self] = .blue
        editor.transact { $0.insert(colored) }
        expectEqual(editor.schema(colored.id), blueStarter, "its color written in")
        var said = typeRecord(#"{"properties": {"$color": {"const": "teal"}}}"#, title: "Drawn", at: CGPoint(x: 400, y: 40))
        said[ColorProperty.self] = .pink
        editor.transact { $0.insert(said) }
        expectEqual(editor.color(said.id), .teal, "its JSON's, when the two differ")
        let note = editor.addInstance("A pet", of: [], title: "Pet", at: CGPoint(x: 800, y: 40))
        editor.setColor(.orange, of: [note])
        expectEqual(editor.schema(note), nil, "no type, no schema")
        editor.makeType(note)
        expectEqual(editor.color(note), .orange)
        expectEqual(Directive.reading(of: try require(editor.schema(note))), .color(.orange), "made a type, its color in its JSON")
        editor.undo()
        expectEqual(editor.schema(note), nil)
        expectEqual(editor.color(note), .orange, "the note keeps its color")
    },
    test("an instance's color, or a plain note's, writes no schema; a type built on another keeps its own color") {
        let editor = try colorEditor()
        let person = editor.addType(blueStarter, title: "Person")
        expectEqual(editor.color(person), .blue)
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        editor.addTypeLink(person, to: employee)
        expectEqual(editor.color(employee), nil)
        expectEqual(try require(editor.types).look(of: employee).swatch, BuiltInColors.named(try require(TypeColors.name(of: employee).name))?.swatch)
        let ann = editor.addInstance("Ann", of: [person], title: "Ann")
        editor.setColor(.pink, of: [ann])
        expectEqual(editor.document[ann]?[TypeSchemaProperty.self], nil)
        expectEqual(editor.schema(person), blueStarter)
    },
    test("a file's color renamed or removed rewrites the $color of every type that holds it, in the same step") {
        let editor = try colorEditor()
        expect(editor.defineColor(named: "Brand", value: RGB(hex: 0x4465E9)))
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        editor.setColor(.named("Brand"), of: [person])
        expectEqual(Directive.reading(of: try require(editor.schema(person))), .color(.named("Brand")))
        expect(editor.renameColor("Brand", to: "Ocean"))
        expectEqual(Directive.reading(of: try require(editor.schema(person))), .color(.named("Ocean")))
        expect(editor.removeColor("Ocean"))
        expectEqual(Directive.reading(of: try require(editor.schema(person))), .color(.value(RGB(hex: 0x4465E9))), "the value it was")
        editor.undo()
        expectEqual(Directive.reading(of: try require(editor.schema(person))), .color(.named("Ocean")))
    },
    test("a type and its color disagreeing from before are left until either changes") {
        var record = typeRecord(TypeSchemaProperty.starter, title: "Old")
        record[ColorProperty.self] = .green
        let editor = try colorEditor(document: CanvasDocument(shapes: [record]))
        editor.transact("Change JSON") { $0.update(record.id) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"a": {}}}"#) } }
        expectEqual(editor.color(record.id), .green, "an edit of its fields takes no color away")
        expectEqual(editor.schema(record.id), #"{"type": "object", "properties": {"a": {}}}"#, "and writes none in")
        editor.setColor(.blue, of: [record.id])
        expectEqual(Directive.reading(of: try require(editor.schema(record.id))), .color(.blue))
    },
])

@MainActor let colorSyncTests = Suite("A type's color and the model", [
    test("a type given a color asks the model nothing, stays in step, and the model is never sent its $color") {
        let b = try SyncBench(more: [Contributor(id: "memo-colors") { $0.colorable(Memo.self) }, ColorsPlugin()])
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.model.requests.count, 1)
        b.editor.setColor(.purple, of: [id])
        expectEqual(Directive.reading(of: try require(b.schema(id))), .color(.purple))
        expect(b.sync.isInStep(id), "in step at once")
        b.scheduler.advance(by: .seconds(10))
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "nothing asked")
        b.typeWords(id, "a pet in my household, and its vet")
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.requests.count == 2 && b.status(id) == .idle })
        let sent = try require(b.message(1))
        expect(!sent.contains("$color"), sent)
        expectEqual(Directive.reading(of: try require(b.schema(id))), .color(.purple), "the model's schema keeps the type's color")
        expectEqual(b.editor.color(id), .purple)
    },
    test("words that are JSON become the schema with the type's color, and the words written from it are never sent it") {
        let b = try SyncBench(more: [Contributor(id: "memo-colors") { $0.colorable(Memo.self) }, ColorsPlugin()])
        let id = b.place()
        b.editor.setColor(.teal, of: [id])
        let typed = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        b.typeWords(id, typed)
        b.sync(id, answer: "A thing: its name.")
        expectEqual(b.editor.color(id), .teal)
        expectEqual(b.schema(id), Directive.text(typed, saying: .teal), "the words' fields, and the color")
        expectEqual(b.words(id), "A thing: its name.")
        let sent = try require(b.message(0))
        expect(!sent.contains("$color"), sent)
    },
])
