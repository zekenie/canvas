import Canvas
import CanvasTesting
import Colors
import CoreGraphics
import Palette
import TestKit
import Validation

/// A harness with Validation and Colors' rule.
@MainActor private func validatedHarness() throws -> EditorHarness {
    try colorHarness([ValidationPlugin(), ColorValidationPlugin()])
}

@MainActor private func issues(of id: ShapeID, in h: EditorHarness) -> [ValidationIssue] {
    h.editor.validation?.result(for: id)?.issues ?? []
}

@MainActor let colorValidationTests = Suite("A color the file lacks", [
    test("a shape whose own color is a name the file lacks is warned, about its color") {
        let h = try validatedHarness()
        let sheet = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let pane = h.add(Pane(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.setColor(.named("brand"), of: [sheet])
        let found = issues(of: sheet, in: h)
        expectEqual(found.map(\.message), ["Color “brand” isn’t in this file."])
        expectEqual(found.first?.field, "color")
        expectEqual(found.first?.severity, .warning)
        expectEqual(issues(of: pane, in: h), [], "a shape with no color of its own isn't")
    },
    test("a hex value and a built-in name, in any case, never warn") {
        let h = try validatedHarness()
        let a = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Pane(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.setColor(.value(RGB(hex: 0x123456)), of: [a])
        h.editor.setColor(.blue, of: [b])
        expectEqual(issues(of: a, in: h), [])
        expectEqual(issues(of: b, in: h), [])
        h.editor.transact("Spell") { $0.update(b) { $0[ColorProperty.self] = .named("BLUE") } }
        expectEqual(issues(of: b, in: h), [])
    },
    test("the warning is gone when the color is changed or taken away, and back with an undo") {
        let h = try validatedHarness()
        let a = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.setColor(.named("brand"), of: [a])
        expectEqual(issues(of: a, in: h).count, 1)
        h.editor.setColor(.teal, of: [a])
        expectEqual(issues(of: a, in: h), [])
        h.editor.undo()
        expectEqual(issues(of: a, in: h).count, 1)
        h.editor.setColor(nil, of: [a])
        expectEqual(issues(of: a, in: h), [])
    },
    test("when the file's colors change, a shape that names one is checked again with no commit to it") {
        let h = try validatedHarness()
        let a = h.add(Sheet(CGRect(x: 0, y: 0, width: 100, height: 100)))
        h.editor.setColor(.named("brand"), of: [a])
        expectEqual(issues(of: a, in: h).count, 1)
        expect(h.editor.defineColor(named: "Brand", value: RGB(hex: 0x0055FF)))
        expectEqual(issues(of: a, in: h), [], "the file has it now, whatever the case")
        expectEqual(h.editor.document[a]?.ownColor, .named("brand"), "the shape wasn't written")
        h.editor.undo()
        expectEqual(issues(of: a, in: h).map(\.message), ["Color “brand” isn’t in this file."])
        h.editor.redo()
        expectEqual(issues(of: a, in: h), [])
        // Another value is the same name: nothing to warn of, before or after.
        expect(h.editor.setColorValue(of: "Brand", to: RGB(hex: 0x00AA55)))
        expectEqual(issues(of: a, in: h), [])
        expect(h.editor.removeColor("Brand"))
        expectEqual(issues(of: a, in: h), [], "removed, the shape holds its value")
    },
])
