@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Types
import Validation

// What the release costs, as a unit test with a thread-CPU bound (a one-off gesture, not a line of `./build.sh bench`): the fit of
// a port's release between two typed notes among many relationship types, and the landing of the drag between two types on a
// big board. The figures are the design's, for a release build; this suite runs in a debug one, which does the same work several
// times slower, so the bound each case holds is that figure times `debugFactor`, and the measured time is printed beside it.

#if DEBUG
private let debugFactor = 8.0
#else
private let debugFactor = 1.0
#endif

@MainActor let releaseCostTests = Suite("What the release costs", [
    test("releaseFit: a port's release between two typed notes, 100 relationship types among 1,000 types, fits in a millisecond") {
        let editor = try bondEditor()
        // 1,000 types, of which 100 are relationship types each with an end at two of the others.
        var types: [ShapeID] = []
        types.append(editor.addType(TypeSchemaProperty.starter, title: "Anchor", at: CGPoint(x: 0, y: 0)))
        let records = (0..<999).map { n -> AnyShapeRecord in
            typeRecord(TypeSchemaProperty.starter, title: "Type \(n)", at: CGPoint(x: CGFloat(n % 40) * 300, y: 400 + CGFloat(n / 40) * 100))
        }
        editor.transact { transaction in for record in records { transaction.insert(record) } }
        types += records.map(\.id)
        var relationships: [ShapeID] = []
        for n in 0..<100 {
            var record = typeRecord(TypeSchemaProperty.starter, title: "Relationship \(n)", at: CGPoint(x: CGFloat(n % 40) * 300, y: 6_000 + CGFloat(n / 40) * 100))
            record[RelationshipProperty.self] = true
            relationships.append(record.id)
            let from = types[2 * n % types.count], to = types[(2 * n + 1) % types.count]
            editor.transact { transaction in
                transaction.insert(record)
                transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: from, to: record.id))))
                transaction.insert(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: record.id, to: to))))
            }
        }
        // Relationship 7 runs between types 14 and 15: a note of each, and an arrow between them.
        let ann = editor.addInstance("Ann", of: [types[14]], at: CGPoint(x: 40, y: 8_000))
        let acme = editor.addInstance("Acme", of: [types[15]], at: CGPoint(x: 400, y: 8_000))
        let graph = try require(editor.relationships).graph
        expectEqual(graph.fitting(from: .note(ann), to: .note(acme)).taken, [relationships[7]])
        var times: [Duration] = []
        for _ in 0..<21 {
            let bond = editor.addBond(ann, acme)
            let elapsed = threadCPUTime { _ = editor.connectionDrawn(bond) }
            expectEqual(editor.typesOf(bond), [relationships[7]])
            times.append(elapsed)
        }
        let fit = threadCPUTime { for _ in 0..<100 { _ = graph.fitting(from: .note(ann), to: .note(acme)) } }
        times.sort()
        let median = times[times.count / 2].milliseconds
        print("  releaseFit: the whole release (the fit, the type given, the commit heard) \(String(format: "%.2f", median)) ms, the fit alone \(String(format: "%.3f", fit.milliseconds / 100)) ms (budget 1 ms for the fit)")
        expect(fit.milliseconds / 100 < 1.0 * debugFactor, "the fit took \(fit.milliseconds / 100) ms")
        expect(median < 1.0 * debugFactor, "the whole release took \(median) ms")
    },
    test("relationshipLanding: the drag between two types on a board of 10,000 shapes, 5,000 notes of each, is a step of 16 milliseconds") {
        @MainActor func slip(_ n: Int, of type: ShapeID, column: Int) -> AnyShapeRecord {
            slipRecord("n\(n)", of: [type], at: CGPoint(x: 40 + CGFloat(column) * 300 + CGFloat(n % 50) * 6_000, y: 1_000 + CGFloat(n / 50) * 100))
        }
        let person = typeRecord(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = typeRecord(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 900, y: 40))
        var shapes = [person, company]
        for n in 0..<5_000 { shapes.append(slip(n, of: person.id, column: 0)) }
        for n in 0..<5_000 { shapes.append(slip(n, of: company.id, column: 1)) }
        let bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: person.id, to: company.id)))
        shapes.append(bond)
        let editor = try bondEditor(file: CanvasFile(root: CanvasDocument(shapes: shapes)),
                                    more: [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()])
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        // The board has been shown: every shape's frame is kept, as a frame of the canvas leaves them.
        for record in editor.document.shapes { _ = editor.shapeContext.frame(of: record.id) }
        var made: ShapeID?
        let elapsed = threadCPUTime { made = editor.newRelationshipType(from: person.id, to: company.id, replacing: bond.id) }
        let id = try require(made)
        editor.closeCard()
        expectEqual(editor.relationships?.graph.sides(of: id).from.map(\.type), [person.id])
        print("  relationshipLanding: the release between two types on \(editor.document.shapes.count) shapes \(String(format: "%.1f", elapsed.milliseconds)) ms (budget 16)")
        expect(elapsed.milliseconds < 16 * debugFactor, "the landing took \(elapsed.milliseconds) ms")
    },
])

extension Duration {
    fileprivate var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
