@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import Queries
import TestKit
import Titles
import Types

// What the agents' side of relationships costs, each held to a constant factor of the same work without them, in a
// thread's CPU time (never the wall clock): what `--ask` is told of 200 relationship types, `:misfit` over 10,000
// shapes and 2,500 relationships, and a run of 2,500 typed edges. The bounds are about twice what is measured (1.5 times for
// --ask, 2.5 for a run, whose untyped baseline is itself more than linear): they hold the shape of the
// cost (linear, no square), not a figure; `./build.sh bench` holds the paths a frame or a keystroke takes.

@MainActor let relationshipCostTests = Suite("What relationships cost an agent", [
    test("askFieldsRelationships: what --ask is told of 200 relationship types costs about what 200 plain types cost") {
        @MainActor func told(relationships: Bool) throws -> Duration {
            let editor = try bondEditor()
            let plain = editor.addType(#"{"type": "object", "properties": {"name": {"type": "string"}}}"#, title: "Thing", at: CGPoint(x: 40, y: 40))
            var shapes: [AnyShapeRecord] = []
            for index in 0..<200 {
                var record = slipTypeRecord(#"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}, "note": {"type": "string"}}}"#,
                                            title: "Rel \(index)", at: CGPoint(x: 400 + Double(index % 20) * 10, y: 40 + Double(index / 20) * 10))
                if relationships { record[RelationshipProperty.self] = true }
                shapes.append(record)
                if relationships {
                    shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: plain, to: record.id, text: MentionText(plain: "row \(index)")))))
                    shapes.append(AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: record.id, to: plain))))
                }
            }
            editor.transact { transaction in for record in shapes { transaction.insert(record) } }
            // Each time after a type changes, so the lines are made again.
            var least = Duration.seconds(1000)
            var text = ""
            for round in 0..<5 {
                editor.transact { $0.update(plain) { $0[TitleProperty.self] = "Thing \(round)" } }
                least = min(least, threadCPUTime { text = editor.fileFields?.text(for: "which things") ?? "" })
            }
            if relationships {
                expect(text.contains("Rel 0 relates Thing 4 to Thing 4: since (date), note (text); rows: Thing 4 \"row 0\""), "told: \(text.prefix(300))")
            }
            return least
        }
        let plain = try told(relationships: false), related = try told(relationships: true)
        expect(related < plain * 2 + .milliseconds(3), "200 relationship types took \(related), 200 plain types \(plain)")
    },
    test("misfitQuery10k: :misfit over 10,000 shapes and 2,500 relationships is the cost of a query over their types") {
        let editor = try queryBondEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        var shapes: [AnyShapeRecord] = []
        var people: [ShapeID] = [], companies: [ShapeID] = []
        for index in 0..<7_500 {
            let isPerson = index % 2 == 0
            let record = instanceRecord("n\(index)", of: [isPerson ? person : company], at: CGPoint(x: Double(index % 100) * 10, y: 400 + Double(index / 100) * 10))
            shapes.append(record)
            if isPerson { people.append(record.id) } else { companies.append(record.id) }
        }
        // Employments from a person to a company, and every 25th the wrong way round: a misfit.
        var misfits: Set<ShapeID> = []
        for index in 0..<2_500 {
            var arrow = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: people[index % people.count], to: companies[index % companies.count])))
            if index % 25 == 0 {
                arrow = AnyShapeRecord(ShapeRecord(id: arrow.id, Bond(from: companies[index % companies.count], to: people[index % people.count])))
                misfits.insert(arrow.id)
            }
            arrow[IsAProperty.self] = [TypeLink(employment)]
            shapes.append(arrow)
        }
        editor.transact { transaction in for record in shapes { transaction.insert(record) } }
        var found: Set<ShapeID> = []
        var misfitTime = Duration.seconds(1000), isATime = Duration.seconds(1000)
        for _ in 0..<3 {
            misfitTime = min(misfitTime, threadCPUTime { found = Set((try? queried("bond:misfit", on: editor).rows.map(\.id)) ?? []) })
            isATime = min(isATime, threadCPUTime { _ = try? queried(#"bond:is-a("Employment")"#, on: editor) })
        }
        expectEqual(found, misfits, "the 100 that run the wrong way")
        expect(misfitTime < isATime * 3 + .milliseconds(20), ":misfit took \(misfitTime), the :is-a query \(isATime)")
    },
    test("drawRelationshipRun: 2,500 typed edges in one run cost a constant factor of the same run untyped") {
        @MainActor func ran(typed: Bool) throws -> Duration {
            let editor = try typeEditorWithDraw()
            let a = editor.addType(TypeSchemaProperty.starter, title: "A", at: CGPoint(x: 40, y: 40))
            let b = editor.addType(TypeSchemaProperty.starter, title: "B", at: CGPoint(x: 40, y: 200))
            if typed {
                let relation = editor.addRelationshipType("Rel")
                editor.addBond(a, relation)
                editor.addBond(relation, b)
            }
            var shapes: [AnyShapeRecord] = []
            for index in 0..<50 {
                shapes.append(instanceRecord("a\(index)", of: [a], title: "a\(index)", at: CGPoint(x: 400 + Double(index) * 20, y: 40)))
                shapes.append(instanceRecord("b\(index)", of: [b], title: "b\(index)", at: CGPoint(x: 400 + Double(index) * 20, y: 400)))
            }
            editor.transact { transaction in for record in shapes { transaction.insert(record) } }
            var script: [String] = []
            for i in 0..<50 { for j in 0..<50 { script.append(#"edge "a\#(i)" -> "b\#(j)"\#(typed ? #" is: "Rel""# : "")"#) } }
            let text = script.joined(separator: "\n")
            var failure: String?
            let took = threadCPUTime {
                do { _ = try draw(script: text, dryRun: false, reveal: false, program: "canvas", in: editor) } catch { failure = "\(error)" }
            }
            expectEqual(failure, nil)
            expectEqual(editor.document.shapes.filter { $0.typed(as: Bond.self) != nil }.count, typed ? 2_502 : 2_500)
            return took
        }
        let untyped = try ran(typed: false), typed = try ran(typed: true)
        expect(typed < untyped * 3 + .milliseconds(100), "2,500 typed edges took \(typed), the same untyped \(untyped)")
    },
])
