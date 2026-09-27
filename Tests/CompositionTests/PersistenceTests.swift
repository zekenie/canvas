import Canvas
import CanvasTesting
import Composition
import Foundation
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
])
