import Canvas
import CanvasTesting
import CoreGraphics
import Types

// The shared types (`FieldFixtures`, in CanvasTesting) as an editor holds them: each a memo that is a type,
// Employee a Person.

extension CanvasEditor {
    /// Adds `types` (a note each), laid out in a column from the left, in one step.
    @discardableResult
    func addFieldTypes(_ types: [FieldFixtures.TypeText]) -> [ShapeID] {
        let records = types.enumerated().map { place, type in
            typeRecord(type.schema, words: type.words, title: type.title, at: CGPoint(x: 40 + Double(place) * 300, y: 40), id: type.id)
        }
        transact("Add Types") { transaction in records.forEach { transaction.insert($0) } }
        return types.map(\.id)
    }
}

/// An editor over `typeEditor()` with Person, Address, Employee (a Person) and Order added as types.
@MainActor func fieldEditor(scheduler: any Scheduler = ManualScheduler(), more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let editor = try typeEditor(scheduler: scheduler, more: more)
    editor.addFieldTypes([FieldFixtures.person, FieldFixtures.address, FieldFixtures.employee, FieldFixtures.order])
    editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
    return editor
}
