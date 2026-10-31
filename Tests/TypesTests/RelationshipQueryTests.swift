@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Queries
import TestKit
import Titles
import Topology
import Types
import Validation

// `:misfit`, in Types: an arrow whose ends do not fit its relationship type, from the one `fit` the check calls.
// Over bonds.

@MainActor private var sharedQueryRegistry: Registry?

/// An editor with bonds and the query engine. With no more plugins it is over one registry for them all, as `bondEditor` is.
@MainActor func queryBondEditor(file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let queries: [any CanvasPlugin] = [QueriesPlugin(), TitleQueriesPlugin(), ValidationQueriesPlugin(), TypeQueriesPlugin()]
    guard more.isEmpty else { return try bondEditor(file: file, more: queries + more) }
    if sharedQueryRegistry == nil { sharedQueryRegistry = try bondRegistry(more: queries) }
    return bondEditor(registry: try require(sharedQueryRegistry), file: file ?? CanvasFile(root: CanvasDocument()))
}

/// The shapes a query matches, as a set.
@MainActor func queried(_ text: String, on editor: CanvasEditor, properties: QueryRequest.Properties = .none) throws -> QueryResult {
    let queries = try require(editor.queries)
    return try awaitResult { try await queries.run(QueryRequest(text, limit: QueryRequest.every, properties: properties)) }
}

@MainActor private struct World {
    let editor: CanvasEditor
    let person: ShapeID, company: ShapeID, layer: ShapeID, employment: ShapeID
    let ann: ShapeID, acme: ShapeID, foundation: ShapeID
    let job: ShapeID

    init() throws {
        editor = try queryBondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 200))
        layer = editor.addType(TypeSchemaProperty.starter, title: "Layer", at: CGPoint(x: 40, y: 360))
        employment = editor.addRelationshipType("Employment")
        editor.addBond(person, employment)
        editor.addBond(employment, company)
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 500, y: 400))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 800, y: 400))
        foundation = editor.addInstance("foundation", of: [layer], at: CGPoint(x: 800, y: 700))
        job = editor.addBond(ann, acme, of: [employment])
    }

    func misfits(_ text: String = "bond:misfit") throws -> Set<ShapeID> { Set(try queried(text, on: editor).rows.map(\.id)) }
}

@MainActor let misfitWordTests = Suite(":misfit in canvas query", [
    test("an arrow whose end does not fit its relationship type is a misfit, one that fits is not, and the word names no kind of arrow") {
        let w = try World()
        expectEqual(try w.misfits(), [])
        let wrong = w.editor.addBond(w.ann, w.foundation, of: [w.employment])
        expectEqual(try w.misfits(), [wrong])
        expectEqual(try w.misfits(":misfit"), [wrong], "the word alone: nothing else is an arrow with a type that misfits")
        expectEqual(try w.misfits(#"bond:is-a("Employment"):misfit"#), [wrong], "narrowed to the type")
        expectEqual(try w.misfits(#"bond:is-a("Layer"):misfit"#), [])
        w.editor.removeTypeLink(w.company, from: w.acme)
        expectEqual(try w.misfits(), [wrong, w.job], "Acme is no Company now")
        w.editor.undo()
        expectEqual(try w.misfits(), [wrong])
    },
    test("a type that builds on an end fits, a side with no end fits anything, and an arrow with no relationship type is no misfit") {
        let w = try World()
        let employee = w.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        let bo = w.editor.addInstance("Bo", of: [employee], at: CGPoint(x: 500, y: 700))
        let boJob = w.editor.addBond(bo, w.acme, of: [w.employment])
        expectEqual(try w.misfits(), [boJob], "an Employee is no Person yet")
        w.editor.addTypeLink(w.person, to: employee)
        expectEqual(try w.misfits(), [], "it builds on Person")
        let open = w.editor.addRelationshipType("Mentorship", at: CGPoint(x: 400, y: 200))
        let free = w.editor.addBond(w.foundation, w.ann, of: [open])
        expectEqual(try w.misfits(), [], "no end on either side: anything")
        let plain = w.editor.addBond(w.ann, w.foundation)
        let plainType = w.editor.addBond(w.ann, w.foundation, of: [w.person])
        expect(free != plain && plain != plainType)
        expectEqual(try w.misfits(), [], "an arrow of no relationship type, and one of a plain type, judge nothing")
    },
    test("an end that cannot be read gives no verdict, as the check gives none: a free end, a pill that is not admitted, one that stands for several shapes; an admitted pill is judged through") {
        let w = try World()
        let free = w.editor.addBond(w.ann, nil, of: [w.employment])
        let hidden = w.editor.addRelay(standingFor: [w.foundation], says: "foundation", at: CGPoint(x: 40, y: 800))
        let viaHidden = w.editor.addBond(w.ann, hidden, of: [w.employment])
        expect(free != viaHidden)
        expectEqual(try w.misfits(), [], "free, and a pill the kind may not stand for")
        expectEqual(w.editor.relationships?.reading(ofEnd: hidden), .notAdmitted(w.foundation, needs: "open"))
        w.editor.open(w.foundation)
        expectEqual(try w.misfits(), [viaHidden], "the pill stands for a Layer once its note is open: the arrow is a misfit, as the check says")
        expectEqual(w.editor.issues(viaHidden).filter { $0.severity == .error }.count, 1)
        let several = w.editor.addRelay(standingFor: [w.foundation, w.acme], says: "both", at: CGPoint(x: 40, y: 860))
        w.editor.open(w.acme)
        let viaSeveral = w.editor.addBond(w.ann, several, of: [w.employment])
        expectEqual(try w.misfits(), [viaHidden], "a pill that stands for two shapes is read as a query")
        expect(w.editor.issues(viaSeveral).allSatisfy { $0.severity != .error })
    },
    test("the word reads only the file, and the rows of arrow:misfit:invalid say where") {
        let w = try World()
        let wrong = w.editor.addBond(w.ann, w.foundation, of: [w.employment])
        let queries = try require(w.editor.queries)
        let plan = try queries.check("bond:misfit")
        expectEqual(plan.editorWords, [])
        expect(plan.readsOnlyTheFile, "a word of the file")
        let rows = try queried("bond:misfit:invalid", on: w.editor, properties: .all).rows
        expectEqual(rows.map(\.id), [wrong])
        expectEqual(rows.first?.problems?.map(\.field), ["to"])
        expectEqual(rows.first?.problems?.map(\.problemClass), ["wrong"])
        expectEqual(rows.first?.problems?.map(\.message), ["Employment runs to a Company. “foundation” is a Layer."])
        let plainRows = try queried("bond:misfit", on: w.editor, properties: .all).rows
        expect(plainRows.first?.problems == nil, "the word lists; :invalid says why")
    },
])
