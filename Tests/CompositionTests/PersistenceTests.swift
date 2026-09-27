import Canvas
import CanvasTesting
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
    test("the welcome board, and a board of every shipped kind, read back as they were") {
        let registry = try ShippedPlugins.registry()
        let codec = BoardCodec(registry: registry)
        var shapes: [AnyShapeRecord] = []
        for kind in registry.kinds {
            let data = try Data(contentsOf: URL(fileURLWithPath: "Tests/CompositionTests/Fixtures/kinds/\(kind.rawValue).v\(try require(codec.version(of: kind))).json"))
            shapes.append(record(try codec.decodeProps(data, kind: kind, version: try require(codec.version(of: kind)))))
        }
        for document in [WelcomeBoard.document(), CanvasDocument(shapes: shapes)] {
            let loaded = try codec.decode(try codec.encode(document))
            expectEqual(loaded.document, document)
            expect(loaded.report.isEmpty, "\(loaded.report)")
        }
    },
    // A note's title is optional, so it came without a migration: an untitled note writes none,
    // as its fixture shows, and boards from before titles read as untitled notes.
    test("a note's title reads back as it was written") {
        let codec = BoardCodec(registry: try ShippedPlugins.registry())
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let document = CanvasDocument(shapes: [record(StickyNote(frame: frame, text: "Milk", title: "Groceries")), record(StickyNote(frame: frame))])
        let data = try codec.encode(document)
        expectEqual(try codec.decode(data).document, document)
        expectEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "\"title\"").count, 2, "the titled note's, alone")
    },
])
