import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Foundation
import Selection
import SwiftUI
import TestKit
import Titles
import Types

// An instance's Types tab: its types in order, each a row that goes to the type, with a minus that
// takes the shape out of it; shown while it is some.

extension TypePanelWindow {
    /// A shape that has no JSON Schema, selected, its panel up (`show` waits for the JSON).
    func select(_ record: AnyShapeRecord) -> ShapeID {
        editor.transact { $0.insert(record) }
        editor.selection = record.id
        window.settle()
        return record.id
    }
}

@MainActor let typesPanelTests = Suite("An instance's panel", [
    test("a shape that is some has the Types tab, one section, after its own tabs; a shape that is none has none; it comes and goes with the list") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        let bare = editor.addInstance("Bare", of: [], at: CGPoint(x: 600, y: 400))
        @MainActor func tabs(_ id: ShapeID) throws -> [String] {
            try require(editor.detailPanel?.layout(for: try require(editor.document[id]))).tabs.map(\.title)
        }
        expectEqual(try tabs(ann), ["Types"])
        expectEqual(try tabs(person), ["Schema"])
        expectEqual(try tabs(bare), [])
        expectEqual(try require(editor.detailPanel?.layout(for: try require(editor.document[ann]))).sections(in: .of(TypesTab.self)).map(\.section), ["types"])
        editor.addTypeLink(person, to: bare)
        expectEqual(try tabs(bare), ["Types"])
        editor.removeTypeLink(person, from: bare)
        expectEqual(try tabs(bare), [])
        // A type with a supertype has both, its Types before its Schema.
        editor.addTypeLink(person, to: editor.addType(TypeSchemaProperty.starter, title: "Employee"))
        let employee = try require(editor.document.shapes.first { editor.registry.title(of: $0) == "Employee" })
        expectEqual(try tabs(employee.id), ["Types", "Schema"])
    },
    test("each type is a row in the order of its list: a click goes to it, the minus removes it in one step, Remove Type") {
        let panel = try TypePanelWindow()
        let person = panel.editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 700, y: 40))
        let employee = panel.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 700, y: 300))
        let ann = panel.select(instanceRecord("Ann", of: [person, employee]))
        panel.window.spin { panel.buttons.count == 4 }
        // Row by row: the type, then its minus.
        let buttons = panel.buttons.sorted { panel.frame(of: $0).minY < panel.frame(of: $1).minY }
        expectEqual(buttons.count, 4)
        buttons[0].performClick(nil)
        panel.window.spin { panel.editor.selectedShapeIDs == [person] }
        panel.editor.selection = ann
        panel.window.spin { panel.buttons.count == 4 }
        let minus = panel.buttons.sorted { panel.frame(of: $0).minY < panel.frame(of: $1).minY }[3]
        minus.performClick(nil)
        panel.window.spin { panel.editor.typesOf(ann) == [person] }
        expectEqual(panel.editor.undoHistory.undoName, "Remove Type")
        panel.window.spin { panel.buttons.count == 2 }
    },
    test("on a read-only shape the rows still go to their types, and the minus is off") {
        let panel = try TypePanelWindow(more: [FreezingPlugin()])
        let person = panel.editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 700, y: 40))
        let ann = panel.select(instanceRecord("Ann", of: [person]))
        panel.window.spin { panel.buttons.count == 2 }
        panel.editor.freeze([ann])
        panel.window.spin { panel.buttons.filter(\.isEnabled).count == 1 }
        let buttons = panel.buttons.sorted { panel.frame(of: $0).minY < panel.frame(of: $1).minY }
        expect(buttons[0].isEnabled && !buttons[1].isEnabled)
    },
])
