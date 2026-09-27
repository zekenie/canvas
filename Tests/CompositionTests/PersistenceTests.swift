import Canvas
import CanvasTesting
import Checklists
import Composition
import CoreGraphics
import Foundation
import StickyNotes
import TestKit

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
    // A note's title is optional, so it came without a migration: an untitled note writes none,
    // as its fixture shows, and boards from before titles read as untitled notes.
    test("a note's title reads back as it was written") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let document = registry.fillingDefaults(CanvasDocument(shapes: [record(StickyNote(frame: frame, text: "Milk", title: "Groceries")),
                                                                        record(StickyNote(frame: frame))]))
        let data = try codec.encode(document)
        expectEqual(try codec.decode(data).document, document)
        expectEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "\"title\"").count, 2, "the titled note's, alone")
    },
])
