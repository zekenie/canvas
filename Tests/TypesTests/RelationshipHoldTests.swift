@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types

// A port's drag binds and unbinds its arrow at every hover, and a re-aim does the same. Counted as ends, a drag
// across a relationship type would make an end and unmake it each pass, laying out every instance of the end type
// twice. A drag session says which arrow it is changing (`Session.touching`); the relationships read it as it was
// before the drag, and count it at the release (`connectionReleased`). Over bonds, with a session of the tests' own,
// so none of it imports Connections.

/// A drag that changes one shape and does nothing else.
@MainActor private final class Dragging {
    let shape: ShapeID
    init(_ shape: ShapeID) { self.shape = shape }
}

extension Dragging: Session {
    var touching: Set<ShapeID> { [shape] }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

@MainActor private struct Hold {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, employment: ShapeID
    let heard: RelationshipHeard

    init() throws {
        editor = try bondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        employment = editor.addRelationshipType("Employment")
        for n in 0..<3 { editor.addInstance("Ann \(n)", of: [person], at: CGPoint(x: 40 + 300 * Double(n), y: 400)) }
        heard = RelationshipHeard(editor)
    }

    /// The arrow's end moved to `shape`, as a hover commits it.
    func hover(_ bond: ShapeID, over shape: ShapeID?, end: WritableKeyPath<Bond, ShapeID?> = \.to) {
        editor.transact("Hover") { $0.update(bond, as: Bond.self) { $0.props[keyPath: end] = shape } }
    }

    var index: RelationshipIndex { editor.relationships! }
}

@MainActor let relationshipHoldTests = Suite("A drag across a relationship type", [
    test("a drag from a type across a relationship type names no instance, makes no end and keeps nothing counted until the release; the release counts it, once") {
        let w = try Hold()
        let bond = w.editor.addBond(w.person, nil)
        w.heard.changes.removeAll()
        let drag = Dragging(bond)
        w.editor.session = drag
        w.hover(bond, over: w.employment)
        w.hover(bond, over: w.company)
        w.hover(bond, over: w.employment)
        expect(w.heard.changes.isEmpty, "a hover announces nothing: \(w.heard.changes.map(\.layout))")
        expectEqual(w.index.end(bond) == nil, true, "and makes no end")
        expectEqual(w.index.graph.sides(of: w.employment).from.count, 0)
        #if DEBUG
        expectEqual(w.index.heldConnections, [bond])
        #endif
        let revision = w.index.revision
        expectEqual(revision, w.index.revision)
        w.editor.connectionReleased(bond)
        expectEqual(w.heard.changes.count, 1, "the release counts it once")
        expect(w.heard.last?.layout.contains(w.person) == true, "the instances of Person are laid out: they gain the row")
        expect(w.heard.last?.arrows.contains(bond) == true)
        expectEqual(w.index.end(bond)?.type, w.employment)
        expectEqual(w.index.end(bond)?.side, .from)
        #if DEBUG
        expectEqual(w.index.heldConnections, [])
        #endif
        w.editor.session = nil
        w.editor.connectionReleased(bond)
        expectEqual(w.heard.changes.count, 1, "a connection no session is changing is not counted again")
    },
    test("a pass over a relationship type that ends elsewhere leaves nothing: the release of an arrow that is no end counts no end, and lays out nothing") {
        let w = try Hold()
        let bond = w.editor.addBond(w.person, nil)
        w.heard.changes.removeAll()
        w.editor.session = Dragging(bond)
        w.hover(bond, over: w.employment)
        w.hover(bond, over: w.company)
        w.editor.connectionReleased(bond)
        expectEqual(w.index.end(bond) == nil, true, "Person to Company is a plain arrow")
        expect(w.heard.changes.allSatisfy { $0.layout.isEmpty }, "no instance laid out: \(w.heard.changes.map(\.layout))")
        w.editor.session = nil
    },
    test("a released re-aim counts: an end re-aimed away is still an end while the drag goes on and is not once it is released") {
        let w = try Hold()
        let end = w.editor.addBond(w.person, w.employment)
        expectEqual(w.index.end(end)?.type, w.employment)
        w.heard.changes.removeAll()
        w.editor.session = Dragging(end)
        w.hover(end, over: w.company)
        w.hover(end, over: w.person)
        expect(w.heard.changes.isEmpty, "the re-aim's hovers announce nothing")
        expectEqual(w.index.end(end)?.type, w.employment, "it is what it was before the drag")
        expectEqual(w.index.graph.sides(of: w.employment).from.map(\.type), [w.person])
        w.hover(end, over: w.company)
        w.editor.connectionReleased(end)
        expect(w.index.end(end) == nil, "Person to Company is no end")
        expect(w.heard.last?.layout.contains(w.person) == true, "Person loses its row")
        expect(w.index.graph.sides(of: w.employment).isEmpty)
        w.editor.session = nil
    },
    test("Escape leaves nothing held: the arrow is deleted and told, a free release too, and nothing is counted") {
        let w = try Hold()
        for escape in [true, false] {
            let bond = w.editor.addBond(w.person, nil)
            w.heard.changes.removeAll()
            w.editor.session = Dragging(bond)
            w.hover(bond, over: w.employment)
            #if DEBUG
            expectEqual(w.index.heldConnections, [bond])
            #endif
            w.editor.transact("Delete") { $0.delete([bond]) }
            w.editor.connectionReleased(bond)
            #if DEBUG
            expectEqual(w.index.heldConnections, [], escape ? "Escape" : "a free release")
            #endif
            expect(w.heard.changes.allSatisfy { $0.layout.isEmpty }, "nothing laid out: \(w.heard.changes.map(\.layout))")
            expect(w.index.end(bond) == nil)
            w.editor.session = nil
        }
        expectEqual(w.index.graph.sides(of: w.employment).isEmpty, true)
    },
    test("a held arrow no session touches any more is counted by the next commit; a commit that changes more than the held arrow reads the rest") {
        let w = try Hold()
        let bond = w.editor.addBond(w.person, nil)
        w.editor.session = Dragging(bond)
        w.hover(bond, over: w.employment)
        w.editor.session = nil
        expect(w.index.end(bond) == nil, "held until something counts it")
        w.editor.addInstance("Another", of: [w.company], at: CGPoint(x: 700, y: 400))
        expectEqual(w.index.end(bond)?.type, w.employment, "the next commit has it counted")
        // While a session holds one arrow, a commit of another shape is read as ever.
        let held = w.editor.addBond(w.person, nil)
        w.editor.session = Dragging(held)
        w.hover(held, over: w.employment)
        let other = w.editor.addBond(w.employment, w.company)
        expectEqual(w.index.end(other)?.side, .to, "an end drawn meanwhile is counted at once")
        expectEqual(w.index.end(held) == nil, true, "the held one is not")
        w.editor.session = nil
    },
])
