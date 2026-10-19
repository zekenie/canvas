import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import TestKit
import Types

// The form as values: what each line of a card or the panel's form says, in which cells, and where the
// keyboard can stop. Pure; no view.

private let us = Locale(identifier: "en_US")

@MainActor private struct Sheets {
    let editor: CanvasEditor
    let book: FieldBook

    init() throws {
        editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.everyKind.a, FieldFixtures.everyKind.b, FieldFixtures.wide(12)])
        book = try require(editor.fieldBook)
    }

    func field(_ name: String, of type: ShapeID = FieldFixtures.orderID) throws -> Resolved.Field {
        try require(book.fields(types: [type]).field(named: name), name)
    }

    /// A field written here, a property of a type's root.
    func adHoc(_ schema: String) throws -> Resolved.Field {
        let level = try require(ChainLevel(schema: #"{"type": "object", "properties": {"f": \#(schema)}}"#))
        return Resolved.Field(field: level.fields[0], source: ShapeID(), introducedBy: ShapeID())
    }

    func sheet(_ field: Resolved.Field, at path: FieldPath? = nil, _ stored: JSONValue? = nil, check: FieldCheck = .clean, types: [ShapeID] = [FieldFixtures.orderID],
               mode: FieldFormMode = .values, readOnly: Bool = false, presentation: FieldFormContext.Presentation = .card,
               drafts: [FieldPath: FieldDraft] = [:], open: [FieldPath: Bool] = [:], back: String? = nil, branch: Int? = nil) -> FieldSheet {
        let path = path ?? FieldPath(field: field.field.name)
        let values = FieldValues(stored?.objectValue ?? [:])
        return FieldSheets.sheet(path: path, field: field, kind: book.kind(of: field), values: values, check: check, book: book, types: types, mode: mode,
                                 isReadOnly: readOnly, presentation: presentation, drafts: drafts, open: open, back: back, branch: branch, locale: us)
    }

    func sheet(_ name: String, of type: ShapeID = FieldFixtures.orderID, _ stored: JSONValue? = nil, check: FieldCheck = .clean,
               mode: FieldFormMode = .values, readOnly: Bool = false, presentation: FieldFormContext.Presentation = .card,
               drafts: [FieldPath: FieldDraft] = [:], open: [FieldPath: Bool] = [:], branch: Int? = nil) throws -> FieldSheet {
        sheet(try field(name, of: type), stored, check: check, types: mode == .kinds ? [type] : [type], mode: mode, readOnly: readOnly,
              presentation: presentation, drafts: drafts, open: open, branch: branch)
    }

    func fold(_ fields: [Resolved.Field], values: FieldValues = FieldValues(), check: FieldCheck = .clean, mode: FieldFormMode = .values,
              readOnly: Bool = false) -> FieldSheet {
        FieldSheets.foldSheet(fields, values: values, check: check, book: book, types: [FieldFixtures.orderID], mode: mode, isReadOnly: readOnly, locale: us)
    }
}

private func controls(_ sheet: FieldSheet) -> [FieldCell.Control] { sheet.lines.flatMap(\.cells).map(\.control) }
private func problem(_ path: FieldPath, _ kind: FieldClass) -> FieldProblem { FieldProblem(path: path, kind: kind, keyword: "x", place: [], message: "") }

@MainActor let fieldSheetTests = Suite("Field sheets", [
    test("a group: a line a member, in the type's order, each cell by its kind, an empty one reading add and its name") {
        let s = try Sheets()
        let group = try s.adHoc(#"""
        {"type": "object", "properties": {
          "name": {"type": "string"}, "price": {"type": "number"}, "due": {"type": "string", "format": "date"}, "done": {"type": "boolean"},
          "status": {"enum": ["draft", "paid"]}, "tags": {"type": "array", "items": {"type": "string"}}, "venue": {"type": "object", "properties": {"city": {"type": "string"}}},
          "extra": {}}}
        """#)
        let sheet = s.sheet(group, ["f": ["name": "Ann", "price": 9.5, "due": "2026-03-03", "done": true, "status": "paid", "tags": ["a", "b"]]], types: [])
        expectEqual(sheet.layout, .rows)
        expectEqual(sheet.lines.map(\.name), ["name", "price", "due", "done", "status", "tags", "venue", "extra"])
        let cells = sheet.lines.flatMap(\.cells)
        expectEqual(cells.map(\.control), [.text(.text), .text(.number(integer: false)), .text(.date), .yesNo,
                                           .choice([FieldOption(value: "draft", label: "draft"), FieldOption(value: "paid", label: "paid")]),
                                           .more(.items(["a", "b"])), .more(.empty("add venue")), .more(.json)])
        expectEqual(cells.map(\.shown), ["Ann", "9.5", "Mar 3, 2026", "yes", "paid", "a, b", "add venue", FieldWords.editedAsJSON])
        expectEqual(cells.map(\.isEditable), [true, true, true, true, true, false, false, false])
        expectEqual(cells[0].path, FieldPath(field: "f").key("name"))
        let empty = s.sheet(group, nil, types: [])
        expectEqual(empty.lines.first?.cells.first?.placeholder, "add name")
        expectEqual(empty.lines.first?.cells.first?.shown, "")
        expectEqual(empty.lines[3].cells[0].placeholder, "", "a box says nothing")
        expectEqual(sheet.stops, [FieldStop(line: 0, column: 0), FieldStop(line: 1, column: 0), FieldStop(line: 2, column: 0), FieldStop(line: 3, column: 0),
                                  FieldStop(line: 4, column: 0), FieldStop(line: 5, column: -1), FieldStop(line: 6, column: -1), FieldStop(line: 7, column: -1)])
    },
    test("another type's fields: its chip and its fields, inherited first; a gone type is the chip and no lines; a member that was a pointer is text") {
        let s = try Sheets()
        let address = try s.sheet("shippingAddress", ["shippingAddress": ["city": "Leeds"]])
        expectEqual(address.chip, FieldFixtures.addressID)
        expectEqual(address.lines.map(\.name), ["street", "city", "postcode"])
        expectEqual(address.lines.map { $0.cells[0].shown }, ["", "Leeds", ""])
        let employee = s.sheet(try s.adHoc(#"{"$ref": "\#(FieldFixtures.uri(of: FieldFixtures.employeeID))"}"#), types: [])
        expectEqual(employee.chip, FieldFixtures.employeeID)
        expectEqual(employee.lines.map(\.name), ["name", "email", "role", "start date"], "Person's first")
        let gone = ShapeID()
        let missing = s.sheet(try s.adHoc(#"{"$ref": "\#(FieldFixtures.uri(of: gone))"}"#), types: [])
        expectEqual(missing.chip, gone)
        expectEqual(missing.lines, [])
        let customer = s.sheet(try s.adHoc(#"{"type": "object", "properties": {"c": {"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\#(FieldFixtures.uri(of: FieldFixtures.personID))"}}}}"#), ["f": ["c": "Ann Lee"]], types: [])
        expectEqual(customer.lines[0].cells[0].control, .text(.text), "a schema that was a pointer is text")
        expectEqual(customer.lines[0].cells[0].shown, "Ann Lee")
        expectEqual(customer.stops, [FieldStop(line: 0, column: 0)])
    },
    test("a list of text, of numbers, of dates: a line each, then the waiting line reading add; read-only has none, and empty reads None") {
        let s = try Sheets()
        let tags = try s.field("tags")
        let list = s.sheet(tags, ["tags": ["gift", "mugs"]])
        expectEqual(list.layout, .column)
        expectEqual(list.lines.map { $0.cells[0].shown }, ["gift", "mugs", ""])
        expectEqual(list.lines.map { $0.cells[0].isStored }, [true, true, false])
        expectEqual(list.lines.map { $0.cells[0].placeholder }, ["", "", "add"])
        expectEqual(list.lines.map { $0.cells[0].path }, (0...2).map { FieldPath(field: "tags").index($0) })
        expectEqual(list.lines.map(\.slot), [0, 1, 2])
        expectEqual(list.lines.first?.list, FieldPath(field: "tags"))
        let numbers = s.sheet(try s.adHoc(#"{"type": "array", "items": {"type": "number"}}"#), ["f": [1, 2.5]], types: [])
        expectEqual(numbers.lines.map { $0.cells[0].shown }, ["1", "2.5", ""])
        expectEqual(numbers.lines[0].cells[0].control, .text(.number(integer: false)))
        let dates = s.sheet(try s.adHoc(#"{"type": "array", "items": {"type": "string", "format": "date"}}"#), ["f": ["2026-03-03"]], types: [])
        expectEqual(dates.lines.map { $0.cells[0].shown }, ["Mar 3, 2026", ""])
        let readOnly = s.sheet(tags, ["tags": ["gift"]], readOnly: true)
        expectEqual(readOnly.lines.count, 1, "no waiting line")
        expect(!readOnly.lines[0].cells[0].isEditable)
        let nothing = s.sheet(tags, readOnly: true)
        expectEqual(nothing.lines.map { $0.cells[0].control }, [.label(FieldWords.none)])
        expect(nothing.stops.isEmpty)
        expectEqual(list.stops, [FieldStop(line: 0, column: 0), FieldStop(line: 1, column: 0), FieldStop(line: 2, column: 0)])
    },
    test("a list of groups is a table of the members' names, numbers set right, a member with more as more; a list of a type's fields too, under its chip") {
        let s = try Sheets()
        let lines: JSONValue = [["product": "Mug", "quantity": 2, "price": 12], ["product": "Plate", "quantity": 1, "price": 9.5]]
        let table = try s.sheet("lineItems", ["lineItems": lines])
        expectEqual(table.layout, .table(["product", "quantity", "price"]))
        expectEqual(table.lines.count, 3, "two and the waiting line")
        expectEqual(table.lines[0].cells.map(\.shown), ["Mug", "2", "12"])
        expectEqual(table.lines[1].cells.map(\.shown), ["Plate", "1", "9.5"])
        expectEqual(table.lines[0].cells.map(\.alignsRight), [false, true, true])
        expectEqual(table.lines[0].cells[1].path, FieldPath(field: "lineItems").index(0).key("quantity"))
        expectEqual(table.lines[2].cells.map(\.isStored), [false, false, false])
        expectEqual(table.lines[2].cells.map(\.placeholder), ["add", "", ""])
        expectEqual(table.lines[2].cells[0].path, FieldPath(field: "lineItems").index(2).key("product"), "where the item would go")
        expectEqual(table.stops.count, 9)
        expectEqual(table.stops.prefix(4), [FieldStop(line: 0, column: 0), FieldStop(line: 0, column: 1), FieldStop(line: 0, column: 2), FieldStop(line: 1, column: 0)])
        let nested = s.sheet(try s.adHoc(#"{"type": "array", "items": {"type": "object", "properties": {"n": {"type": "string"}, "tags": {"type": "array", "items": {"type": "string"}}}}}"#),
                             ["f": [["n": "a", "tags": ["x", "y"]]]], types: [])
        expectEqual(nested.lines[0].cells.map(\.control), [.text(.text), .more(.items(["x", "y"]))])
        expectEqual(nested.stops.prefix(2), [FieldStop(line: 0, column: 0), FieldStop(line: 0, column: 1)], "a cell with more is its cell's stop in a table")
        let rooms = s.sheet(try s.field("rooms", of: FieldFixtures.kindsBID), ["rooms": [["city": "Leeds"]]], types: [FieldFixtures.kindsBID])
        expectEqual(rooms.chip, FieldFixtures.addressID)
        expectEqual(rooms.layout, .table(["street", "city", "postcode"]))
        expectEqual(rooms.lines[0].cells.map(\.shown), ["", "Leeds", ""])
    },
    test("several choices: a check line an option, the picked ones on, and None last") {
        let s = try Sheets()
        let roles = try s.field("roles", of: FieldFixtures.kindsAID)
        let sheet = s.sheet(roles, ["roles": ["designer"]], types: [FieldFixtures.kindsAID])
        expectEqual(sheet.layout, .checks)
        expectEqual(sheet.lines.map { $0.cells[0].shown }, ["engineer", "designer", "manager", "None"])
        expectEqual(controls(sheet), [.check(false), .check(true), .check(false), .clear])
        expectEqual(sheet.stops, (0...3).map { FieldStop(line: $0, column: -1) })
        let locked = s.sheet(roles, readOnly: true)
        expectEqual(locked.lines.count, 4)
        expect(locked.lines.allSatisfy { !$0.cells[0].isEditable })
    },
    test("pairs: a name and a value a line in name order, then the waiting line; a half-typed pair keeps its text; a name another pair has is marked") {
        let s = try Sheets()
        let labels = try s.field("labels", of: FieldFixtures.kindsBID)
        let sheet = s.sheet(labels, ["labels": ["weight": "heavy", "size": "L"]], types: [FieldFixtures.kindsBID])
        expectEqual(sheet.layout, .pairs)
        expectEqual(sheet.lines.map { $0.cells.map(\.shown) }, [["size", "L"], ["weight", "heavy"], ["", ""]])
        expectEqual(sheet.lines[0].cells[0].path, FieldPath(field: "labels").key("size"))
        expectEqual(sheet.lines[0].cells[1].path, FieldPath(field: "labels").key("size"))
        expectEqual(sheet.lines[2].cells[0].placeholder, "add")
        expectEqual(sheet.lines.map { $0.cells.map(\.isStored) }, [[true, true], [true, true], [false, false]])
        expectEqual(sheet.stops.count, 6)
        var draft = FieldDraft(["size": "L"], waiting: true)
        draft.slots.insert(.pair(name: "size", value: "XL", taken: true), at: 1)
        let half = s.sheet(labels, ["labels": ["size": "L"]], types: [FieldFixtures.kindsBID], drafts: [FieldPath(field: "labels"): draft])
        expectEqual(half.lines[1].cells.map(\.shown), ["size", "XL"])
        expectEqual(half.lines[1].cells[0].mark, .wrong, "the name another pair has")
        expectEqual(half.lines[1].cells.map(\.isStored), [false, false])
    },
    test("either: the branch names, the branch the value fits (the first with none), a plain branch as one cell") {
        let s = try Sheets()
        let payment = try s.field("payment", of: FieldFixtures.kindsBID)
        let types = [FieldFixtures.kindsBID]
        let empty = s.sheet(payment, types: types)
        expectEqual(empty.branches, ["1 field", "Text"], "the first branch is the group")
        expectEqual(empty.branch, 0)
        expectEqual(empty.lines.map(\.name), ["card number"])
        let text = s.sheet(payment, ["payment": "cash"], types: types)
        expectEqual(text.branch, 1)
        expectEqual(text.lines.count, 1)
        expectEqual(text.lines[0].cells[0].control, .text(.text))
        expectEqual(text.lines[0].cells[0].shown, "cash")
        expectEqual(text.lines[0].cells[0].path, FieldPath(field: "payment"))
        let group = s.sheet(payment, ["payment": ["cardNumber": "4242"]], types: types)
        expectEqual(group.branch, 0)
        expectEqual(group.lines[0].cells[0].shown, "4242")
        let picked = s.sheet(payment, ["payment": "cash"], types: types, branch: 0)
        expectEqual(picked.branch, 0)
        expectEqual(picked.lines[0].cells[0].shown, "", "the other branch's control, empty")
        expectEqual(picked.lines[0].cells[0].path, FieldPath(field: "payment").key("cardNumber"))
        let object = s.sheet(payment, ["payment": ["cardNumber": "4242"]], types: types, branch: 1)
        expectEqual(object.branch, 1)
        expectEqual(object.lines[0].cells[0].shown, "", "the text branch over a group is empty, not the group as JSON")
        expectEqual(object.lines[0].cells[0].value, nil)
        expectEqual(object.lines[0].cells[0].path, FieldPath(field: "payment"))
        expectEqual(group.stops.first, FieldStop(line: -1, column: 0), "the branch names are a stop")
        let size = s.sheet(try s.field("size", of: FieldFixtures.kindsBID), ["size": 3], types: types)
        expectEqual(size.branches, [], "two plain kinds are one cell")
        expectEqual(size.lines[0].cells[0].control, .oneOf([.number(integer: false), .text]))
    },
    test("a type's note: names with kinds, the amber dot, chips, a › only where a member opens") {
        let s = try Sheets()
        let order = s.fold(s.book.fields(types: [FieldFixtures.orderID]).fields, mode: .kinds)
        expectEqual(order.lines.map(\.name), ["customer", "shipping address", "line items", "status", "tags", "gift", "gift note"])
        expectEqual(order.lines.map(\.isNeeded), [true, false, true, false, false, false, false])
        expectEqual(order.lines.map { $0.cells[0].shown }, ["Text", "", "List", "Choice", "List of Text", "Yes or no", "Text"])
        expectEqual(order.lines[0].chip, nil)
        expectEqual(order.lines[1].chip, FieldFixtures.addressID)
        expectEqual(order.lines.map { $0.cells[0].isEditable }, Array(repeating: false, count: 7))
        expectEqual(order.stops, [FieldStop(line: 1, column: -1), FieldStop(line: 2, column: -1)], "only the rows that open")
        let list = try s.sheet("lineItems", mode: .kinds)
        expectEqual(list.layout, .rows)
        expectEqual(list.lines.map(\.name), ["product", "quantity", "price"])
        expectEqual(list.lines.map { $0.cells[0].shown }, ["Text", "Number", "Number"])
        expectEqual(list.lines.map(\.isNeeded), [true, true, false])
        let pairs = try s.sheet("labels", of: FieldFixtures.kindsBID, mode: .kinds)
        expectEqual(pairs.lines.map(\.name), ["name", "value"])
        expectEqual(pairs.lines.map { $0.cells[0].shown }, ["Text", "Text"])
        let either = try s.sheet("payment", of: FieldFixtures.kindsBID, mode: .kinds)
        expectEqual(either.branches, ["1 field", "Text"])
        expectEqual(either.lines.map(\.name), ["card number"])
        let text = try s.sheet("payment", of: FieldFixtures.kindsBID, mode: .kinds, branch: 1)
        expectEqual(text.lines, [], "a plain branch has no rows")
        let choices = try s.sheet("roles", of: FieldFixtures.kindsAID, mode: .kinds)
        expectEqual(controls(choices), [.check(false), .check(false), .check(false)])
        let address = try s.sheet("rooms", of: FieldFixtures.kindsBID, mode: .kinds)
        expectEqual(address.chip, FieldFixtures.addressID)
        expectEqual(address.lines.map(\.name), ["street", "city", "postcode"])
    },
    test("the fold: the folded fields as rows, under their type's chip when one type brought every one") {
        let s = try Sheets()
        let person = try s.field("email", of: FieldFixtures.employeeID)
        let role = try s.field("role", of: FieldFixtures.employeeID)
        let folded = s.fold([try s.field("name", of: FieldFixtures.employeeID), person], values: FieldValues(["name": "Ann"]))
        expectEqual(folded.chip, FieldFixtures.personID)
        expectEqual(folded.lines.map(\.name), ["name", "email"])
        expectEqual(folded.lines[0].cells[0].shown, "Ann")
        expectEqual(folded.lines[0].cells[0].path, FieldPath(field: "name"))
        expectEqual(folded.stops, [FieldStop(line: 0, column: 0), FieldStop(line: 1, column: 0)])
        let mixed = s.fold([person, role])
        expectEqual(mixed.chip, nil, "two types brought them")
        let wide = s.book.fields(types: [FieldFixtures.wideID])
        let more = s.fold(Array(wide.fields.dropFirst(8)))
        expectEqual(more.lines.count, 4)
        let kinds = s.fold(Array(s.book.fields(types: [FieldFixtures.kindsAID]).fields.prefix(3)), mode: .kinds)
        expectEqual(kinds.lines.map { $0.cells[0].shown }, ["Text", "Number", "Date"])
        expectEqual(kinds.lines.map(\.isNeeded), [true, false, false])
    },
    test("a draft: the stored index of a line counts the stored lines before it; a line emptied turns blank and the lines after shift; reconcile when the count differs") {
        var draft = FieldDraft(["a", "b", "c"], waiting: true)
        expectEqual(draft.slots, [.stored(key: nil), .stored(key: nil), .stored(key: nil), .blank])
        expectEqual((0...3).map(draft.storedIndex(ofLine:)), [0, 1, 2, 3])
        draft.blank(line: 1)
        expectEqual((0...4).map(draft.storedIndex(ofLine:)), [0, 1, 1, 2, 2])
        expectEqual(draft.slots[2], .stored(key: nil), "the line after it is still the item after")
        draft.reconcile(with: ["a", "c"])
        expectEqual(draft.slots[1], .blank, "the same count: the emptied line stays")
        draft.reconcile(with: ["a", "c", "d", "e"])
        expectEqual(draft.slots, [.stored(key: nil), .stored(key: nil), .stored(key: nil), .stored(key: nil), .blank], "another count: every line stored, one waiting")
        draft.reconcile(with: nil)
        expectEqual(draft.slots, [.blank])
        let locked = FieldDraft(["a"], waiting: false)
        expectEqual(locked.slots, [.stored(key: nil)])
        var fresh = FieldDraft(nil, waiting: false)
        fresh.reconcile(with: ["x"])
        expectEqual(fresh.slots, [.stored(key: nil)], "no blank for read-only")
        var stored = FieldDraft(["a"], waiting: true)
        stored.store(line: 1)
        expectEqual(stored.slots, [.stored(key: nil), .stored(key: nil), .blank], "filling the waiting line makes another")
        stored.remove(line: 0)
        expectEqual(stored.slots, [.stored(key: nil), .blank])
    },
    test("marks from a check: wrong at a cell, needed and empty, needed under a cell with more; none for what is not stored") {
        let s = try Sheets()
        let items = FieldPath(field: "lineItems")
        let lines: JSONValue = [["product": "Mug", "quantity": 2], ["product": "Plate", "quantity": 0]]
        let check = FieldCheck(problems: [problem(items.index(1).key("quantity"), .wrong), problem(items.index(0).key("price"), .needed)])
        let table = try s.sheet("lineItems", ["lineItems": lines], check: check)
        expectEqual(table.lines[1].cells[1].mark, .wrong)
        expectEqual(table.lines[0].cells[1].mark, nil)
        expectEqual(table.lines[0].cells[2].mark, .needed)
        expectEqual(table.lines[0].cells[2].placeholder, "add", "an empty needed cell in a table says add")
        expectEqual(table.lines[2].cells.map(\.mark), [nil, nil, nil], "the waiting line is marked by nothing")
        let order = s.fold(s.book.fields(types: [FieldFixtures.orderID]).fields, check: FieldCheck(problems: [
            problem(FieldPath(field: "lineItems").index(1).key("quantity"), .wrong), problem(FieldPath(field: "customer"), .needed)]))
        expectEqual(order.lines.first { $0.name == "line items" }?.cells[0].mark, .wrong, "the row above a wrong cell")
        expectEqual(order.lines.first { $0.name == "customer" }?.cells[0].mark, .needed)
        expectEqual(order.lines.first { $0.name == "status" }?.cells[0].mark, nil)
        let typing = check.leaving(out: items.index(1).key("quantity"))
        let quiet = try s.sheet("lineItems", ["lineItems": lines], check: typing)
        expectEqual(quiet.lines[1].cells[1].mark, nil, "the path being typed in")
    },
    test("the panel: closed is one line with a triangle; open puts the next level under it, a depth down; a problem opens it unless the person closed it") {
        let s = try Sheets()
        let address = try s.field("shippingAddress")
        let stored: JSONValue = ["shippingAddress": ["city": "Leeds"]]
        let path = FieldPath(field: "shippingAddress")
        let closed = s.sheet(address, stored, presentation: .panel)
        expectEqual(closed.lines.count, 1)
        expectEqual(closed.lines[0].disclosure, false)
        expectEqual(closed.lines[0].cells[0].control, .more(.items(["Leeds"])))
        expectEqual(closed.stops, [FieldStop(line: 0, column: -1)], "the triangle is a stop")
        let opened = s.sheet(address, stored, presentation: .panel, open: [path: true])
        expectEqual(opened.lines.map(\.depth), [0, 1, 1, 1])
        expectEqual(opened.lines.map(\.name), [nil, "street", "city", "postcode"])
        expectEqual(opened.lines[0].disclosure, true)
        expectEqual(opened.lines[2].cells[0].shown, "Leeds")
        let wrong = FieldCheck(problems: [problem(path.key("city"), .wrong)])
        let byItself = s.sheet(address, stored, check: wrong, presentation: .panel)
        expectEqual(byItself.lines[0].disclosure, true, "a problem under it opens it")
        expectEqual(byItself.lines[2].cells[0].mark, .wrong)
        let shut = s.sheet(address, stored, check: wrong, presentation: .panel, open: [path: false])
        expectEqual(shut.lines.count, 1, "the person closed it")
        let nested = s.sheet(try s.adHoc(#"{"type": "object", "properties": {"inner": {"type": "object", "properties": {"x": {"type": "string"}}}}}"#), ["f": ["inner": ["x": "1"]]],
                             types: [], presentation: .panel, open: [FieldPath(field: "f"): true, FieldPath(field: "f").key("inner"): true])
        expectEqual(nested.lines.map(\.depth), [0, 1, 2], "a member with more has its own triangle, to any depth")
        expectEqual(nested.lines.map(\.disclosure), [true, true, nil])
        let items = s.sheet(try s.field("lineItems"), ["lineItems": [["product": "Mug"], ["product": "Plate"]]], presentation: .panel,
                            open: [FieldPath(field: "lineItems"): true, FieldPath(field: "lineItems").index(1): true])
        expectEqual(items.lines.map(\.depth), [0, 1, 1, 2, 2, 2, 1])
        expectEqual(items.lines.map(\.disclosure), [true, false, true, nil, nil, nil, false], "a line an item, then the add line")
        expectEqual(items.lines[1].cells[0].shown, "Mug")
        expectEqual(items.lines[6].cells[0].shown, "add")
        expectEqual(items.lines[6].cells[0].isStored, false)
        let customer = s.sheet(try s.field("customer"), ["customer": "Ann Lee"], presentation: .panel)
        expectEqual(customer.lines.map { $0.cells[0].control }, [.text(.text)], "a text is one line")
        let other = s.sheet(try s.adHoc("{}"), ["f": ["k": 1]], types: [], presentation: .panel)
        expectEqual(other.lines.count, 1)
        expectEqual(other.lines[0].cells[0].control, .json, "Other is the JSON box")
    },
    test("stops are in reading order for each layout") {
        let s = try Sheets()
        let rows = s.fold(s.book.fields(types: [FieldFixtures.orderID]).fields)
        expectEqual(rows.lines.map(\.name), ["customer", "shipping address", "line items", "status", "tags", "gift", "gift note"])
        expectEqual(rows.stops, [FieldStop(line: 0, column: 0), FieldStop(line: 1, column: -1), FieldStop(line: 2, column: -1), FieldStop(line: 3, column: 0),
                                 FieldStop(line: 4, column: -1), FieldStop(line: 5, column: 0), FieldStop(line: 6, column: 0)], "a text is a stop; a row with more is the line")
        let branch = s.sheet(try s.field("payment", of: FieldFixtures.kindsBID), types: [FieldFixtures.kindsBID])
        expectEqual(branch.stops, [FieldStop(line: -1, column: 0), FieldStop(line: 0, column: 0)])
    },
    test("a line that is not stored has the stored index its item would take: in the middle of a list and at its end") {
        let s = try Sheets()
        var draft = FieldDraft(["a", "b", "c"], waiting: true)
        draft.blank(line: 1)
        let tags = FieldPath(field: "tags")
        let sheet = s.sheet(try s.field("tags"), ["tags": ["a", "c"]], drafts: [tags: draft])
        expectEqual(sheet.lines.map { $0.cells[0].isStored }, [true, false, true, false])
        expectEqual(sheet.lines.map { $0.cells[0].path }, [tags.index(0), tags.index(1), tags.index(1), tags.index(2)])
        expectEqual(sheet.lines.map { $0.cells[0].shown }, ["a", "", "c", ""])
        expectEqual(sheet.lines.map { $0.cells[0].placeholder }, ["", "", "", "add"], "only the waiting line says add")
        expectEqual(sheet.lines.map(\.slot), [0, 1, 2, 3])
    },
    test("a summary in a cell is as the shared vocabulary says it: five values are a list, joined") {
        let s = try Sheets()
        let group = try s.adHoc(#"{"type": "object", "properties": {"tags": {"type": "array", "items": {"type": "string"}}}}"#)
        let sheet = s.sheet(group, ["f": ["tags": ["a", "b", "c", "d", "e"]]], types: [])
        expectEqual(sheet.lines[0].cells[0].control, .more(.items(["a", "b", "c", "d", "e"])))
        expectEqual(sheet.lines[0].cells[0].shown, "a, b, c, d, e", "the view cuts it to what fits and ends it +N")
    },
    test("pairs in a draft: name order as made; a key added by reconcile is the last stored line; a key gone loses its line; a half-typed line stays") {
        var draft = FieldDraft(["weight": "heavy", "size": "L"], waiting: true)
        expectEqual(draft.slots, [.stored(key: "size"), .stored(key: "weight"), .blank])
        draft.reconcile(with: ["weight": "heavy", "size": "L", "alpha": "1"])
        expectEqual(draft.slots, [.stored(key: "size"), .stored(key: "weight"), .stored(key: "alpha"), .blank], "the new key is the last line, whatever its name")
        draft.reconcile(with: ["weight": "heavy", "alpha": "1"])
        expectEqual(draft.slots, [.stored(key: "weight"), .stored(key: "alpha"), .blank])
        draft.slots.insert(.pair(name: "", value: "x", taken: false), at: 2)
        draft.reconcile(with: ["weight": "heavy", "alpha": "1", "beta": "2"])
        expectEqual(draft.slots, [.stored(key: "weight"), .stored(key: "alpha"), .pair(name: "", value: "x", taken: false), .stored(key: "beta"), .blank])
        expectEqual((0...5).map(draft.storedIndex(ofLine:)), [0, 1, 2, 2, 3, 3])
        var empty = FieldDraft(nil, waiting: true, pairs: true)
        empty.reconcile(with: ["a": "1"])
        expectEqual(empty.slots, [.stored(key: "a"), .blank])
        empty.reconcile(with: nil)
        expectEqual(empty.slots, [.blank])
    },
])
