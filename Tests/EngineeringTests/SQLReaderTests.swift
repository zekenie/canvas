import Clipboard
import Engineering
import Foundation
import TestKit

// The SQL reader, pure: each construct of Postgres-flavored DDL it reads into the kit's model (tables, columns, enums, keys), a
// pg_dump file's keys added after its tables, quoting and folding, comments and dollar quotes that hold `;`, the statements it
// passes over without a word, and the sniff that says cheaply whether a pasteboard may hold SQL.

@MainActor private func table(_ schema: SQLSchema, _ name: String) throws -> SQLTable {
    try require(schema.tables.first { $0.name.name == name }, "no table \(name) in \(schema.tables.map(\.name))")
}

@MainActor private func column(_ table: SQLTable, _ name: String) throws -> Column {
    try require(table.columns.first { $0.name == name }, "no column \(name) in \(table.columns.map(\.name))")
}

@MainActor let sqlReaderTests = Suite("The SQL reader", [
    test("a table's columns: each type as written, lower-cased, one space; NOT NULL, NULL, UNIQUE, PRIMARY KEY, DEFAULT to the next keyword, each after an optional CONSTRAINT name") {
        let schema = SQLReader.read("""
            CREATE TABLE payments (
                id uuid CONSTRAINT payments_pk PRIMARY KEY DEFAULT gen_random_uuid(),
                order_id UUID NOT NULL,
                stripe_charge_id VARCHAR(255) CONSTRAINT one_charge UNIQUE,
                amount_cents NUMERIC(10, 2) NOT NULL DEFAULT 0,
                tags text[] NULL,
                status text DEFAULT 'pending'::text NOT NULL,
                created_at TIMESTAMP   WITH TIME ZONE DEFAULT now() NOT NULL,
                note character varying(20),
                ratio double precision default (1.0 / 3) check (ratio > 0)
            );
            """)
        let payments = try table(schema, "payments")
        expectEqual(payments.columns.map(\.name), ["id", "order_id", "stripe_charge_id", "amount_cents", "tags", "status", "created_at", "note", "ratio"])
        expectEqual(payments.columns.map(\.type.words), ["uuid", "uuid", "varchar(255)", "numeric(10,2)", "text[]", "text", "timestamp with time zone",
                                                          "character varying(20)", "double precision"])
        expectEqual(payments.primaryKey, ["id"])
        let id = try column(payments, "id")
        expect(id.primaryKey)
        expect(!id.nullable, "a primary key may not be null")
        expectEqual(id.default, "gen_random_uuid()")
        expect(!(try column(payments, "order_id")).nullable, "NOT NULL")
        expect((try column(payments, "stripe_charge_id")).unique)
        expect((try column(payments, "stripe_charge_id")).nullable, "no NOT NULL and no primary key: nullable")
        expectEqual((try column(payments, "amount_cents")).default, "0")
        expect((try column(payments, "tags")).nullable, "NULL says so")
        expectEqual((try column(payments, "status")).default, "'pending'::text", "the default's text as written, to the next keyword")
        expect(!(try column(payments, "status")).nullable)
        expectEqual((try column(payments, "created_at")).default, "now()")
        expectEqual((try column(payments, "ratio")).default, "(1.0 / 3)", "to CHECK, which is passed over")
        expectEqual(payments.keys, [])
    },
    test("REFERENCES t (c) ON DELETE and ON UPDATE, a key on the column; REFERENCES t alone names t's primary key; the actions are the column's") {
        let schema = SQLReader.read("""
            CREATE TABLE orders (id uuid PRIMARY KEY, customer_id uuid REFERENCES customers);
            CREATE TABLE payments (
              id uuid PRIMARY KEY,
              order_id uuid NOT NULL CONSTRAINT payments_order_fk REFERENCES orders (id) ON UPDATE NO ACTION ON DELETE CASCADE,
              refund_of uuid references payments(id) match simple on delete set null
            );
            """)
        let payments = try table(schema, "payments")
        expectEqual(payments.keys, [SQLKey(column: "order_id", table: SQLName("orders"), targetColumn: "id"),
                                    SQLKey(column: "refund_of", table: SQLName("payments"), targetColumn: "id")])
        expectEqual((try column(payments, "order_id")).onDelete, "cascade")
        expectEqual((try column(payments, "order_id")).onUpdate, "no action")
        expectEqual((try column(payments, "refund_of")).onDelete, "set null")
        let orders = try table(schema, "orders")
        let key = try require(orders.keys.first)
        expectEqual(key.targetColumn, nil, "no column named")
        expectEqual(key.target(primaryKey: ["id"]), "id", "the table's primary key's")
        expectEqual(key.target(primaryKey: ["a", "b"]), nil, "a key of one column to a primary key of two names none")
    },
    test("table constraints: PRIMARY KEY (a, b) marks each, UNIQUE (a) one, UNIQUE (a, b) none, FOREIGN KEY (a, b) REFERENCES t (x, y) a key a pair; CHECK and EXCLUDE passed over") {
        let schema = SQLReader.read("""
            CREATE TABLE line_items (
              order_id uuid,
              line int,
              sku text,
              warehouse text,
              bin text,
              CONSTRAINT line_items_pk PRIMARY KEY (order_id, line),
              UNIQUE (sku),
              UNIQUE (warehouse, bin),
              CONSTRAINT positive CHECK (line > 0),
              EXCLUDE USING gist (bin WITH =),
              FOREIGN KEY (warehouse, bin) REFERENCES bins (warehouse, code) ON DELETE RESTRICT,
              CONSTRAINT to_order FOREIGN KEY (order_id) REFERENCES orders
            );
            """)
        let items = try table(schema, "line_items")
        expectEqual(items.columns.map(\.name), ["order_id", "line", "sku", "warehouse", "bin"])
        expectEqual(items.primaryKey, ["order_id", "line"])
        expectEqual(items.columns.filter(\.primaryKey).map(\.name), ["order_id", "line"])
        expectEqual(items.columns.filter(\.unique).map(\.name), ["sku"], "a UNIQUE of several columns is passed over")
        expectEqual(items.columns.filter { !$0.nullable }.map(\.name), ["order_id", "line"])
        expectEqual(items.keys.map(\.column), ["warehouse", "bin", "order_id"])
        expectEqual(items.keys.map(\.targetColumn), ["warehouse", "code", nil])
        expectEqual((try column(items, "bin")).onDelete, "restrict")
        // A key of two columns to a table's primary key, named by place.
        let pair = SQLReader.read("CREATE TABLE notes (a int, b int, FOREIGN KEY (a, b) REFERENCES line_items);")
        let keys = try table(pair, "notes").keys
        expectEqual(keys.map { $0.target(primaryKey: ["order_id", "line"]) }, ["order_id", "line"])
    },
    test("CREATE TYPE … AS ENUM: its values in order, each as written; the tables and enums in the order they're made") {
        let schema = SQLReader.read("""
            CREATE TYPE order_status AS ENUM ('pending', 'paid', 'it''s refunded');
            CREATE TABLE orders (id uuid PRIMARY KEY, status order_status NOT NULL DEFAULT 'pending');
            CREATE TYPE public.currency AS ENUM ();
            CREATE TYPE money_range AS RANGE (subtype = numeric);
            """)
        expectEqual(schema.enums.map(\.name.name), ["order_status", "currency"])
        expectEqual(schema.enums[0].values, ["pending", "paid", "it's refunded"])
        expectEqual(schema.enums[1].values, [])
        expectEqual(schema.enums[1].name.schema, nil, "public is no schema of its own")
        expectEqual(schema.order, [.enumType(0), .table(0), .enumType(1)])
        expectEqual((try column(try table(schema, "orders"), "status")).type.words, "order_status")
    },
    test("a pg_dump file: its tables first, then their keys added by ALTER TABLE ONLY … ADD CONSTRAINT; everything else in it passed over") {
        let dump = """
            --
            -- PostgreSQL database dump
            --

            SET statement_timeout = 0;
            SET client_encoding = 'UTF8';
            SELECT pg_catalog.set_config('search_path', '', false);

            CREATE FUNCTION public.touch() RETURNS trigger
                LANGUAGE plpgsql
                AS $$
            BEGIN
              NEW.updated_at := now(); -- CREATE TABLE inside a body is no table;
              RETURN NEW;
            END;
            $$;

            CREATE TABLE public.orders (
                id uuid NOT NULL,
                total_cents integer NOT NULL
            );

            ALTER TABLE public.orders OWNER TO shop;

            CREATE TABLE public.payments (
                id uuid NOT NULL,
                order_id uuid NOT NULL,
                amount_cents integer
            );

            CREATE SEQUENCE public.payments_seq START WITH 1;
            COMMENT ON TABLE public.payments IS 'money; in';
            COPY public.orders (id, total_cents) FROM stdin;
            1\t500
            \\.
            ALTER TABLE ONLY public.orders
                ADD CONSTRAINT orders_pkey PRIMARY KEY (id);
            ALTER TABLE ONLY public.payments
                ADD CONSTRAINT payments_pkey PRIMARY KEY (id);
            ALTER TABLE ONLY public.payments
                ADD CONSTRAINT payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;
            ALTER TABLE ONLY public.payments ADD COLUMN refunded_at timestamptz, ADD CONSTRAINT one_amount UNIQUE (amount_cents);
            ALTER TABLE ONLY public.ghosts ADD COLUMN boo text;
            CREATE INDEX payments_order_idx ON public.payments USING btree (order_id);
            CREATE TRIGGER touch BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.touch();
            GRANT ALL ON TABLE public.orders TO shop;
            """
        let schema = SQLReader.read(dump)
        expectEqual(schema.tables.map(\.name), [SQLName("orders"), SQLName("payments")], "public. is dropped; ghosts was never made")
        let payments = try table(schema, "payments")
        expectEqual(payments.columns.map(\.name), ["id", "order_id", "amount_cents", "refunded_at"])
        expectEqual(payments.primaryKey, ["id"])
        expect((try column(payments, "id")).primaryKey)
        expectEqual(payments.keys, [SQLKey(column: "order_id", table: SQLName("orders"), targetColumn: "id")])
        expectEqual((try column(payments, "order_id")).onDelete, "cascade")
        expect((try column(payments, "amount_cents")).unique)
        expect((try column(payments, "amount_cents")).nullable)
        expectEqual(try table(schema, "orders").primaryKey, ["id"])
    },
    test("a pg_dump with data: the rows after COPY … FROM stdin are raw lines to \\., whatever quotes, comments and dollars they hold, and the keys written after them are read") {
        let dump = """
            CREATE TABLE public.people (id integer NOT NULL, name text);
            CREATE TABLE public.orders (id integer NOT NULL, person_id integer);
            COPY public.people (id, name) FROM stdin;
            1\tO'Brien
            2\t/usr/*
            3\t$x$ -- not a comment
            \\.

            COPY public.orders (id, person_id) FROM stdin;
            10\t1
            \\.

            ALTER TABLE ONLY public.people
                ADD CONSTRAINT people_pkey PRIMARY KEY (id);
            ALTER TABLE ONLY public.orders
                ADD CONSTRAINT orders_person_fkey FOREIGN KEY (person_id) REFERENCES public.people(id);
            """
        let schema = SQLReader.read(dump)
        expectEqual(schema.tables.map(\.name.name), ["people", "orders"])
        expectEqual(try table(schema, "people").primaryKey, ["id"], "the key after the data is read")
        expectEqual(try table(schema, "orders").keys, [SQLKey(column: "person_id", table: SQLName("people"), targetColumn: "id")])
        expectEqual(SQLReader.read("COPY t (a) FROM stdin;\n1\n'unterminated").isEmpty, true, "rows with no end run to the end of the text")
    },
    test("a comma inside brackets holds a column together: DEFAULT ARRAY[1, 2], and in an ALTER's actions") {
        let schema = SQLReader.read("""
            CREATE TABLE shapes (
              id int PRIMARY KEY,
              sizes int[] DEFAULT ARRAY[1, 2] NOT NULL,
              tags text[] DEFAULT ARRAY['a', 'b'],
              after_it text
            );
            ALTER TABLE shapes ADD COLUMN extra int[] DEFAULT ARRAY[3, 4], ADD COLUMN more int;
            """)
        let shapes = try table(schema, "shapes")
        expectEqual(shapes.columns.map(\.name), ["id", "sizes", "tags", "after_it", "extra", "more"])
        expectEqual((try column(shapes, "sizes")).default, "ARRAY[1, 2]")
        expectEqual((try column(shapes, "tags")).default, "ARRAY['a', 'b']")
        expectEqual((try column(shapes, "extra")).default, "ARRAY[3, 4]")
        expect(!(try column(shapes, "sizes")).nullable)
    },
    test("names: unquoted folded to lower case, quoted and backticked kept as written, schema.table and catalog.schema.table") {
        let schema = SQLReader.read("""
            CREATE TABLE Orders (ID UUID PRIMARY KEY, "CustomerId" uuid);
            CREATE TABLE "Line Items" ("Order" uuid REFERENCES Orders);
            CREATE TABLE `audit_log` (`Who` text) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
            CREATE TABLE billing.invoices (id serial PRIMARY KEY);
            CREATE TABLE shop.public.carts (id int);
            """)
        expectEqual(schema.tables.map(\.name.description), ["orders", "Line Items", "audit_log", "billing.invoices", "carts"])
        expectEqual(try table(schema, "orders").columns.map(\.name), ["id", "CustomerId"])
        expectEqual(try table(schema, "Line Items").keys, [SQLKey(column: "Order", table: SQLName("orders"), targetColumn: nil)])
        expectEqual(try table(schema, "audit_log").columns.map(\.name), ["Who"])
        expectEqual(try table(schema, "invoices").name.schema, "billing")
    },
    test("comments, -- and nested /* */, and strings, '…', E'…' and $tag$…$tag$, hold `;` and words that read as SQL without splitting a statement") {
        let schema = SQLReader.read("""
            /* a header; CREATE TABLE nope (x int);
               /* nested; */ still a comment; */
            CREATE TABLE notes ( -- the notes; CREATE TABLE no (y int);
              id int PRIMARY KEY,
              body text DEFAULT E'it\\'s; here',
              tag text DEFAULT $tag$a; b$tag$,
              other text DEFAULT $$c;$$
            );
            """)
        expectEqual(schema.tables.map(\.name.name), ["notes"])
        let notes = try table(schema, "notes")
        expectEqual(notes.columns.map(\.name), ["id", "body", "tag", "other"])
        expectEqual((try column(notes, "body")).default, "E'it\\'s; here'", "as written")
        expectEqual((try column(notes, "tag")).default, "$tag$a; b$tag$")
    },
    test("what it passes over: generated and identity clauses, COLLATE, MySQL's AUTO_INCREMENT, KEY and COMMENT, LIKE; other statements; one that doesn't read") {
        let schema = SQLReader.read("""
            CREATE TABLE items (
              id bigint GENERATED BY DEFAULT AS IDENTITY (START WITH 10) PRIMARY KEY,
              name text COLLATE "C" NOT NULL,
              price_cents int GENERATED ALWAYS AS (cost * 2) STORED,
              legacy_id int NOT NULL AUTO_INCREMENT COMMENT 'old; id',
              key varchar(20),
              KEY items_name (name),
              INDEX (price_cents),
              LIKE templates INCLUDING ALL
            );
            CREATE VIEW cheap AS SELECT * FROM items WHERE price_cents < 100;
            INSERT INTO items (name) VALUES ('CREATE TABLE x (y int)');
            CREATE TABLE broken;
            CREATE TABLE (no name int);
            CREATE TEMP TABLE IF NOT EXISTS scratch (id int);
            DROP TABLE items;
            """)
        expectEqual(schema.tables.map(\.name.name), ["items", "scratch"])
        let items = try table(schema, "items")
        expectEqual(items.columns.map(\.name), ["id", "name", "price_cents", "legacy_id", "key"])
        expectEqual(items.columns.map(\.type.words), ["bigint", "text", "int", "int", "varchar(20)"])
        expect((try column(items, "id")).primaryKey)
        expectEqual((try column(items, "id")).default, nil, "BY DEFAULT is the identity's, no default")
        expect(!(try column(items, "name")).nullable)
        expectEqual(SQLReader.read("SELECT 1; hello there;").isEmpty, true)
        expectEqual(SQLReader.read("").isEmpty, true)
    },
    test("the sniff: CREATE TABLE (temporary or unlogged too) or AS ENUM in any case in the first 64 KB, or a .sql file; prose, and SQL past 64 KB, no") {
        expect(SQLReader.sniffs("CREATE TABLE payments (id uuid)"))
        expect(SQLReader.sniffs("-- dump\ncreate\n  unlogged   table t (x int)"))
        expect(SQLReader.sniffs("create type s as  enum ('a')"))
        expect(!SQLReader.sniffs("We should create a table for payments"))
        expect(!SQLReader.sniffs("SELECT * FROM orders"))
        expect(!SQLReader.sniffs(String(repeating: "-- padding\n", count: 7_000) + "CREATE TABLE late (x int);"), "past the first 64 KB")
    },
])
