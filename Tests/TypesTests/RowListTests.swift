import Canvas
import CanvasTesting
import TestKit
import Types

// The rows of a list of fields: every row up to nine, then the fold.

private let person = ShapeID(), employee = ShapeID(), speaker = ShapeID(), kin = ShapeID()

private func field(_ name: String, by type: ShapeID) -> Resolved.Field {
    Resolved.Field(field: ChainField(name: name, schema: .object([SchemaMember(key: "type", value: .string("string"))])), source: type, introducedBy: type)
}

private func resolved(_ fields: [Resolved.Field]) -> Resolved {
    var resolved = Resolved()
    resolved.fields = fields
    return resolved
}

/// `count` fields of one type, `a1…`.
private func fields(_ count: Int, by type: ShapeID, prefix: String = "f") -> [Resolved.Field] {
    (1...max(count, 1)).prefix(count).map { field("\(prefix)\($0)", by: type) }
}

/// The rows as words: a field its name, a fold `from …` or `+N more` and how many it holds.
private func words(_ list: RowList) -> [String] {
    list.items.map { item in
        switch item {
        case .field(let field): field.field.name
        case .fold(let fold): fold.isMore ? "+\(fold.folded.count) more" : "from \(fold.sources.count) (\(fold.folded.count))"
        }
    }
}

