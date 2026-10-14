import Canvas
import CanvasTesting
import Foundation
import TestKit
import Types

// What the check says of a note's values (`fullCheck`): the pure checker of a list of types, reached
// through the service, over the shared fixtures and the check's own. One case for each row of the design's
// table of classes and each state of the plan's "Needed and wrong".

private let person = FieldFixtures.personID, order = FieldFixtures.orderID, employee = FieldFixtures.employeeID, address = FieldFixtures.addressID

/// Each problem as `needed /path`, `wrong /path` or `warning /path`, in the order the check gives them.
private func className(_ kind: FieldClass) -> String {
    switch kind {
    case .warning: "warning"
    case .needed: "needed"
    case .wrong: "wrong"
    }
}

private func summary(_ check: FieldCheck) -> [String] {
    check.problems.map { "\(className($0.kind)) \($0.path.isRoot ? "(root)" : $0.path.pointer)" }
}

@MainActor private func editor() throws -> CanvasEditor {
    let editor = try fieldEditor()
    editor.addCheckTypes([CheckFixtures.contact, CheckFixtures.deep, CheckFixtures.pricing, CheckFixtures.shop, CheckFixtures.tree, CheckFixtures.unions,
                          CheckFixtures.pairs, CheckFixtures.rule, CheckFixtures.strict, CheckFixtures.lists, CheckFixtures.peer, CheckFixtures.crew])
    editor.addTypeLink(person, to: CheckFixtures.peerID)
    return editor
}

private func line(_ product: String, _ quantity: JSONValue) -> JSONValue { ["product": .string(product), "quantity": quantity] }

