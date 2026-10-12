import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import TextEditing
import Titles
import Types

// The list over a pointer's field (`LinkPicker`): the notes that are the type through the chain, on any board,
// ranked as the `@` picker ranks them, each line the name and the board's; and what its keys do, Tab never a pick.
// Headless, over slips: Persons on the board shown and in two pockets, Employee a Person.

private let clients = ShapeID(), team = ShapeID()
private let andersID = ShapeID(), danaID = ShapeID(), fayID = ShapeID(), annTwoID = ShapeID()

@MainActor
private struct Bench {
    let editor: CanvasEditor
    let order: ShapeID

    init(people: Bool = true) throws {
        func person(_ name: String, id: ShapeID, of types: [ShapeID] = [FieldFixtures.personID], at x: Double = 0) -> AnyShapeRecord {
            var record = slipRecord("", of: types, at: CGPoint(x: x, y: 300), id: id)
            record[TitleProperty.self] = name
            return record
        }
        func pocket(_ id: ShapeID, _ name: String, at y: Double) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(CGRect(x: 0, y: y, width: 100, height: 100))))
            record[TitleProperty.self] = name
            return record
        }
        let root = CanvasDocument(shapes: [pocket(clients, "Clients", at: 900), pocket(team, "Team", at: 1100)])
        let file = CanvasFile(root: root, children: [
            clients: CanvasDocument(shapes: [person("Anders Holm", id: andersID), person("Dana Novak", id: danaID, at: 300), person("Ann Lee", id: annTwoID, at: 600)]),
            team: CanvasDocument(shapes: [person("Fay Ng", id: fayID, of: [FieldFixtures.employeeID])]),
        ])
        editor = try rowEditor(file: file, more: [PocketsPlugin()])
        editor.addFieldSlips([FieldFixtures.person, FieldFixtures.employee, FieldFixtures.order])
        editor.addTypeLink(FieldFixtures.personID, to: FieldFixtures.employeeID)
        if people { editor.addFieldPeople() }
        order = editor.addSlip("An order", of: [FieldFixtures.orderID], at: CGPoint(x: 40, y: 1500))
    }

    func picker() -> LinkPicker { LinkPicker(editor: editor, owner: order, type: FieldFixtures.personID) }

    func names(_ picker: LinkPicker) -> [String] { picker.choices.map(\.candidate.appearance.label) }

    func items(_ picker: LinkPicker) -> [CaretListItem] { picker.list.rows.compactMap(\.item) }
}

@MainActor let linkPickerTests = Suite("The list of a pointer's field", [
    test("it lists the notes that are the type through the chain, on every board, never a type's own note, and a note given the type mid-pick at the next keystroke") {
        let t = try Bench()
        let picker = t.picker()
        expectEqual(Set(t.names(picker)), ["Ann Lee", "Bo Park", "Anders Holm", "Dana Novak", "Fay Ng"], "Fay is an Employee, and an Employee is a Person")
        expect(!t.names(picker).contains("Person") && !t.names(picker).contains("Employee"), "no type's note")
        expect(!t.names(picker).contains("An order"), "an Order is not a Person")
        let late = t.editor.addSlip("Zed Quill", of: [FieldFixtures.personID], at: CGPoint(x: 900, y: 300))
        t.editor.transact { $0.update(late) { $0[TitleProperty.self] = "Zed Quill" } }
        picker.setQuery("zed")
        expectEqual(t.names(picker), ["Zed Quill"], "listed at the next keystroke")
    },
    test("a typed query ranks the type's notes alone, as the `@` picker ranks them") {
        let t = try Bench()
        let picker = t.picker()
        picker.setQuery("an")
        let names = t.names(picker)
        expect(["Ann Lee", "Anders Holm"].contains(names.first ?? ""), "a prefix first: \(names)")
        expect(names.contains("Dana Novak"), "a match inside a word")
        expect(!names.contains("Bo Park"), "a note that does not match is not listed")
        expectEqual(picker.list.highlighted, 0, "the first is highlighted")
        picker.setQuery("")
        expectEqual(t.names(picker).count, 6, "nothing typed: every note of the type, on any board")
    },
    test("a line is the name, the board's name when it isn't the board shown, and no symbol; two alike read `Kind · Board`") {
        let t = try Bench()
        let picker = t.picker()
        let items = t.items(picker)
        let anders = try require(items.first { $0.title == "Anders Holm" })
        expectEqual(anders.detail, "pocket", "the board's owner's kind, for an owner with no title kind")
        expectEqual(try require(items.first { $0.title == "Fay Ng" }).detail, "pocket")
        expect(items.contains { $0.title == "Bo Park" && $0.detail == nil }, "on the board shown: no board's name")
        expect(items.allSatisfy { $0.symbol == nil }, "board 5 panel 3 draws no symbol")
        // The two called Ann Lee are told apart by their kind, and the board's name where it isn't the board shown.
        let alike = items.filter { $0.title == "Ann Lee" }
        expectEqual(alike.count, 2)
        expect(alike.contains { ($0.detail ?? "").hasPrefix("RowSlip") || ($0.detail ?? "").contains(" · ") }, "told apart: \(alike.map(\.detail))")
    },
    test("with nothing to list it says so: `No Person notes`, and `No matches` for a query that finds none") {
        let t = try Bench(people: false)
        let nobody = LinkPicker(editor: t.editor, owner: t.order, type: FieldFixtures.orderID)
        expectEqual(nobody.list.rows, [.empty("No Order notes")], "the only Order is the owner, left out")
        expectEqual(nobody.list.highlighted, nil)
        let picker = t.picker()
        picker.setQuery("zzqx")
        expectEqual(picker.list.rows, [.empty("No matches")])
        let fay = t.picker()
        expect(!fay.choices.isEmpty, "Persons are in the pockets even with none on the board shown")
    },
    test("Tab and ⇧Tab are never a pick; Return picks the highlighted line and with none is swallowed; Backspace on an empty query closes") {
        let t = try Bench()
        let picker = t.picker()
        expect(picker.list.highlighted != nil)
        for selector in [#selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:))] {
            let (taken, action) = picker.perform(selector)
            expect(!taken && action == .close, "\(selector): not taken, the host closes")
        }
        expect(picker.perform(#selector(NSResponder.insertNewline(_:))) == (true, .pick))
        expect(picker.perform(#selector(NSResponder.moveDown(_:))) == (true, nil))
        expect(picker.perform(#selector(NSResponder.cancelOperation(_:))) == (true, .close))
        expect(picker.perform(#selector(NSResponder.deleteBackward(_:))) == (true, .close), "empty query")
        picker.setQuery("an")
        expect(picker.perform(#selector(NSResponder.deleteBackward(_:))) == (false, nil), "a query: the field deletes")
        picker.setQuery("zzqx")
        expect(picker.perform(#selector(NSResponder.insertNewline(_:))) == (true, nil), "nothing highlighted: taken, nothing picked")
        expect(picker.pick() == nil)
    },
    test("a pick is the token with the name the note shows now, and the pick is first among the recent ones") {
        let t = try Bench()
        let picker = t.picker()
        picker.setQuery("dana")
        let link = try require(picker.pick())
        expectEqual(link, FieldLink(target: danaID, stored: "Dana Novak"))
        expect(MentionToken.read(link.value.stringValue ?? "") != nil, "one mention token")
        let again = t.picker()
        expectEqual(t.names(again).first, "Dana Novak", "recent first")
        expectEqual(again.pick(row: 99), nil, "no such line")
    },
])
