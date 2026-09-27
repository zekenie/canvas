import Canvas
import CanvasTesting
import Checklists
import Composition
import CoreGraphics
import Foundation
import StickyNotes
import TaskCards
import TestKit
import Titles

@MainActor private func record<P: ShapeProps>(_ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(props)) }

@MainActor let persistenceTests = Suite("Persistence", [
    // Fixtures/kinds holds one shape's props per shipped kind and version, written once, never
    // edited: how boards of that version were written.
    test("every shipped kind reads its fixture at every version, and writes today's back byte for byte") {
        let registry = try ShippedPlugins.registry()
        expectKindFixtures(registry.kinds, in: registry, directory: "Tests/CompositionTests/Fixtures/kinds")
    },
    // Fixtures/added holds one shape's value per shipped added property and version, the same way.
    test("every shipped added property reads its fixture at every version, and writes today's back byte for byte") {
        let registry = try ShippedPlugins.registry()
        expectPropertyFixtures(registry.declaredProperties, in: registry, directory: "Tests/CompositionTests/Fixtures/added")
    },
    // Before Checklists added the checklist to the kinds that opt in, each kind kept its own.
    test("a note or a task from before hands its checklist over to Checklists' property") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        for kind: ShapeKind in ["sticky-note", "task-card"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/kinds/\(kind.rawValue).v0.json"))
            let record = try codec.decodeRecord(props: data, kind: kind, version: 0)
            expectEqual(record[ChecklistProperty.self], [ChecklistItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                                                        text: "Oat milk", isDone: true)], "\(kind)")
            let props = try JSONDecoder().decode(JSONValue.self, from: codec.encodeProps(record.props))
            expect(props["checklist"] == nil, "\(kind) keeps no checklist of its own")
        }
    },
    test("the welcome board, and a board of every shipped kind, read back as they were") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        var shapes: [AnyShapeRecord] = []
        for kind in registry.kinds {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/kinds/\(kind.rawValue).v\(try require(codec.version(of: kind))).json"))
            shapes.append(record(try codec.decodeProps(data, kind: kind, version: try require(codec.version(of: kind)))))
        }
        // As an editor has them: with the defaults of what their kinds opt into.
        for document in [WelcomeBoard.document(), CanvasDocument(shapes: shapes)].map(registry.fillingDefaults) {
            let loaded = try codec.decode(try codec.encode(document))
            expectEqual(loaded.document, document)
            expect(loaded.report.isEmpty, "\(loaded.report)")
        }
    },
    // A note's title is the property Titles adds, with no default: an untitled note writes none, and
    // boards from before titles read as untitled notes.
    test("a note's title reads back as it was written, among its added values; an untitled note writes none") {
        let registry = try ShippedPlugins.registry()
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
    // Each note and task the app ever titled keeps its title, now Titles': the kinds hand their own
    // over (`PropsMigration.handOver`), and a task's blank title, how an untitled task was written,
    // is none.
    test("boards from before Titles kept titles read them as Titles' property, and a task's blank title as none") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        let board = """
            { "format" : 3, "versions" : { "added" : { "checklist" : 0 }, "kinds" : { "sticky-note" : 1, "task-card" : 1 } }, "shapes" : [
              { "id" : "11111111-1111-1111-1111-111111111111", "index" : "a0", "kind" : "sticky-note",
                "props" : { "frame" : [[0, 0], [200, 200]], "text" : "Milk", "title" : "Groceries" }, "added" : { "checklist" : [] } },
              { "id" : "22222222-2222-2222-2222-222222222222", "index" : "a1", "kind" : "task-card",
                "props" : { "frame" : [[300, 0], [240, 200]], "title" : "Ship it" }, "added" : { "checklist" : [] } },
              { "id" : "33333333-3333-3333-3333-333333333333", "index" : "a2", "kind" : "task-card",
                "props" : { "frame" : [[600, 0], [240, 200]], "title" : "  " }, "added" : { "checklist" : [] } }
            ] }
            """
        let loaded = try codec.decode(Data(board.utf8))
        expectEqual(loaded.report, LoadReport())
        expectEqual(loaded.document.shapes.map { $0[TitleProperty.self] }, ["Groceries", "Ship it", nil])
        expectEqual(loaded.document.shapes.compactMap { $0.typed(as: TaskCard.self)?.isUntitled }, [false, true])
    },
])
