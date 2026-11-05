import Arrows
import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Frames
import LanguageModels
import Mentions
import References
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

@MainActor private func record<P: ShapeProps>(_ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(props)) }

@MainActor let persistenceTests = Suite("Persistence", [
    // Fixtures/kinds holds one shape's props per shipped kind and version, written once, never
    // edited: how boards of that version were written.
    test("every shipped kind reads its fixture at every version, and writes today's back byte for byte") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectKindFixtures(registry.kinds, in: registry, directory: "Tests/CompositionTests/Fixtures/kinds")
    },
    // Fixtures/added holds one shape's value per shipped added property and version, the same way.
    test("every shipped added property reads its fixture at every version, and writes today's back byte for byte") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expectPropertyFixtures(registry.declaredProperties, in: registry, directory: "Tests/CompositionTests/Fixtures/added")
    },
    // Fixtures/file holds the file's value per shipped file property and version, the same way.
    test("every shipped file property reads its fixture at every version, and writes today's back byte for byte") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        expect(!registry.declaredFileProperties.isEmpty, "the shipped list declares file properties")
        expectFilePropertyFixtures(registry.declaredFileProperties, in: registry, directory: "Tests/CompositionTests/Fixtures/file")
    },
    // Since its third version a note's text may mention shapes: what it said before reads as it did.
    test("a note's text from before mentions reads as the text it was; today's fixture holds mentions, and a look-alike that's text") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let directory = "Tests/CompositionTests/Fixtures/kinds"
        expectEqual(codec.version(of: StickyNote.kind), 4)
        for version in 0...2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/sticky-note.v\(version).json"))
            let note = try require(codec.decodeRecord(props: data, kind: StickyNote.kind, version: version).typed(as: StickyNote.self))
            expectEqual(note.props.text.stored, "Buy milk\nand bread", "version \(version): no look-alike, so written as it was")
            expectEqual(note.props.text.runs, [.text("Buy milk\nand bread")])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/sticky-note.v3.json"))
        let note = try require(codec.decodeRecord(props: data, kind: StickyNote.kind, version: 3).typed(as: StickyNote.self))
        let groceries = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
        let review = ShapeID(UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!)
        expectEqual(note.props.text.runs, [
            .text("Ask "), .mention(groceries, label: "Groceries"), .text(" first.\nThen "),
            .mention(review, label: #"Q3 ] review \ notes"#),
            .text(#", not @[Q2](shape:11111111-2222-4333-8444-555555555555).\#nSaved in C:\"#),
            .mention(groceries, label: "Plans"),
        ])
        expectEqual(MentionText(note.props.text.runs), note.props.text, "written as a note's editor writes it")
    },
    // Since its third version an arrow's text may mention shapes: what it said before reads as it did.
    test("an arrow's text from before mentions reads as the text it was; today's fixture holds mentions, and a look-alike that's text") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let directory = "Tests/CompositionTests/Fixtures/kinds"
        expectEqual(codec.version(of: Arrow.kind), 2)
        let before = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/arrow.v1.json"))
        let old = try require(codec.decodeRecord(props: before, kind: Arrow.kind, version: 1).typed(as: Arrow.self))
        expectEqual(old.props.text.runs, [.text("Calls")])
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/arrow.v2.json"))
        let arrow = try require(codec.decodeRecord(props: data, kind: Arrow.kind, version: 2).typed(as: Arrow.self))
        let groceries = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
        expectEqual(arrow.props.text.runs, [.text("Calls "), .mention(groceries, label: "Groceries"), .text(", not @[Q2](shape:11111111-2222-4333-8444-555555555555)")])
        expectEqual(MentionText(arrow.props.text.runs), arrow.props.text, "written as an arrow's editor writes it")
        // A label from before that reads as a mention (a look-alike or a whole one) is the text it was.
        var looks = try require(JSONValue.object(["start": .object(["free": .array([0, 0])]), "end": .object(["free": .array([1, 1])]),
                                                    "text": "see @[x](shape:1234)"]).objectValue)
        looks["bend"] = 0
        let escaped = try require(codec.decodeRecord(props: try JSONEncoder().encode(JSONValue.object(looks)), kind: Arrow.kind, version: 1).typed(as: Arrow.self))
        expectEqual(escaped.props.text.runs, [.text("see @[x](shape:1234)")])
    },
    // Since its first version a pill is 40 tall, for the place over its name: a pill from before keeps its center.
    test("a reference from before it was 40 tall keeps its center; today's fixture is 40 tall and its other members are as they were") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let directory = "Tests/CompositionTests/Fixtures/kinds"
        expectEqual(codec.version(of: Reference.kind), 1)
        let before = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/reference.v0.json"))
        let old = try require(codec.decodeRecord(props: before, kind: Reference.kind, version: 0).typed(as: Reference.self))
        expectEqual(old.props.frame, CGRect(x: 0, y: -4, width: 160, height: 40), "32 tall at y 0 is 40 tall at y -4: the same middle")
        expectEqual(old.props.query, "sticky-note")
        expectEqual(old.props.target?.label, "Shapes")
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(directory)/reference.v1.json"))
        let now = try require(codec.decodeRecord(props: data, kind: Reference.kind, version: 1).typed(as: Reference.self))
        expectEqual(now.props.frame, CGRect(x: 0, y: 0, width: 160, height: 40))
        expectEqual(now.props.words, "every note")
    },
    // A type's schema (Types' added property) is its text, one string, whose `$ref`s to other types
    // name them, as a note's mentions do.
    test("a type note's schema reads as the text it was, and names the type its $ref points to") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        expectEqual(codec.version(ofProperty: TypeSchemaProperty.key), 0)
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/added/schema.v0.json"))
        let schema = try JSONDecoder().decode(SchemaText.self, from: try codec.migrateValue(data, property: TypeSchemaProperty.key, version: 0))
        let address = ShapeID(UUID(uuidString: "5B0E7C1A-3D2F-4E6B-8A9C-1F2E3D4C5B6A")!)
        expect(schema.text.hasPrefix("{\n  \"type\": \"object\""), schema.text)
        expectEqual(SchemaReferences.refs(in: schema.text).map(\.shape), [address])
        var named: [ShapeID] = []
        schema.forEachNamedShape { named.append($0) }
        expectEqual(named, [address], "a $ref names its type, as a mention does")
        expect(registry.properties(for: StickyNote.kind).contains(TypeSchemaProperty.key), "a note can be a type")
    },
    // The types a shape is, an ordered list of the types' ids (Types' added property): read back in the
    // order written, each a name of its type, as a mention is.
    test("a shape's types read as the ids' list they were, in order, each naming its type; notes, arrows, subboards and frames can hold them") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        expectEqual(codec.version(ofProperty: IsAProperty.key), 0)
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/added/is.v0.json"))
        let types = try JSONDecoder().decode([TypeLink].self, from: try codec.migrateValue(data, property: IsAProperty.key, version: 0))
        let groceries = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
        let review = ShapeID(UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!)
        expectEqual(types.map(\.shape), [groceries, review])
        var named: [ShapeID] = []
        types.forEachNamedShape { named.append($0) }
        expectEqual(named, [groceries, review], "an entry names its type")
        for kind in [StickyNote.kind, Arrow.kind, Subboard.kind, Frame.kind] {
            expect(registry.properties(for: kind).contains(IsAProperty.key), "\(kind) can be an instance of a type")
        }
    },
    // What a shape holds for the fields of its types: a bare JSON object, nothing empty in it, on the
    // kinds that can be instances.
    test("a shape's values read as the object they were; notes, arrows, subboards and frames can hold them; a frame holds no autofill, a subboard does") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        expectEqual(codec.version(ofProperty: FieldValuesProperty.key), 0)
        let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/added/fieldValues.v0.json"))
        let values = try JSONDecoder().decode(FieldValues.self, from: try codec.migrateValue(data, property: FieldValuesProperty.key, version: 0))
        expectEqual(values["status"], .string("paid"))
        expectEqual(values["gift"], .bool(false), "a false is a value")
        expectEqual(values["address"]?["city"], .string("Leeds"))
        expectEqual(values["lineItems"]?.arrayValue?.count, 2)
        expectEqual(values["lineItems"]?.arrayValue?.last?["price"], .number(0), "a 0 is a value")
        expectEqual(values["tags"], .array(["gift", "mugs"]))
        expectEqual(FieldValues.pruned(.object(values.values)), .object(values.values), "nothing in a fixture is empty")
        for kind in [StickyNote.kind, Arrow.kind, Subboard.kind, Frame.kind] {
            expect(registry.properties(for: kind).contains(FieldValuesProperty.key), "\(kind) can hold the values of its types' fields")
        }
        expect(registry.properties(for: Subboard.kind).contains(AutofillProperty.key), "a subboard's description is its words")
        expect(!registry.properties(for: Frame.kind).contains(AutofillProperty.key), "a frame has no words to fill from")
    },
    test("the sample board, and a board of every shipped kind, read back as they were") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        var shapes: [AnyShapeRecord] = []
        for kind in registry.kinds {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/kinds/\(kind.rawValue).v\(try require(codec.version(of: kind))).json"))
            shapes.append(record(try codec.decodeProps(data, kind: kind, version: try require(codec.version(of: kind)))))
        }
        // As an editor has them: with the defaults of what their kinds opt into.
        for document in [SampleBoard.document(), CanvasDocument(shapes: shapes)].map(registry.fillingDefaults) {
            let loaded = try codec.decode(try codec.encode(document))
            expectEqual(loaded.document, document)
            expect(loaded.report.isEmpty, "\(loaded.report)")
        }
    },
    // A note's title is the property Titles adds, with no default: an untitled note writes none, and
    // boards from before titles read as untitled notes.
    test("a note's title reads back as it was written, among its added values; an untitled note writes none") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        var titled = ShapeRecord(StickyNote(frame: frame, text: "Milk"))
        titled[TitleProperty.self] = "Groceries"
        let document = registry.fillingDefaults(CanvasDocument(shapes: [AnyShapeRecord(titled), record(StickyNote(frame: frame))]))
        let data = try codec.encode(document)
        expectEqual(try codec.decode(data).document, document)
        let shapes = try require(try JSONDecoder().decode(JSONValue.self, from: data)["shapes"]?.arrayValue)
        expectEqual(shapes.map { $0["added"]?["title"] }, ["Groceries", nil])
        expectEqual(shapes.map { $0["props"]?["title"] }, [nil, nil], "not the note's own")
    },
    // Each note the app ever titled keeps its title, now Titles': the kind hands its own over
    // (`PropsMigration.handOver`), and a blank one is none.
    test("boards from before Titles kept titles read them as Titles' property, and a blank title as none") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let board = """
            { "format" : 3, "versions" : { "kinds" : { "sticky-note" : 1 } }, "shapes" : [
              { "id" : "11111111-1111-1111-1111-111111111111", "index" : "a0", "kind" : "sticky-note",
                "props" : { "frame" : [[0, 0], [200, 200]], "text" : "Milk", "title" : "Groceries" } },
              { "id" : "22222222-2222-2222-2222-222222222222", "index" : "a1", "kind" : "sticky-note",
                "props" : { "frame" : [[300, 0], [200, 200]], "text" : "Eggs", "title" : "  " } }
            ] }
            """
        let loaded = try codec.decode(Data(board.utf8))
        expectEqual(loaded.report, LoadReport())
        expectEqual(loaded.document.shapes.map { $0[TitleProperty.self] }, ["Groceries", nil])
    },
    // A member written as null was one the props didn't have (a property reads null as missing),
    // so it hands nothing over; and a blank title, however it comes, is none. Neither is kept
    // aside, so the shape is renamed like any other.
    test("a title of null, or a blank title, in a board from before or among added values, is none, and the shape renames") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        let codec = BoardCodec(registry: registry)
        let board = """
            { "format" : 3, "versions" : { "added" : { "title" : 0 }, "kinds" : { "sticky-note" : 0 } }, "shapes" : [
              { "id" : "11111111-1111-1111-1111-111111111111", "index" : "a0", "kind" : "sticky-note",
                "props" : { "frame" : [[0, 0], [200, 200]], "text" : "Milk", "title" : null } },
              { "id" : "33333333-3333-3333-3333-333333333333", "index" : "a2", "kind" : "sticky-note",
                "props" : { "frame" : [[600, 0], [200, 200]], "text" : "", "title" : " " } },
              { "id" : "44444444-4444-4444-4444-444444444444", "index" : "a3", "kind" : "sticky-note", "v" : 2,
                "props" : { "frame" : [[900, 0], [200, 200]], "text" : "" }, "added" : { "title" : "" } },
              { "id" : "55555555-5555-5555-5555-555555555555", "index" : "a4", "kind" : "sticky-note", "v" : 2,
                "props" : { "frame" : [[1200, 0], [200, 200]], "text" : "" }, "added" : { "title" : null } },
              { "id" : "66666666-6666-6666-6666-666666666666", "index" : "a5", "kind" : "sticky-note", "v" : 3,
                "props" : { "frame" : [[1500, 0], [200, 200]], "text" : "" }, "kept" : { "title" : { "v" : 0, "value" : null } } }
            ] }
            """
        let loaded = try codec.decode(Data(board.utf8))
        expectEqual(loaded.report, LoadReport(), "nothing kept aside")
        expectEqual(loaded.document.shapes.map { $0[TitleProperty.self] }, [nil, nil, nil, nil, nil])
        let editor = CanvasEditor(registry: registry, document: loaded.document, scheduler: ManualScheduler())
        for shape in loaded.document.shapes { editor.transact { $0.update(shape.id) { $0[TitleProperty.self] = "Named" } } }
        expectEqual(editor.document.shapes.map { $0[TitleProperty.self] }, ["Named", "Named", "Named", "Named", "Named"])
    },
])
