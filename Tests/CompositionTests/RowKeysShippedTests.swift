import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import Geometry
import Mentions
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Types

// The keys of a relation row's pills, on the shipped list with real notes and arrows: a held Backspace takes one
// relationship away and no more; Return and Space on a focused pill go to its note, as a click on it does; the row and its
// pills are named for VoiceOver.

extension Minute {
    /// The Feature note edited in its `in` row with two relationships, the row focused, no pill yet.
    func twoPills() throws -> (made: ShapeID, ends: [ShapeID]) {
        let made = try nameTheType()
        var ends: [ShapeID] = []
        for (order, y) in [(2.0, 800.0), (3.0, 1050.0)] {
            var note = ShapeRecord(StickyNote(frame: CGRect(x: 1000, y: y, width: 200, height: 200), text: ""))
            note[IsAProperty.self] = [TypeLink(layer)]
            note[FieldValuesProperty.self] = FieldValues(["order": .number(order)])
            let record = AnyShapeRecord(note)
            editor.transact { $0.insert(record) }
            ends.append(record.id)
        }
        let row0 = try require(editor.relationships?.rows(for: [feature], isType: false).first)
        for end in ends { _ = try require(editor.relate(featureNote, to: end, in: row0)) }
        expectEqual(try pills(of: featureNote, "in").count, 2)
        editor.undoHistory.seal()
        let row = try require(rows.rows(of: featureNote).first { $0.name == "in" })
        editor.selection = featureNote
        expect(editor.beginEditing(featureNote, at: CGPoint(x: row.valueRect.minX + 8, y: row.rect.midY)))
        h.scheduler.advance(by: .zero)
        window.pressEscape()
        expectEqual(rowsView?.focusedRow, "in")
        return (made, ends)
    }
}

@MainActor let rowKeysShippedTests = Suite("The keys of a note's rows, shipped", [
    test("a held Backspace on a relation row with two pills focuses the last and takes at most one relationship away") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.twoPills()
        let driver = KeyDriver(m.window)
        driver.hold(.delete, repeats: 8)
        expectEqual(try m.pills(of: m.featureNote, "in").count, 2, "one press focuses the pill: the repeats do nothing")
        expectEqual(m.rowsView?.focusedPill, 1)
        m.editor.undoHistory.seal()
        driver.hold(.delete, repeats: 8)
        expectEqual(try m.pills(of: m.featureNote, "in").count, 1, "the second press, held, takes one away")
        expectEqual(m.editor.undoHistory.undoName, "Remove Relationship")
    },
    test("Return, and Space, on a focused pill go to its note, as a click on it does; Return with no pill focused opens the row's card") {
        for key in [Chord.return, Chord.space] {
            let m = try Minute()
            defer { m.close() }
            let (_, ends) = try m.twoPills()
            let driver = KeyDriver(m.window)
            driver.send(.left)
            expectEqual(m.rowsView?.focusedPill, 1)
            driver.send(.left)
            expectEqual(m.rowsView?.focusedPill, 0)
            driver.send(key)
            m.h.scheduler.advance(by: .zero)
            expectEqual(m.editor.editingShapeID, nil, "\(key): editing ended to go to the note")
            expectEqual(m.editor.selectedShapeIDs, [ends[0]], "\(key): the first pill's note")
        }
        let m = try Minute()
        defer { m.close() }
        _ = try m.twoPills()
        KeyDriver(m.window).send(.return)
        m.h.scheduler.advance(by: .zero)
        expectEqual(m.editor.editingShapeID, m.featureNote, "no pill focused: the card, and editing goes on")
        expect(m.editor.fieldCards?.openTarget != nil, "the row's card is open")
    },
    test("the relation row is a group named for its field with its pills as buttons, the focused pill is the focused element, and the walk announces each") {
        let m = try Minute()
        defer { m.close() }
        _ = try m.twoPills()
        let rows = try require(m.rowsView)
        let children = (rows.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
        let row = try require(children.first { AccessibilityProbe.label(of: $0) == "in" }, "an element for the row")
        expectEqual(AccessibilityProbe.role(of: row), "AXGroup")
        let pills = (row.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
        expectEqual(pills.count, 2)
        expect(pills.allSatisfy { AccessibilityProbe.role(of: $0) == "AXButton" && AccessibilityProbe.label(of: $0) != nil })
        KeyDriver(m.window).send(.right)
        let focused = try require(rows.accessibilityFocusedUIElement as? NSAccessibilityProtocol)
        expectEqual(AccessibilityProbe.label(of: focused), AccessibilityProbe.label(of: pills[0]))
        expectEqual(AccessibilityProbe.role(of: focused), "AXButton")
    },
])