@MainActor let fieldCheckerTests = Suite("The check", [
    test("a fresh Order asks for its customer and line items, and not for a gift note, whatever the gift") {
        let editor = try editor()
        let id = editor.addNote(of: [order])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["needed /customer", "needed /lineItems"])
        expect(check.isIncomplete && !check.isWrong)
        expectEqual(check.problems.map(\.place), [["customer"], ["line items"]])
        expectEqual(check.problems.map(\.message), ["customer is needed", "line items is needed"])
        expectEqual(check.problems.map(\.keyword), ["required", "required"])
        let ticked = editor.addNote(of: [order], ["gift": true])
        expectEqual(summary(editor.fullCheck(of: ticked)), ["needed /customer", "needed /lineItems", "needed /giftNote"], "asked once ticked")
    },
    test("a gift note is needed while gift is ticked, and not unticked, and not for an Order that never said") {
        let editor = try editor()
        let filled: JSONObject = ["customer": "Ann Lee", "lineItems": [line("Mug", 1)]]
        let base = editor.addNote(of: [order], filled)
        expectEqual(summary(editor.fullCheck(of: base)), [], "a filled Order is clean")
        var ticked = filled
        ticked["gift"] = true
        let gift = editor.addNote(of: [order], ticked)
        expectEqual(summary(editor.fullCheck(of: gift)), ["needed /giftNote"])
        expectEqual(editor.fullCheck(of: gift).problems.first?.message, "gift note is needed")
        var unticked = filled
        unticked["gift"] = false
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [order], unticked))), [])
        var noted = ticked
        noted["giftNote"] = "Happy birthday"
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [order], noted))), [])
    },
    test("a line item's quantity of 0 is wrong at the cell, worded with its place; a missing one is needed") {
        let editor = try editor()
        let id = editor.addNote(of: [order], ["customer": "Ann Lee", "lineItems": [line("Mug", 1), line("Plate", 0)]])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["wrong /lineItems/1/quantity"])
        let problem = try require(check.problems.first)
        expectEqual(problem.place, ["line items", "Plate", "quantity"])
        expectEqual(problem.message, "line items › Plate › quantity is 0, and should be at least 1")
        expectEqual(problem.keyword, "minimum")
        expectEqual(check.mark(at: FieldPath(field: "lineItems")), .wrong)
        expectEqual(check.mark(at: FieldPath(field: "customer")), nil)
        let missing = editor.addNote(of: [order], ["customer": "Ann Lee", "lineItems": [["quantity": 2]]])
        let needed = editor.fullCheck(of: missing)
        expectEqual(summary(needed), ["needed /lineItems/0/product"])
        expectEqual(needed.problems.first?.place, ["line items", "2", "product"], "an item with no plain value first is labelled by its first value")
        let bare = editor.addNote(of: [order], ["customer": "Ann Lee", "lineItems": [["price": 5]]])
        expectEqual(editor.fullCheck(of: bare).problems.first?.place, ["line items", "5", "product"])
    },
    test("an item with no plain value is `item N`, counted from 1") {
        let editor = try editor()
        let id = editor.addNote(of: [CheckFixtures.crewID], ["rows": [["label": "a", "price": 1], ["label": "b"]]])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["needed /rows/1/price"])
        expectEqual(check.problems.first?.place, ["rows", "b", "price"])
        let deep = editor.addNote(of: [CheckFixtures.crewID], ["rows": [[:], ["price": 2]]])
        expectEqual(summary(editor.fullCheck(of: deep)), [], "an empty item is pruned away")
    },
    test("a wrong email is wrong at the field; Person needs a name; both are said, in row order") {
        let editor = try editor()
        let id = editor.addNote(of: [person], ["email": "ann@"])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["needed /name", "wrong /email"])
        expect(check.isWrong && check.isIncomplete)
        let wrong = try require(check.problems.last)
        expectEqual(wrong.keyword, "format")
        expectEqual(wrong.message, #"email should be an email address, not "ann@""#)
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [person], ["name": "Ann", "email": "bo@acme.com"]))), [])
    },
    test("a date kept as typed is wrong, and Employee's fields come with Person's") {
        let editor = try editor()
        let id = editor.addNote(of: [employee], ["startDate": "Jan 2024", "role": "Cook"])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["needed /name", "wrong /startDate"], "name is Person's, inherited")
        expect(try require(check.problems.last).message.hasPrefix("start date should be a date like 2026-03-03"))
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [employee], ["name": "A", "startDate": "2024-02-29"]))), [])
    },
    test("a number that is text is wrong; so is an option outside the list, and the wrong one is said by its keyword") {
        let editor = try editor()
        let id = editor.addNote(of: [order], ["customer": "Ann Lee", "lineItems": [line("Mug", "02134")], "status": "lost"])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["wrong /lineItems/0/quantity", "wrong /status"])
        expectEqual(check.problems.map(\.keyword), ["type", "enum"])
        expectEqual(check.problems[0].message, #"line items › Mug › quantity should be an integer, not "02134""#.replacingOccurrences(of: "an integer", with: "a whole number"), "see the validator's words")
    },
    test("at least one of a phone or an email: neither asks for both, one asks for nothing; a card asks for its code") {
        let editor = try editor()
        let contact = CheckFixtures.contactID
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [contact], ["name": "A"]))), ["needed /phone", "needed /email"])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [contact], ["name": "A", "phone": "1"]))), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [contact], ["name": "A", "email": "a@b.c"]))), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [contact], ["name": "A", "phone": "1", "card": "4"]))), ["needed /cvv"])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [contact], ["name": "A", "phone": "1", "card": "4", "cvv": "1"]))), [])
    },
    test("a group inside a list inside a group asks and limits at the depth it is at; an absent group asks for nothing") {
        let editor = try editor()
        let deep = CheckFixtures.deepID
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [deep]))), [], "no team, no title asked for")
        let id = editor.addNote(of: [deep], ["team": ["members": [["name": "A", "age": 3], ["name": "B", "age": -1], ["name": "C"]]]])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["wrong /team/members/1/age", "needed /team/members/2/age", "needed /team/title"], "by the path's text under a row")
        expectEqual(check.problems[0].place, ["team", "members", "B", "age"])
        expectEqual(check.problems[1].place, ["team", "members", "C", "age"])
        expectEqual(check.mark(at: FieldPath(field: "team")), .wrong)
        expectEqual(check.mark(at: FieldPath(field: "team").key("members").index(0)), nil)
        expectEqual(check.mark(at: FieldPath(field: "team").key("members").index(2)), .needed)
    },
    test("a required list is needed while empty, whether it says at least one or two; with one filled, two is wrong; a list not needed is nothing") {
        let editor = try editor()
        let lists = CheckFixtures.listsID
        let empty = editor.fullCheck(of: editor.addNote(of: [lists]))
        expect(summary(empty).contains("needed /one") && summary(empty).contains("needed /two"))
        expect(!summary(empty).contains { $0.hasSuffix("/maybe") }, "not needed, so nothing, whatever its minItems")
        let some = editor.fullCheck(of: editor.addNote(of: [lists], ["one": ["a"], "two": ["a"], "done": false, "mode": "fixed"]))
        expectEqual(summary(some), ["wrong /two"])
        expectEqual(some.problems.first?.keyword, "minItems")
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [lists], ["one": ["a"], "two": ["a", "b"], "mode": "fixed"]))), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [lists], ["one": ["a"], "two": ["a", "b"], "mode": "fixed", "maybe": ["x"]]))), ["wrong /maybe"])
    },
    test("a needed yes or no never counts as empty; a needed choice of one does; a required name no field has is dropped") {
        let editor = try editor()
        let empty = summary(editor.fullCheck(of: editor.addNote(of: [CheckFixtures.listsID])))
        expect(!empty.contains("needed /done"), "\(empty)")
        expect(empty.contains("needed /mode"), "\(empty)")
        expect(!empty.contains { $0.contains("ghost") }, "\(empty)")
        expectEqual(empty.count, 3, "one, two, mode: \(empty)")
    },
    test("a value that breaks its pattern and its length is two problems at one path, said by the keywords in the validator's order") {
        let editor = try editor()
        let check = editor.fullCheck(of: editor.addNote(of: [CheckFixtures.listsID], ["code": "A1", "one": ["a"], "two": ["a", "b"], "mode": "fixed"]))
        expectEqual(summary(check), ["wrong /code", "wrong /code"])
        expectEqual(Set(check.problems.map(\.keyword)), ["pattern", "minLength"])
        expectEqual(check.problems(at: FieldPath(field: "code")).count, 2)
    },
    test("a date field holding a part of a date is wrong, a full one is not; a number field's text is wrong") {
        let editor = try editor()
        let base: JSONObject = ["one": ["a"], "two": ["a", "b"], "mode": "fixed"]
        @MainActor func check(_ extra: JSONObject) throws -> [String] { summary(editor.fullCheck(of: editor.addNote(of: [CheckFixtures.listsID], base.merging(extra) { $1 }))) }
        expectEqual(try check(["when": "Jan 2024"]), ["wrong /when"])
        expectEqual(try check(["when": "2024-01-31"]), [])
        expectEqual(try check(["qty": "17000000000000000"]), ["wrong /qty"])
        expectEqual(try check(["qty": 3]), [])
    },
    test("a date or date-time typed as a full date is stored in a form its format accepts, and a part of a date breaks it; time, link and UUID likewise") {
        let editor = try editor()
        editor.addCheckTypes([CheckFixtures.moments])
        let locale = Locale(identifier: "en_US_POSIX")
        @MainActor func check(_ field: String, _ typed: String, as kind: PlainKind = .text) throws -> [String] {
            let value = try require(FieldText.value(from: typed, as: kind, locale: locale))
            return summary(editor.fullCheck(of: editor.addNote(of: [CheckFixtures.momentsID], [field: value])))
        }
        for typed in ["2026-03-03", "Mar 3, 2026", "3 Mar 2026"] {
            expectEqual(try check("at", typed, as: .dateTime), [], "\(typed) stored as a date-time")
        }
        expectEqual(try check("at", "Jan 2024", as: .dateTime), ["wrong /at"])
        expectEqual(try check("at", "2026-03", as: .dateTime), ["wrong /at"])
        expectEqual(try check("time", "09:30:00Z"), [])
        expectEqual(try check("time", "9:30"), ["wrong /time"])
        expectEqual(try check("site", "https://acme.com/a?b=1"), [])
        expectEqual(try check("site", "acme.com"), ["wrong /site"])
        expectEqual(try check("ref", "123e4567-e89b-42d3-a456-426614174000"), [])
        expectEqual(try check("ref", "123e4567"), ["wrong /ref"])
    },
    test("a union that fits neither form is wrong at the field; an object form missing its needed member is wrong, at the field too") {
        let editor = try editor()
        let unions = CheckFixtures.unionsID
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [unions], ["size": true]))), ["wrong /size"])
        expectEqual(editor.fullCheck(of: editor.addNote(of: [unions], ["size": true])).problems.first?.keyword, "anyOf")
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [unions], ["size": "L", "payment": "cash"]))), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [unions], ["payment": ["cardNumber": "4"]]))), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [unions], ["payment": ["other": "4"]]))), ["wrong /payment"])
    },
    test("pairs: a wrong value is at its pair, a refused name is worded by the row, too few pairs is wrong at the row") {
        let editor = try editor()
        let pairs = CheckFixtures.pairsID
        let value = editor.fullCheck(of: editor.addNote(of: [pairs], ["labels": ["a": 5]]))
        expectEqual(summary(value), ["wrong /labels/a"])
        expectEqual(value.problems.first?.place, ["labels", "a"])
        let name = editor.fullCheck(of: editor.addNote(of: [pairs], ["labels": ["Size 2": "L"]]))
        expectEqual(summary(name), ["wrong /labels/Size 2"])
        expectEqual(name.problems.first?.message, "labels › Size 2 isn’t a name labels allows")
        expectEqual(name.problems.first?.keyword, "propertyNames")
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [pairs], ["labels": ["size": "L"]]))), [])
    },
    test("a rule across fields is a problem at the root named for its type, and no row; a limit on a member no type names is nothing") {
        let editor = try editor()
        let rule = CheckFixtures.ruleID
        let both = editor.fullCheck(of: editor.addNote(of: [rule], ["a": 3, "b": 4]))
        expect(summary(both).contains("wrong (root)"), "\(summary(both))")
        let root = try require(both.problems.first { $0.path.isRoot })
        expectEqual(root.keyword, "rule")
        expect(root.message.hasPrefix("Exclusive rule: the note "), root.message)
        expect(root.place.isEmpty)
        expectEqual(both.problems.last?.path.isRoot, true, "the root is last")
        expectEqual(both.mark(at: FieldPath()), .wrong)
        expectEqual(both.mark(at: FieldPath(field: "a")), nil, "no row is marked")
        let fits = editor.fullCheck(of: editor.addNote(of: [rule], ["a": 3]))
        expect(fits.problems.contains { $0.path.isRoot && $0.message.contains("more than one") }, "a oneOf that two forms fit: \(summary(fits))")
        let ghost = editor.fullCheck(of: editor.addNote(of: [rule], ["a": 6, "flag": true, "ghost": "far too long"]))
        expectEqual(summary(ghost), [], "a rule's limit on a name no field has")
    },
    test("a value no field names is never wrong, at any depth, whatever the groups say of other names") {
        let editor = try editor()
        let strict = CheckFixtures.strictID
        let id = editor.addNote(of: [strict], ["name": "x", "nickname": 5, "extra": ["deep": 1], "box": ["width": 1, "height": 2, "depth": 3], "items": [["a": "x", "b": "y"]]])
        expectEqual(summary(editor.fullCheck(of: id)), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [person], ["name": "A", "nickname": 5]))), [])
    },
    test("another type's fields are checked, its inherited ones too; a part of a type is checked as the type writes it") {
        let editor = try editor()
        let shop = CheckFixtures.shopID
        let boss = editor.fullCheck(of: editor.addNote(of: [shop], ["boss": ["role": "Cook", "email": "x@"]]))
        expectEqual(summary(boss), ["wrong /boss/email", "needed /boss/name"], "Employee's own and Person's")
        expectEqual(boss.problems.last?.place, ["boss", "name"])
        let price = editor.fullCheck(of: editor.addNote(of: [shop], ["price": -1]))
        expectEqual(summary(price), ["wrong /price"], "a ref with a fragment is checked against that part")
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [shop], ["price": 4, "address": ["city": "Oslo"]]))), [])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [shop], ["address": ["city": 5]]))), ["wrong /address/city"])
    },
    test("a type that refers to itself terminates and checks a value three deep") {
        let editor = try editor()
        let tree = CheckFixtures.treeID
        let id = editor.addNote(of: [tree], ["name": "root", "child": ["child": ["child": ["name": 5]]]])
        let check = editor.fullCheck(of: id)
        expectEqual(summary(check), ["wrong /child/child/child/name"])
        expectEqual(check.problems.first?.place, ["child", "child", "child", "name"])
    },
    test("a type that is gone is not checked and not red; one of two gone leaves the other checked; no types is clean") {
        let editor = try editor()
        let shop = CheckFixtures.shopID
        let ghost = ShapeID()
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [ghost], ["x": 1]))), [])
        let both = editor.addNote(of: [ghost, person], ["email": "a@"])
        expectEqual(summary(editor.fullCheck(of: both)), ["needed /name", "wrong /email"])
        let id = editor.addNote(of: [shop], ["address": ["city": 5], "boss": ["name": "Bo"]])
        expectEqual(summary(editor.fullCheck(of: id)), ["wrong /address/city"])
        editor.transact("Delete") { $0.delete([address]) }
        expectEqual(summary(editor.fullCheck(of: id)), [], "a field of a gone type: values kept, not checked")
        expectEqual(editor.document[id]?[FieldValuesProperty.self]?["address"] != nil, true)
        editor.undo()
        expectEqual(summary(editor.fullCheck(of: id)), ["wrong /address/city"], "back with the type")
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: []))), [], "no types")
    },
    test("Peer restates name and replaces Person's: needed follows the winner, and so do its limits") {
        let editor = try editor()
        let peer = CheckFixtures.peerID
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [peer]))), [], "Peer's name is not needed")
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [peer], ["name": "Al"]))), ["wrong /name"])
        expectEqual(summary(editor.fullCheck(of: editor.addNote(of: [peer], ["name": "Alan", "email": "a@"]))), ["wrong /email"], "Person's email, inherited")
    },
    test("a shape that is a type, an opaque shape and a shape with no types are clean") {
        let editor = try editor()
        let checks = try require(editor.fieldChecks)
        expectEqual(checks.fullCheck(of: try require(editor.document[employee])), .clean, "a type, though it is an instance of Person")
        let plain = editor.addInstance("plain", of: [])
        expectEqual(checks.fullCheck(of: try require(editor.document[plain])), .clean)
    },
    test("problems come in row order and then by path with item 2 before item 10; the root last") {
        let editor = try editor()
        var items: [JSONValue] = (0..<12).map { line("P\($0)", 1) }
        items[10] = line("P10", 0)
        items[2] = line("P2", 0)
        let check = editor.fullCheck(of: editor.addNote(of: [order], ["lineItems": .array(items), "status": "lost"]))
        expectEqual(summary(check), ["needed /customer", "wrong /lineItems/2/quantity", "wrong /lineItems/10/quantity", "wrong /status"])
        expectEqual(check.problems.first?.path, FieldPath(field: "customer"))
    },
    test("a note's problems are capped at 100, wrong first, keeping one of each class") {
        let editor = try editor()
        let many = JSONValue.array((0..<150).map { _ in "ab" })
        let check = editor.fullCheck(of: editor.addNote(of: [CheckFixtures.listsID], ["tags": many, "one": ["a"], "two": ["a", "b"], "mode": "fixed"]))
        expectEqual(check.problems.count, 100)
        expect(check.isWrong && !check.isIncomplete)
        let with = editor.fullCheck(of: editor.addNote(of: [CheckFixtures.listsID], ["tags": many]))
        expectEqual(with.problems.count, 100)
        expect(with.isWrong && with.isIncomplete, "the cap never changes what the ring or :incomplete read")
        expectEqual(with.problems.filter { $0.kind == .needed }.count, 1, "150 wrong and 3 needed: one needed is kept")
        let forty = (0..<40).map { _ in JSONValue.object(["label": "x"]) }
        let rows = editor.fullCheck(of: editor.addNote(of: [CheckFixtures.crewID], ["rows": .array(forty)]))
        expectEqual(rows.problems.count, 40, "40 items each missing a price")
        expectEqual(rows.mark(at: FieldPath(field: "rows")), .needed)
    },
    test("a field asked for by the root and by a rule is one problem") {
        let editor = try editor()
        let check = editor.fullCheck(of: editor.addNote(of: [CheckFixtures.contactID]))
        expectEqual(check.problems(at: FieldPath(field: "name")).count, 1)
        expectEqual(check.problems(at: FieldPath(field: "phone")).count, 1)
    },
    test("leaving out what is being typed in") {
        let editor = try editor()
        let check = editor.fullCheck(of: editor.addNote(of: [person], ["email": "ann@"]))
        expectEqual(summary(check.leaving(out: FieldPath(field: "email"))), ["needed /name"])
    },
])
