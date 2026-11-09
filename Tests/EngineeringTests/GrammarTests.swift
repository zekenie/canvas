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
    test("a quote opens a quoted run only where a word starts, and one never closed is a letter: no word is swallowed, none lost to a repeat") {
        expectEqual(said(ColumnGrammar.read("customer's_id uuid pk")), "customer's_id|uuid|false|false|true|-|", "an apostrophe in a name")
        expectEqual(said(ColumnGrammar.read("f(a text pk")), "f(a|text|false|false|true|-|", "a parenthesis never closed")
        expectEqual(said(ColumnGrammar.read("g text default 'a pk")), "g|text|false|false|true|'a|", "a quote never closed ends with the word")
        expectEqual(said(ColumnGrammar.read("x int default 1 default 2")), "x|int|false|false|false|1|default 2", "a second default is kept, not the first's loss")
        expectEqual(said(ColumnGrammar.read("x int pk pk")), "x|int|false|false|true|-|pk")
        expectEqual(ColumnGrammar.print(try require(ColumnGrammar.read("x int default 1 default 2"), "x")), "x int default 1 default 2")
    },
    test("printing what was read reads back as the same column, and loses no word") {
        for line in ["id uuid pk", "placed_at timestamptz?", "email text unique null default ''", "customer_id uuid -> customers.id",
                     "total numeric(10, 2) default 0 pk", "sku text unique check (sku <> '')", "status order_status", "id PRIMARY KEY", "id",
                     "customer's_id uuid pk", "x int default 1 default 2", "x int pk pk unique unique null null", "f(a text pk", "g text default 'a pk"] {
            let read = try require(ColumnGrammar.read(line), line)
            let printed = ColumnGrammar.print(read)
            expectEqual(said(ColumnGrammar.read(printed)), said(read), "\(line) → \(printed)")
            let printedWords = printed.split(separator: " ").map(String.init)
            expect(ownWords(line).allSatisfy(printedWords.contains), "\(printed) keeps every word of \(line)")
        }
        expectEqual(ColumnGrammar.print(Column(name: "placed_at", type: TypeRef("timestamptz"), nullable: true, default: "now()", unread: "→ x.y")),
                    "placed_at timestamptz null default now() → x.y")
    },
    test("SQL's types of several words read as SQL writes them, a ? after the last word null; a default that casts to one too") {
        expectEqual(said(ColumnGrammar.read("created_at timestamp with time zone not null default now()")), "created_at|timestamp with time zone|false|false|false|now()|")
        expectEqual(said(ColumnGrammar.read("at TIMESTAMP(3) WITHOUT TIME ZONE")), "at|TIMESTAMP(3) WITHOUT TIME ZONE|false|false|false|-|", "as typed, any case")
        expectEqual(said(ColumnGrammar.read("note character varying(255)?")), "note|character varying(255)|true|false|false|-|")
        expectEqual(said(ColumnGrammar.read("ratio double precision unsigned")), "ratio|double precision unsigned|false|false|false|-|")
        expectEqual(said(ColumnGrammar.read("span interval day to second(3) pk")), "span|interval day to second(3)|false|false|true|-|")
        expectEqual(said(ColumnGrammar.read("code national character varying(10)")), "code|national character varying(10)|false|false|false|-|")
        expectEqual(said(ColumnGrammar.read("bits bit varying(8)[]")), "bits|bit varying(8)[]|false|false|false|-|")
        expectEqual(said(ColumnGrammar.read("t timestamp with time")), "t|timestamp|false|false|false|-|with time", "with time zone whole or not at all")
        expectEqual(said(ColumnGrammar.read("t timestamp? with time zone")), "t|timestamp|true|false|false|-|with time zone", "a ? ends the type")
        expectEqual(said(ColumnGrammar.read("name text default ''::character varying null")), "name|text|true|false|false|''::character varying|")
        expectEqual(said(ColumnGrammar.read("at timestamp default '2020-01-01 00:00'::timestamp without time zone")),
                    "at|timestamp|false|false|false|'2020-01-01 00:00'::timestamp without time zone|")
    },
    test("a name, a type and a default in double quotes are the words between them, a doubled quote a quote; a quoted literal's doubled quote stays in it") {
        expectEqual(said(ColumnGrammar.read("\"order date\" date")), "order date|date|false|false|false|-|")
        expectEqual(said(ColumnGrammar.read("status \"Order Status\"? default 'new'")), "status|Order Status|true|false|false|'new'|")
        expectEqual(said(ColumnGrammar.read("due date default \"now() + interval '1 day'\" pk")), "due|date|false|false|true|now() + interval '1 day'|")
        expectEqual(said(ColumnGrammar.read("say text default \"a \"\"b\"\"\"")), "say|text|false|false|false|a \"b\"|")
        expectEqual(said(ColumnGrammar.read("note text default 'it''s a test' unique")), "note|text|false|true|false|'it''s a test'|", "SQL's own escape keeps the literal one word")
        let read = try require(ColumnGrammar.scan("status \"Order Status\" null").typeRange)
        expectEqual(read, NSRange(location: 8, length: 12), "the type's words without their quotes: what an enum's pill stands on")
    },
    test("a print quotes only a part that wouldn't read back alone: a name or an enum's of several words, a default of several no cast explains") {
        expectEqual(ColumnGrammar.print(Column(name: "created_at", type: TypeRef("timestamp with time zone"), default: "''::character varying")),
                    "created_at timestamp with time zone default ''::character varying")
        expectEqual(ColumnGrammar.print(Column(name: "order date", type: TypeRef("Order Status"), nullable: true)), "\"order date\" \"Order Status\" null")
        expectEqual(ColumnGrammar.print(Column(name: "due", type: TypeRef("date"), default: "now() + interval '1 day'")), "due date default \"now() + interval '1 day'\"")
        expectEqual(ColumnGrammar.print(Column(name: "x", type: TypeRef("varchar(255) binary"))), "x \"varchar(255) binary\"", "a type SQL's words don't explain")
        expectEqual(ColumnGrammar.print(Column(name: "x", type: TypeRef("null"))), "x \"null\"", "a type that's a word of the grammar's")
        expectEqual(ColumnGrammar.print(Column(name: "x", type: TypeRef("text"), default: "\"quoted\"")), "x text default \"\"\"quoted\"\"\"", "a default that's a quoted run itself")
        expectEqual(ColumnGrammar.print(Column(name: "x", type: TypeRef("int"), unread: "→ y.id"), key: "customers.id").line, "x int → customers.id → y.id",
                    "a key's words before the words kept, so the line's first arrow is the key's")
    },
    test("every column the SQL reader writes (pg_dump's, MySQL's, quoted names, spaced enums) prints as a line that reads back as it") {
        let schema = SQLReader.read(#"""
            CREATE TYPE public."Order Status" AS ENUM ('new', 'paid');
            CREATE TABLE public."Line Items" (
                id integer NOT NULL,
                "order date" timestamp(6) without time zone DEFAULT '2020-01-01 00:00:00'::timestamp without time zone,
                name character varying(255) DEFAULT ''::character varying NOT NULL,
                code national character varying(10),
                ratio double precision DEFAULT (1.0 / 3),
                due date DEFAULT (now() + '1 day'::interval),
                late timestamp with time zone DEFAULT now() + interval '1 day',
                span interval day to second(3),
                bits bit varying(8)[],
                status public."Order Status" DEFAULT 'new'::public."Order Status",
                note text DEFAULT 'it''s a test',
                "say ""hi""" text,
                place geography(Point, 4326),
                flag "char" DEFAULT 'a'::"char"
            );
            CREATE TABLE legacy (
                id int(11) unsigned NOT NULL AUTO_INCREMENT,
                total decimal(10,2) unsigned zerofill DEFAULT '0.00',
                label varchar(255) binary DEFAULT NULL,
                PRIMARY KEY (id)
            );
            """#)
        let columns = schema.tables.flatMap(\.columns)
        expectEqual(columns.count, 17)
        for column in columns {
            let line = ColumnGrammar.print(column)
            expectEqual(said(ColumnGrammar.read(line)), said(column), "\(said(column) ?? "") → \(line)")
        }
    },
    test("a key's target that holds a space, a dot or a quote is written in quotes and reads back as the same row") {
        expectEqual(ColumnGrammar.written(table: "customers", column: "first name"), "customers.\"first name\"")
        expectEqual(ColumnGrammar.written(table: "order lines", column: "a.b"), "\"order lines\".\"a.b\"")
        expectEqual(ColumnGrammar.written(table: "customers", column: "say \"hi\""), "customers.\"say \"\"hi\"\"\"")
        for (table, column) in [("customers", "first name"), ("order lines", "a.b"), ("v1.2", "id"), ("customers", "say \"hi\""), ("customers", "id")] {
            let target = ColumnGrammar.written(table: table, column: column)
            let held = Column(name: "ref", type: TypeRef("uuid"), unread: "later words")
            let (line, range) = ColumnGrammar.print(held, key: target)
            let read = try require(ColumnGrammar.read(line))
            expectEqual(read.unread, "→ \(target) later words", "\(line)")
            let key = try require(ColumnGrammar.key(in: read.unread))
            expectEqual(key.column, column, "\(target)")
            expectEqual(key.table, table, "\(target)")
            expectEqual(range.map { (line as NSString).substring(with: $0) }, target, "the key's range is the whole target")
        }
    },
    test("a column with no type and words kept that aren't the grammar's prints an empty type, so they aren't read as one") {
        let held = Column(name: "price", type: TypeRef(""), unread: "check (price > 0)")
        expectEqual(ColumnGrammar.print(held), "price \"\" check (price > 0)")
        expectEqual(said(ColumnGrammar.read(ColumnGrammar.print(held))), said(held))
        expectEqual(ColumnGrammar.print(Column(name: "id", type: TypeRef(""), primaryKey: true)), "id pk", "no empty type where a word of the grammar's follows")
    },
    test("every column a card can make reads back as the column it says: its type typed there, its default, normalized, its type cleared") {
        let schema = SQLReader.read(#"""
            CREATE TABLE "Line Items" (
                id integer NOT NULL,
                "order date" timestamp(6) without time zone DEFAULT '2020-01-01 00:00:00'::timestamp without time zone,
                name character varying(255) DEFAULT ''::character varying NOT NULL,
                late timestamp with time zone DEFAULT now() + interval '1 day',
                "say ""hi""" text DEFAULT 'it''s a test',
                total decimal(10,2) unsigned zerofill DEFAULT '0.00'
            );
            """#)
        var columns = schema.tables.flatMap(\.columns)
        columns += [
            Column(name: "state", type: TypeRef("Order Status"), nullable: true),
            Column(name: "first name", type: TypeRef("Order Status"), unique: true, default: "\"x\""),
            Column(name: "price", type: TypeRef("numeric"), unread: "check (price > 0)"),
            Column(name: "ref", type: TypeRef("uuid"), unread: "→ nowhere.x"),
            Column(name: "note", type: TypeRef("null"), default: "a b"),
        ]
        for column in columns {
            let expected = said(column)
            if !column.type.words.isEmpty {
                let typed = TypeRef(ColumnGrammar.written(type: column.type.words))
                expectEqual(said(EngineeringLines.cardRetyped(column, typed)), expected, "retyped: \(column.name)")
            }
            expectEqual(said(EngineeringLines.cardDefaulted(column, column.default)), expected, "defaulted: \(column.name)")
            expectEqual(said(EngineeringLines.cardNormalized(column)), expected, "normalized: \(column.name)")
            var cleared = column
            cleared.type = TypeRef("")
            expectEqual(said(EngineeringLines.cardRetyped(column, nil)), said(cleared), "cleared: \(column.name)")
        }
    },
    test("a block of lines is a column a line, blank lines passed over, each its own id; printed, a line a column") {
        let columns = ColumnGrammar.read(lines: "id uuid pk\n\n  \ncustomer_id uuid\n")
        expectEqual(columns.map(\.name), ["id", "customer_id"])
        expect(columns[0].id != columns[1].id)
        expectEqual(ColumnGrammar.print(lines: columns), "id uuid pk\ncustomer_id uuid")
    },
    test("what a statement writes joins what the table holds by name: a column it names takes its line and keeps its id and on delete; a new one goes after the one written before it, else last; one it leaves out stays") {
        let enumID = ShapeID()
        let held = [Column(name: "id", type: TypeRef("uuid"), primaryKey: true),
                    Column(name: "status", type: TypeRef("order_status", shape: enumID), onDelete: "cascade"),
                    Column(name: "note", type: TypeRef("text"))]
        let merged = ColumnGrammar.merge(ColumnGrammar.read(lines: "status order_status null\nplaced_at timestamptz"), onto: held)
        expectEqual(merged.map(\.name), ["id", "status", "placed_at", "note"], "placed_at after status, written before it")
        expectEqual(ColumnGrammar.merge(ColumnGrammar.read(lines: "first int\nid uuid pk"), onto: held).map(\.name), ["id", "status", "note", "first"],
                    "written before every column it has: last")
        expectEqual(merged[1].id, held[1].id, "its id kept")
        expectEqual(merged[1].onDelete, "cascade", "what no line says, kept")
        expectEqual(merged[1].type.shape, enumID, "its type's words still say the same, so still bound")
        expect(merged[1].nullable)
        expectEqual(merged[0], held[0])
        expectEqual(ColumnGrammar.merge(ColumnGrammar.read(lines: ColumnGrammar.print(lines: held)), onto: held), held, "the same lines again: nothing changes")
        let retyped = ColumnGrammar.merge(ColumnGrammar.read(lines: "status text"), onto: held)
        expectEqual(retyped[1].type, TypeRef("text"), "other words name no enum")
        let later = ShapeID()
        let bound = ColumnGrammar.merge([Column(name: "note", type: TypeRef("text", shape: later))], onto: held)
        expectEqual(bound[2].type.shape, later, "words that name an enum now are bound, though they named none before")
    },
    test("an enum's values are a line each, trimmed, blank lines passed over; joined by text, a value it has keeping its id, a new one after the one written before it") {
        let values = EnumGrammar.read(lines: " pending \npaid\n\nrefunded")
        expectEqual(values.map(\.text), ["pending", "paid", "refunded"])
        expectEqual(EnumGrammar.print(lines: values), "pending\npaid\nrefunded")
        let merged = EnumGrammar.merge(EnumGrammar.read(lines: "paid\nvoid"), onto: values)
        expectEqual(merged.map(\.text), ["pending", "paid", "void", "refunded"])
        expectEqual(merged[1].id, values[1].id)
    },
])
