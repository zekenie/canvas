import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Queries
import TestKit
import Titles
import Topology
import Types

// How far the file's types have come (`TypeIndex.graphRevision`, `RelationshipIndex.graphRevision`), what a query's facts of
// them (`TypeFacts`, `RelationshipFacts`) give a standing query to compare after each commit: a type's change moves it, a note's
// own words or list never do, since only that note reads them and the commit names it.

@MainActor let typeFactRevisionTests = Suite("Types' facts and how far they've come", [
    test("a type coming, renamed, building on another or going moves the revision; a note's words or its list don't") {
        let editor = try queryBondEditor()
        let types = try require(editor.types), relationships = try require(editor.relationships)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        var revision = types.graphRevision, ends = relationships.graphRevision
        editor.transact("Type") { $0.update(ann, as: Memo.self) { $0.props.text = MentionText(plain: "Ann, a person") } }
        expectEqual(types.graphRevision, revision, "a note's words")
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        expect(types.graphRevision != revision, "a type came")
        expect(relationships.graphRevision != ends, "and the relationships' graph, which holds the types, with it")
        revision = types.graphRevision
        editor.addTypeLink(company, to: ann)
        expectEqual(types.graphRevision, revision, "a note's list")
        editor.transact("Rename") { $0.update(person) { $0[TitleProperty.self] = "Human" } }
        expect(types.graphRevision != revision, "a type renamed")
        revision = types.graphRevision
        editor.addTypeLink(person, to: company)
        expect(types.graphRevision != revision, "a type's own list")
        revision = types.graphRevision
        editor.transact("Delete") { $0.delete([company]) }
        expect(types.graphRevision != revision, "a type gone")
        revision = types.graphRevision
        editor.transact { $0.moveBox(person, to: CGPoint(x: 300, y: 300)) }
        expectEqual(types.graphRevision, revision, "a move")
    },
    test("a standing :is-a asks a retyped note alone, and the whole file when a type changes") {
        let editor = try queryBondEditor()
        let queries = try require(editor.queries)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        let ann = editor.addInstance("Ann", of: [person])
        let acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 400, y: 400))
        let query = try queries.stand(#":is-a("Person")"#)
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [ann])
        let whole = queries.standingWholeAsks, shapes = queries.standingShapeAsks, walks = queries.universeWalks
        editor.addTypeLink(person, to: acme)
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [ann, acme])
        editor.transact("Type") { $0.update(ann, as: Memo.self) { $0.props.text = MentionText(plain: "Ann, a person") } }
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(queries.standingWholeAsks, whole, "a note retyped, and a note typed into: the note alone")
        expectEqual(queries.standingShapeAsks, shapes + 2)
        expectEqual(queries.universeWalks, walks, "walking no other shape")
        editor.addTypeLink(person, to: company)
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(queries.standingWholeAsks, whole + 1, "a type's own list: the whole file")
        expectEqual(query.matches, [ann, acme, company], "Company builds on Person: it and Acme are people")
    },
    test("the list of a shape another's list names moves the revision, and so does its going: :is-a follows the chain through it") {
        let editor = try queryBondEditor()
        let queries = try require(editor.queries), types = try require(editor.types)
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        let bob = editor.addInstance("Bob", of: [ann], at: CGPoint(x: 400, y: 400))
        let query = try queries.stand(#":is-a("Person")"#)
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [ann, bob], "Bob is a person through Ann, who is no type")
        @MainActor func fresh() throws -> Set<ShapeID> {
            let again = try queries.stand(#":is-a("Person")"#)
            defer { again.stop() }
            spinRunLoop(until: { again.isSettled }, timeout: 5)
            return again.matches
        }
        var revision = types.graphRevision
        editor.transact("Untype") { $0.update(ann) { $0[IsAProperty.self] = nil } }
        expect(types.graphRevision != revision, "Ann's list, which Bob's names")
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [], "Bob with her")
        expectEqual(query.matches, try fresh())
        editor.undo()
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [ann, bob], "put back")
        revision = types.graphRevision
        editor.transact("Untype") { $0.update(bob) { $0[IsAProperty.self] = nil } }
        expectEqual(types.graphRevision, revision, "Bob's list, which no list names")
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [ann])
        editor.undo()
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        revision = types.graphRevision
        editor.transact("Delete") { $0.delete([ann]) }
        expect(types.graphRevision != revision, "Ann gone, the chain from Bob ends at her")
        spinRunLoop(until: { query.isSettled }, timeout: 5)
        expectEqual(query.matches, [])
        expectEqual(query.matches, try fresh())
    },
])
