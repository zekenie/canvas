import Canvas
import Engineering
import Foundation
import TestKit

// The column and enum grammars, pure: a line read into a column and printed back, a block of lines, and the join of what
// a statement writes onto what a table holds. Printing what was read loses no word.

/// What a column says, with no id: the comparison a read and a print are held to.
private func said(_ column: Column?) -> String? {
    column.map { "\($0.name)|\($0.type.words)|\($0.nullable)|\($0.unique)|\($0.primaryKey)|\($0.default ?? "-")|\($0.unread)" }
}

/// The words of a line that are its own, not the grammar's (its name, type, default and what it kept), as a print writes them:
/// a type's `?` left off and `->` as →. A print of the line's read must hold every one.
private func ownWords(_ line: String) -> [String] {
    line.replacingOccurrences(of: "->", with: "→").split(separator: " ").compactMap { word -> String? in
        if ["null", "unique", "pk", "default", "primary", "key", "not"].contains(word.lowercased()) { return nil }
        return word.count > 1 && word.hasSuffix("?") ? String(word.dropLast()) : String(word)
    }
}

@MainActor let grammarTests = Suite("The column and enum grammars", [
    test("a line is a name, a type, then null, unique, default and pk in any order and case; a ? after the type is null") {
        expectEqual(said(ColumnGrammar.read("id uuid pk")), "id|uuid|false|false|true|-|")
        expectEqual(said(ColumnGrammar.read("placed_at timestamptz?")), "placed_at|timestamptz|true|false|false|-|")
        expectEqual(said(ColumnGrammar.read("email text UNIQUE null default ''")), "email|text|true|true|false|''|")
        expectEqual(said(ColumnGrammar.read("total numeric(10, 2) not null default 0")), "total|numeric(10, 2)|false|false|false|0|", "a type with a space in its parentheses")
        expectEqual(said(ColumnGrammar.read("id PRIMARY KEY")), "id||false|false|true|-|", "no type: the grammar's own words are no type")
        expectEqual(said(ColumnGrammar.read("note text default 'a b' pk")), "note|text|false|false|true|'a b'|", "a quoted default is one word")
        expectEqual(ColumnGrammar.read("   "), nil, "a line with nothing on it")
    },
    test("words it can't place stay in the row, as written: a key's → among them until keys land") {
        expectEqual(said(ColumnGrammar.read("customer_id uuid → customers.id")), "customer_id|uuid|false|false|false|-|→ customers.id")
        expectEqual(said(ColumnGrammar.read("customer_id uuid -> customers.id null")), "customer_id|uuid|true|false|false|-|→ customers.id", "-> typed for →")
        expectEqual(said(ColumnGrammar.read("sku text unique check (sku <> '')")), "sku|text|false|true|false|-|check (sku <> '')")
    },
    test("printing what was read reads back as the same column, and loses no word") {
        for line in ["id uuid pk", "placed_at timestamptz?", "email text unique null default ''", "customer_id uuid -> customers.id",
                     "total numeric(10, 2) default 0 pk", "sku text unique check (sku <> '')", "status order_status", "id PRIMARY KEY", "id"] {
            let read = try require(ColumnGrammar.read(line), line)
            let printed = ColumnGrammar.print(read)
            expectEqual(said(ColumnGrammar.read(printed)), said(read), "\(line) → \(printed)")
            let printedWords = printed.split(separator: " ").map(String.init)
            expect(ownWords(line).allSatisfy(printedWords.contains), "\(printed) keeps every word of \(line)")
        }
        expectEqual(ColumnGrammar.print(Column(name: "placed_at", type: TypeRef("timestamptz"), nullable: true, default: "now()", unread: "→ x.y")),
                    "placed_at timestamptz null default now() → x.y")
    },
    test("a block of lines is a column a line, blank lines passed over, each its own id; printed, a line a column") {
        let columns = ColumnGrammar.read(lines: "id uuid pk\n\n  \ncustomer_id uuid\n")
        expectEqual(columns.map(\.name), ["id", "customer_id"])
        expect(columns[0].id != columns[1].id)
        expectEqual(ColumnGrammar.print(lines: columns), "id uuid pk\ncustomer_id uuid")
    },
    test("what a statement writes joins what the table holds by name: a column it names takes its line and keeps its id and on delete; a new one goes last; one it leaves out stays") {
        let enumID = ShapeID()
        let held = [Column(name: "id", type: TypeRef("uuid"), primaryKey: true),
                    Column(name: "status", type: TypeRef("order_status", shape: enumID), onDelete: "cascade"),
                    Column(name: "note", type: TypeRef("text"))]
        let merged = ColumnGrammar.merge(ColumnGrammar.read(lines: "status order_status null\nplaced_at timestamptz"), onto: held)
        expectEqual(merged.map(\.name), ["id", "status", "note", "placed_at"])
        expectEqual(merged[1].id, held[1].id, "its id kept")
        expectEqual(merged[1].onDelete, "cascade", "what no line says, kept")
        expectEqual(merged[1].type.shape, enumID, "its type's words still say the same, so still bound")
        expect(merged[1].nullable)
        expectEqual(merged[0], held[0])
        expectEqual(ColumnGrammar.merge(ColumnGrammar.read(lines: ColumnGrammar.print(lines: held)), onto: held), held, "the same lines again: nothing changes")
        let retyped = ColumnGrammar.merge(ColumnGrammar.read(lines: "status text"), onto: held)
        expectEqual(retyped[1].type, TypeRef("text"), "other words name no enum")
    },
    test("an enum's values are a line each, trimmed, blank lines passed over; joined by text, a value it has keeping its id") {
        let values = EnumGrammar.read(lines: " pending \npaid\n\nrefunded")
        expectEqual(values.map(\.text), ["pending", "paid", "refunded"])
        expectEqual(EnumGrammar.print(lines: values), "pending\npaid\nrefunded")
        let merged = EnumGrammar.merge(EnumGrammar.read(lines: "paid\nvoid"), onto: values)
        expectEqual(merged.map(\.text), ["pending", "paid", "refunded", "void"])
        expectEqual(merged[1].id, values[1].id)
    },
])
