@_spi(Host) import Canvas
import CanvasTesting
import Colors
import Constraints
import CoreGraphics
import Foundation
import Queries
import TestKit
import Titles
import Types
import Validation

// What the suites of a type's constraints share: the types' plugins with Constraints, Queries and the words they use
// (`:is-a`), memos as the notes a type is made of and a corral as the frame of a type, titled, typed and constrainable
// as a frame is. Constraints knows no type: the plugins here are the ones Types gives it.

/// The corral as a frame: typed (`is`, `fieldValues`), titled and constrainable.
@MainActor private func frames() -> Contributor {
    Contributor(id: "constraint-frames") { r in
        r.optIn(Corral.self, to: IsAProperty.self)
        r.optIn(Corral.self, to: FieldValuesProperty.self)
        r.title(Corral.self, contents: false)
        r.constrainable(Corral.self)
        r.colorable(Memo.self)
    }
}

/// Every plugin the suites take: the types' (with memos), the corral as a frame, Queries and its words, Colors, Constraints and
/// the rule, and `TypeConstraintsPlugin`.
@MainActor func typeConstraintPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    typePlugins() + [CorralsPlugin(), frames(), QueriesPlugin(), TitleQueriesPlugin(), ValidationQueriesPlugin(), TypeQueriesPlugin(),
                     ColorsPlugin(), TypeColorsPlugin(), ConstraintsPlugin(), ConstraintValidationPlugin(), TypeConstraintsPlugin()] + more
}

/// A harness 800 × 600, the camera at the origin at 100%: view points are world units.
@MainActor func typeConstraintHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: typeConstraintPlugins(more))
    h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return h
}

let onlyTasks = Constraint(says: "only tasks", query: ":is-a(\"Task\")")
let noBugs = Constraint(says: "no bugs", query: ":not(:is-a(\"Bug\"))")
let onlyWork = Constraint(says: "only work", query: ":is-a(\"Work\")", reach: .descendants)

/// How often the frames were asked for the lists they have from elsewhere, by a second giver the test lists after Types'.
@MainActor final class ConstraintAsks {
    var count = 0

    var plugin: Contributor {
        Contributor(id: "asked") { r in
            r.forShapes(holding: ConstraintsProperty.self) { held in
                held.inheritedConstraints { [self] _, _ in
                    count += 1
                    return []
                }
            }
        }
    }
}

/// A constraint as its words, query and reach say it, without the shapes its titles were bound to when the writer wrote it.
func unbound(_ constraint: Constraint) -> Constraint {
    Constraint(says: constraint.says, query: constraint.query, reach: constraint.reach)
}

extension EditorHarness {
    var index: ConstraintIndex { editor.constraintIndex! }
    var writer: ConstraintWriter { editor.constraintWriter! }
    var types: TypeIndex { editor.types! }

    /// Runs the main run loop until every standing query the index holds has answered.
    func settle(file: StaticString = #fileID, line: UInt = #line) {
        let index = index
        expect(spinRunLoop(until: { index.isSettled }, timeout: 5, file: file, line: line), "the index settles", file: file, line: line)
    }

    /// A type titled `title`, built on `others`, holding `constraints` (written by Constraints' writer).
    @discardableResult
    func type(_ title: String, on others: [ShapeID] = [], _ constraints: [Constraint] = [], at origin: CGPoint = CGPoint(x: 40, y: 640)) -> ShapeID {
        let id = editor.addType(TypeSchemaProperty.starter, title: title, at: origin)
        if !others.isEmpty { editor.transact("Is") { $0.update(id) { $0[IsAProperty.self] = others.map(TypeLink.init) } } }
        for constraint in constraints { writer.add(constraint, to: .shape(id)) }
        return id
    }

    /// A corral titled `title`, of `types`, holding its own `constraints`, in `container` if one.
    @discardableResult
    func frame(_ title: String, _ rect: CGRect, of types: [ShapeID] = [], _ constraints: [Constraint] = [], in container: ShapeID? = nil) -> ShapeID {
        let id = ShapeID()
        var record = AnyShapeRecord(ShapeRecord(id: id, Corral(rect)))
        record[TitleProperty.self] = title
        if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
        if !constraints.isEmpty { record[ConstraintsProperty.self] = ConstraintList(constraints) }
        editor.transact { $0.insert(record.copy(as: id, container: container)) }
        return id
    }

    /// A memo of `types`, titled `title`, at `origin`, put in by an insert (made here: let in), in `container` if one.
    @discardableResult
    func note(_ title: String, of types: [ShapeID] = [], at origin: CGPoint, in container: ShapeID? = nil) -> ShapeID {
        let record = instanceRecord("", of: types, title: title, at: origin)
        editor.transact { $0.insert(record.copy(as: record.id, container: container)) }
        return record.id
    }

    /// Makes `shape` built on `others`: its own `is` list.
    func retype(_ shape: ShapeID, to others: [ShapeID]) {
        editor.transact("Is") { $0.update(shape) { $0[IsAProperty.self] = others.isEmpty ? nil : others.map(TypeLink.init) } }
    }

    /// The sources a place has from elsewhere, by the types that hold them.
    func given(to frame: ShapeID) -> [ShapeID] { index.sources(of: .shape(frame)).map(\.holder) }

    /// What Validation says of a shape, as the engine checks it now.
    func issues(of id: ShapeID) -> [String] {
        (editor.validation?.results[id]?.issues ?? []).map(\.message)
    }

    func origin(of id: ShapeID) -> CGPoint? { editor.document[id]?.box?.origin }

    /// Drags a shape from one point to another with the select tool, and lets go.
    func drop(from start: CGPoint, to end: CGPoint) {
        editor.setTool("select")
        press(at: start)
        drag(to: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
        drag(to: end)
        release()
    }
}
