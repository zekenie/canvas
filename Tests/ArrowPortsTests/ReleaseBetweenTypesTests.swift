import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import DetailPanel
import Draw
import Geometry
import Mentions
import Selection
import TableOfContents
import TestKit
import Titles
import Types

// The release of a port's drag between two types: the selection and the bytes an Undo returns, a type dragged onto itself,
// the room the new relationship type is given among other notes, and an end re-aimed from one relationship type to another.
// (The name typed in the pill, and what a press, a delete or the host's save point do to it, are the shipped note's: NotePillTests.)

@MainActor private struct ReleaseBoard {
    let h: EditorHarness
    let person: ShapeID, company: ShapeID, employment: ShapeID, ann: ShapeID, acme: ShapeID

    static let annFrame = CGRect(x: 80, y: 80, width: 200, height: 200)
    static let acmeFrame = CGRect(x: 460, y: 80, width: 200, height: 200)
    static let personFrame = CGRect(x: 80, y: 700, width: 200, height: 200)
    static let companyFrame = CGRect(x: 900, y: 700, width: 200, height: 200)
    static let employmentFrame = CGRect(x: 460, y: 1000, width: 200, height: 200)

    init(ends: Bool = true) throws {
        h = try EditorHarness(plugins: PortBoard.plugins(more: [DetailPanelPlugin(), DrawPlugin(), PortEdgesPlugin(), SlabsPlugin()]))
        h.editor.viewportDidResize(to: CGSize(width: 1400, height: 1400))
        func slab(_ frame: CGRect, title: String? = nil, schema: String? = nil, relationship: Bool = false, of types: [ShapeID] = []) -> AnyShapeRecord {
            var record = ShapeRecord(Slab(frame))
            if let title { record[TitleProperty.self] = title }
            if let schema { record[TypeSchemaProperty.self] = SchemaText(schema) }
            if relationship { record[RelationshipProperty.self] = true }
            if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
            return AnyShapeRecord(record)
        }
        let people = slab(Self.personFrame, title: "Person", schema: TypeSchemaProperty.starter)
        let companies = slab(Self.companyFrame, title: "Company", schema: TypeSchemaProperty.starter)
        let employments = slab(Self.employmentFrame, title: "Employment", schema: TypeSchemaProperty.starter, relationship: true)
        let ann = slab(Self.annFrame, title: "Ann", of: [people.id]), acme = slab(Self.acmeFrame, title: "Acme", of: [companies.id])
        h.editor.transact { transaction in
            for record in [people, companies, employments, ann, acme] { transaction.insert(record) }
        }
        (person, company, employment, self.ann, self.acme) = (people.id, companies.id, employments.id, ann.id, acme.id)
        if ends {
            h.editor.transact { transaction in
                transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(people.id), end: binding(employments.id)))))
                transaction.insert(AnyShapeRecord(ShapeRecord(Arrow(start: binding(employments.id), end: binding(companies.id)))))
            }
        }
        h.editor.undoHistory.seal()
        h.editor.replaceDocument(with: h.editor.document)
    }

    var arrows: [ShapeRecord<Arrow>] { h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }

    func drag(from frame: CGRect, to point: CGPoint, release: Bool = true) {
        h.move(to: CGPoint(x: frame.midX, y: frame.midY))
        h.move(to: CGPoint(x: frame.maxX + 12, y: frame.midY))
        h.press()
        h.drag(to: point, speed: fast)
        if release { h.release() }
    }

    func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    func bytes() throws -> Data { try BoardCodec(registry: h.editor.registry).encode(h.editor.file) }
}