@MainActor let rowListTests = Suite("Row lists", [
    test("nine fields or fewer: every row shows") {
        for count in [0, 1, 8, 9] {
            let list = RowList(resolved(fields(count, by: person)), own: [person])
            expectEqual(list.items.count, count)
            expectEqual(list.all.count, count)
            expect(list.items.allSatisfy { if case .field = $0 { true } else { false } })
        }
        let nine = RowList(resolved(fields(9, by: employee)), own: [employee])
        expectEqual(nine.items.count, 9, "nine own rows show as nine")
        let inheritedNine = RowList(resolved(fields(4, by: person, prefix: "p") + fields(5, by: employee, prefix: "e")), own: [employee])
        expectEqual(inheritedNine.items.count, 9, "nine fields with some inherited: no fold")
    },
    test("ten fields with nothing inherited: the first eight and +2 more; twenty: eight and +12 more, the last ones folding") {
        let ten = RowList(resolved(fields(10, by: person)), own: [person])
        expectEqual(words(ten), ["f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "+2 more"])
        expectEqual(ten.items.count, 9)
        expectEqual(ten.all.count, 10)
        let twenty = RowList(resolved(fields(20, by: person)), own: [person])
        expectEqual(twenty.items.count, 9)
        guard case .fold(let fold) = twenty.items[8] else { throw Failure("a fold last") }
        expect(fold.isMore)
        expectEqual(fold.from, nil)
        expectEqual(fold.sources, [])
        expectEqual(fold.folded.map(\.field.name), (9...20).map { "f\($0)" }, "the last ones fold, in order")
        expectEqual(twenty.items.prefix(8).compactMap { if case .field(let f) = $0 { f.field.name } else { nil } }, (1...8).map { "f\($0)" })
    },
    test("Employee with six fields on Person's four: from Person holds the four, and six rows") {
        let list = RowList(resolved(fields(4, by: person, prefix: "p") + fields(6, by: employee, prefix: "e")), own: [employee])
        expectEqual(list.items.count, 7)
        guard case .fold(let fold) = list.items[0] else { throw Failure("the fold first, in the place of the first inherited row") }
        expectEqual(fold.folded.map(\.field.name), ["p1", "p2", "p3", "p4"])
        expectEqual(fold.sources, [person])
        expectEqual(fold.from, person)
        expect(!fold.isMore)
        expectEqual(list.items.dropFirst().compactMap { if case .field(let f) = $0 { f.field.name } else { nil } }, (1...6).map { "e\($0)" })
        expectEqual(list.all.count, 10)
    },
    test("one inherited row among ten does not fold alone: eight and +2 more") {
        let list = RowList(resolved(fields(1, by: person, prefix: "p") + fields(9, by: employee, prefix: "e")), own: [employee])
        expectEqual(list.items.count, 9)
        expect(list.items.prefix(8).allSatisfy { if case .field = $0 { true } else { false } })
        guard case .fold(let fold) = list.items[8] else { throw Failure("+N more last") }
        expect(fold.isMore)
        expectEqual(fold.folded.count, 2)
    },
    test("inherited four and own ten: the from row, eight rows and +2 more: ten rows in all") {
        let list = RowList(resolved(fields(4, by: person, prefix: "p") + fields(10, by: employee, prefix: "e")), own: [employee])
        expectEqual(list.items.count, 10)
        guard case .fold(let from) = list.items[0], case .fold(let more) = list.items[9] else { throw Failure("both folds") }
        expectEqual(from.folded.count, 4)
        expect(!from.isMore && more.isMore)
        expectEqual(more.folded.map(\.field.name), ["e9", "e10"])
        expectEqual(list.all.count, 14)
    },
    test("own rows of nine or fewer all show beside the from row") {
        let list = RowList(resolved(fields(4, by: person, prefix: "p") + fields(9, by: employee, prefix: "e")), own: [employee])
        expectEqual(list.items.count, 10, "the from row and nine own rows: no +N more that hides one")
        expectEqual(words(list).first, "from 1 (4)")
    },
    test("two types on one note that share no parent fold neither under the other") {
        let list = RowList(resolved(fields(5, by: employee, prefix: "e") + fields(5, by: speaker, prefix: "s")), own: [employee, speaker])
        expectEqual(list.items.count, 9, "ten own rows: eight and +2 more")
        expect(list.items.allSatisfy { if case .fold(let fold) = $0 { fold.isMore } else { true } }, "no from fold")
    },
    test("two inherited sources read from 2 types, each source once in row order") {
        let list = RowList(resolved(fields(3, by: person, prefix: "p") + fields(3, by: kin, prefix: "k") + fields(5, by: employee, prefix: "e")), own: [employee])
        guard case .fold(let fold) = list.items[0] else { throw Failure("a fold first") }
        expectEqual(fold.sources, [person, kin])
        expectEqual(fold.from, nil, "no one type to name")
        expect(!fold.isMore)
        expectEqual(fold.folded.count, 6)
        expectEqual(list.items.count, 6)
    },
    test("a restated field counts as inherited and keeps its place") {
        var all = fields(4, by: person, prefix: "p") + fields(6, by: employee, prefix: "e")
        // Employee restates p2: the winner is Employee's, the row stays where Person put it.
        all[1] = Resolved.Field(field: all[1].field, source: employee, introducedBy: person)
        let list = RowList(resolved(all), own: [employee])
        guard case .fold(let fold) = list.items[0] else { throw Failure("a fold first") }
        expectEqual(fold.folded.map(\.field.name), ["p1", "p2", "p3", "p4"])
        expectEqual(fold.folded[1].source, employee)
        expectEqual(list.items.count, 7)
    },
    test("a type's note passes itself: its own rows are its own, what it builds on is inherited") {
        let list = RowList(resolved(fields(4, by: person, prefix: "p") + fields(6, by: employee, prefix: "e")), own: [employee])
        let asPerson = RowList(resolved(fields(4, by: person, prefix: "p") + fields(6, by: employee, prefix: "e")), own: [person, employee])
        expectEqual(list.items.count, 7)
        expectEqual(asPerson.items.count, 9, "own both: eight and +2 more")
    },
    test("count(of:own:) says how many rows without building them, for each") {
        let cases: [([Resolved.Field], Set<ShapeID>)] = [
            ([], [person]), (fields(1, by: person), [person]), (fields(9, by: person), [person]), (fields(10, by: person), [person]), (fields(20, by: person), [person]),
            (fields(4, by: person, prefix: "p") + fields(6, by: employee, prefix: "e"), [employee]),
            (fields(1, by: person, prefix: "p") + fields(9, by: employee, prefix: "e"), [employee]),
            (fields(4, by: person, prefix: "p") + fields(10, by: employee, prefix: "e"), [employee]),
            (fields(4, by: person, prefix: "p") + fields(9, by: employee, prefix: "e"), [employee]),
            (fields(5, by: employee, prefix: "e") + fields(5, by: speaker, prefix: "s"), [employee, speaker]),
            (fields(3, by: person, prefix: "p") + fields(3, by: kin, prefix: "k") + fields(5, by: employee, prefix: "e"), [employee]),
            (fields(30, by: person, prefix: "p") + fields(30, by: employee, prefix: "e"), [employee]),
        ]
        for (all, own) in cases {
            let made = resolved(all)
            expectEqual(RowList.count(of: made, own: own), RowList(made, own: own).items.count, "\(all.count) fields")
        }
    },
    test("the shared wide fixture folds as the rule says: nine rows, ten and twelve") {
        let editor = try fieldEditor()
        for (count, rows) in [(8, 8), (9, 9), (10, 9), (20, 9)] {
            let wide = FieldFixtures.wide(count)
            editor.addFieldTypes([wide])
            let resolved = try require(editor.fieldBook).fields(types: [wide.id])
            expectEqual(resolved.fields.count, count)
            expectEqual(RowList(resolved, own: [wide.id]).items.count, rows, "\(count) fields")
            editor.transact("Delete") { $0.delete([wide.id]) }
        }
    },
])

private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
