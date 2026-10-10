import Canvas
import TestKit
import Types

// The check's answer, as a value: what a row, a card and the panel read marks from.

private let items = FieldPath(field: "lineItems")
private let cell = items.index(1).key("quantity")

private func problem(_ path: FieldPath, _ kind: FieldClass, _ message: String = "") -> FieldProblem {
    FieldProblem(path: path, kind: kind, keyword: kind == .wrong ? "minimum" : "required", place: [], message: message)
}

@MainActor let fieldCheckTests = Suite("The check's answer", [
    test("the mark at a path is the worst at it or anywhere under it") {
        let check = FieldCheck(problems: [problem(cell, .wrong), problem(FieldPath(field: "customer"), .needed), problem(items.index(0).key("product"), .needed)])
        expectEqual(check.mark(at: cell), .wrong)
        expectEqual(check.mark(at: items.index(1)), .wrong, "the item above a wrong cell")
        expectEqual(check.mark(at: items), .wrong, "the row above it")
        expectEqual(check.mark(at: FieldPath()), .wrong, "the root is above everything")
        expectEqual(check.mark(at: items.index(0)), .needed)
        expectEqual(check.mark(at: items.index(0).key("product")), .needed)
        expectEqual(check.mark(at: FieldPath(field: "customer")), .needed)
        expectEqual(check.mark(at: FieldPath(field: "status")), nil)
        expectEqual(check.mark(at: cell.key("deeper")), nil, "nothing below it is marked")
        expect(FieldClass.needed < FieldClass.wrong)
        expectEqual([FieldClass.wrong, .needed].max(), .wrong)
    },
    test("the problems at a path are exactly its own") {
        let one = problem(cell, .wrong, "one"), two = problem(cell, .wrong, "two"), above = problem(items, .needed, "above")
        let check = FieldCheck(problems: [above, one, two])
        expectEqual(check.problems(at: cell), [one, two])
        expectEqual(check.problems(at: items), [above])
        expectEqual(check.problems(at: items.index(1)), [])
        expectEqual(check.problems(at: FieldPath()), [])
    },
    test("wrong and incomplete: any of either") {
        expect(!FieldCheck.clean.isWrong && !FieldCheck.clean.isIncomplete)
        let needed = FieldCheck(problems: [problem(items, .needed)])
        expect(needed.isIncomplete && !needed.isWrong)
        let wrong = FieldCheck(problems: [problem(cell, .wrong)])
        expect(wrong.isWrong && !wrong.isIncomplete)
        let both = FieldCheck(problems: [problem(items, .needed), problem(cell, .wrong)])
        expect(both.isWrong && both.isIncomplete)
    },
    test("without a path: the problems at or under it go, so a field being typed in is never marked") {
        let check = FieldCheck(problems: [problem(cell, .wrong), problem(items.index(0), .needed), problem(FieldPath(field: "customer"), .needed), problem(FieldPath(), .wrong)])
        let left = check.leaving(out: items)
        expectEqual(left.problems.map(\.path), [FieldPath(field: "customer"), FieldPath()])
        expectEqual(check.leaving(out: cell).problems.count, 3)
        expectEqual(check.leaving(out: FieldPath(field: "status")), check)
        expectEqual(check.leaving(out: FieldPath()), .clean, "the root is above everything")
        expectEqual(FieldCheck.clean.leaving(out: items), .clean)
    },
    test("clean has no problems; the memberwise inits are public and carry everything") {
        expectEqual(FieldCheck.clean.problems.count, 0)
        expectEqual(FieldCheck(), .clean)
        let made = FieldProblem(path: cell, kind: .wrong, keyword: "minimum", place: ["line items", "Plate", "quantity"],
                                message: "line items › Plate › quantity must be at least 1")
        expectEqual(made.place, ["line items", "Plate", "quantity"])
        expectEqual(made.keyword, "minimum")
        expectEqual(made.message, "line items › Plate › quantity must be at least 1")
        expectEqual(Set([made, made]).count, 1, "a problem is hashable")
    },
])