@MainActor let releaseBetweenTypesTests = Suite("The release of a drag between two types", [
    test("selection and bytes: a prior selection comes back with one Undo after a drag between two types, and the file bytes are the same") {
        let w = try ReleaseBoard()
        w.h.editor.selection = w.ann
        w.h.editor.undoHistory.seal()
        let startBytes = try w.bytes()
        let startFile = w.h.editor.file
        let startSelection = w.h.editor.selectedShapeIDs
        w.drag(from: ReleaseBoard.personFrame, to: w.center(ReleaseBoard.companyFrame))
        let made = try require(w.h.editor.document.shapes.last { $0[RelationshipProperty.self] == true && $0.id != w.employment }).id
        expect(w.h.editor.card == nil, "a slab has no editing view, and no card asks a name")
        let namedBytes = try w.bytes()
        w.h.editor.undo()
        expectEqual(w.h.editor.selectedShapeIDs, startSelection, "selection restored")
        expect(w.h.editor.file == startFile, "whole file ==")
        expect(try w.bytes() == startBytes, "bytes")
        expect(!w.h.editor.canUndo)
        w.h.editor.redo()
        expect(try w.bytes() == namedBytes, "redo bytes")
        expectEqual(w.h.editor.selectedShapeIDs, [made])
    },
    test("a type dragged onto itself is related to itself: a relationship type, an arrow into it and one out of it bent apart, no arrow from the type to itself, one step; one Undo returns the bytes") {
        let w = try ReleaseBoard()
        let editor = w.h.editor
        let start = try w.bytes()
        let known = Set(editor.document.shapes.map(\.id))
        w.drag(from: ReleaseBoard.personFrame, to: w.center(ReleaseBoard.personFrame))
        let made = try require(editor.document.shapes.first { !known.contains($0.id) && $0[RelationshipProperty.self] == true }).id
        let arrows = w.arrows.filter { !known.contains($0.id) }
        expectEqual(arrows.count, 2, "two arrows, never one from Person to itself")
        let out = try require(arrows.first { $0.props.start.binding?.shapeID == w.person })
        let back = try require(arrows.first { $0.props.end.binding?.shapeID == w.person })
        expectEqual(out.props.end.binding?.shapeID, made)
        expectEqual(back.props.start.binding?.shapeID, made)
        expect(out.props.bend != back.props.bend, "bent apart")
        expectEqual(editor.relationships?.graph.relationshipTypes(joining: w.person, and: w.person), [made])
        expectEqual(editor.selectedShapeIDs, [made])
        expectEqual(editor.undoHistory.undoName, TypesStyle.newRelationshipType)
        editor.undo()
        expect(try w.bytes() == start, "one Undo returns the bytes")
        expect(!editor.canUndo)
    },
    test("a relationship type, or a note that is no type, dragged onto itself makes nothing and leaves no step") {
        for frame in [ReleaseBoard.employmentFrame, ReleaseBoard.annFrame] {
            let w = try ReleaseBoard()
            let before = w.h.editor.document
            w.drag(from: frame, to: w.center(frame))
            expectEqual(w.h.editor.document, before, "nothing is made from \(frame)")
            expectEqual(w.h.editor.undoHistory.undoName, nil, "and no step")
            expect(w.h.editor.card == nil)
        }
    },
    test("a drag from a type that passes over the type itself, binding there, and goes on to another type relates the two, not the type to itself") {
        let w = try ReleaseBoard(ends: false)
        let editor = w.h.editor
        let known = Set(editor.document.shapes.map(\.id))
        w.drag(from: ReleaseBoard.personFrame, to: w.center(ReleaseBoard.personFrame), release: false)
        w.h.wait(400)
        expectEqual(editor.hintedShapeID, w.person, "bound back to Person, and held there past the precise timer")
        w.h.drag(to: w.center(ReleaseBoard.companyFrame), speed: fast)
        expectEqual(editor.hintedShapeID, w.company)
        w.h.release()
        let made = try require(editor.document.shapes.first { !known.contains($0.id) && $0[RelationshipProperty.self] == true }).id
        let graph = try require(editor.relationships?.graph)
        expectEqual(graph.relationshipTypes(joining: w.person, and: w.company), [made])
        expectEqual(graph.relationshipTypes(joining: w.person, and: w.person), [], "Person is not related to itself")
        expectEqual(w.arrows.filter { !known.contains($0.id) }.count, 2)
    },
    test("an end re-aimed from one relationship type to another: the old loses it and the new gains it at the release only") {
        let h = try EditorHarness(plugins: PortBoard.plugins(more: [DetailPanelPlugin(), DrawPlugin(), PortEdgesPlugin(), SlabsPlugin()]))
        h.editor.viewportDidResize(to: CGSize(width: 1400, height: 1400))
        func slab(_ frame: CGRect, title: String, schema: Bool = true, relationship: Bool = false, of types: [ShapeID] = []) -> AnyShapeRecord {
            var record = ShapeRecord(Slab(frame))
            record[TitleProperty.self] = title
            if schema { record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
            if relationship { record[RelationshipProperty.self] = true }
            if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
            return AnyShapeRecord(record)
        }
        let person = slab(CGRect(x: 80, y: 700, width: 200, height: 200), title: "Person")
        let employment = slab(CGRect(x: 460, y: 1000, width: 200, height: 200), title: "Employment", relationship: true)
        let mentorship = slab(CGRect(x: 900, y: 1000, width: 200, height: 200), title: "Mentorship", relationship: true)
        let ann = slab(CGRect(x: 80, y: 80, width: 200, height: 200), title: "Ann", schema: false, of: [person.id])
        h.editor.transact { for r in [person, employment, mentorship, ann] { $0.insert(r) } }
        let arrow = AnyShapeRecord(ShapeRecord(Arrow(start: binding(person.id), end: binding(employment.id))))
        h.editor.transact { $0.insert(arrow) }
        h.editor.undoHistory.seal()
        h.editor.replaceDocument(with: h.editor.document)
        let index = try require(h.editor.relationships)
        expectEqual(index.end(arrow.id)?.type, employment.id)
        expectEqual(index.graph.sides(of: employment.id).from.map(\.type), [person.id])
        h.editor.selection = arrow.id
        let geometry = try require(h.editor.arrowGeometry(of: arrow.id))
        // An end's handle at the relationship type is where its line meets the type, not the type's middle.
        h.move(to: h.editor.camera.toView(geometry.end))
        h.press()
        h.drag(to: CGPoint(x: 1000, y: 1100), speed: fast)
        expectEqual(index.end(arrow.id)?.type, employment.id, "still an end of Employment while dragging")
        h.release()
        expectEqual(h.editor.document[arrow.id]?.typed(as: Arrow.self)?.props.end.binding?.shapeID, mentorship.id)
        expectEqual(index.end(arrow.id)?.type, mentorship.id, "now Mentorship's")
        expectEqual(index.graph.sides(of: employment.id).from.count, 0, "Employment lost it")
        expectEqual(index.graph.sides(of: mentorship.id).from.map(\.type), [person.id], "Mentorship gained it")
        #if DEBUG
        expectEqual(index.heldConnections, [])
        #endif
        h.editor.undo()
        expectEqual(index.end(arrow.id)?.type, employment.id, "undo returns")
        expectEqual(index.graph.sides(of: mentorship.id).from.count, 0)
    }
])
