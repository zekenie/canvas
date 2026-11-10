import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Draw
import DrawScript
import Engineering
import Find
import Geometry
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// A line reads back what it prints, and what's shown at rest agrees with editing: a pasted column of several words (a type,
// a default, a name, an enum's name) edited on its line keeps every word; the card writes such a type and default whole; two
// enums of one name in two databases are told apart, typing binding the one in the table's own; a column whose words name an
// enum made later is that enum's pill at rest, as on its line; and an enum's values widen it to read whole.

extension KitBench {
    /// The caret on `table`'s column `name`, editing it.
    func go(to table: ShapeID, column name: String) throws {
        if editor.editingShapeID != table { begin(table) }
        view?.go(to: .row(try require(columns(table).first { $0.name == name }?.id, "no column \(name)")))
        window.settle()
    }

    /// A table titled `name` holding `columns` as given, in a step of its own.
    @discardableResult
    func table(_ name: String, columns: [Column], at origin: CGPoint = CGPoint(x: 100, y: 100)) -> ShapeID {
        let id = h.add(DatabaseTable(frame: CGRect(origin: origin, size: CGSize(width: 300, height: 100)), columns: columns), titled: name)
        editor.undoHistory.seal()
        return id
    }
}

@MainActor let wholeLineTests = Suite("A line reads back what it prints; rest agrees with editing", [
    test("a pasted column of several words, renamed on its line, keeps its type, its default and its enum: Rename Column") {
        let b = try KitBench()
        let status = b.enumType("Order Status", ["new", "paid"])
        let held = [
            Column(name: "created_at", type: TypeRef("timestamp with time zone"), default: "''::character varying"),
            Column(name: "order date", type: TypeRef("Order Status", shape: status), nullable: true),
            Column(name: "due", type: TypeRef("date"), default: "now() + interval '1 day'"),
            Column(name: "label", type: TypeRef("varchar(255) binary")),
        ]
        let items = b.table("Line Items", columns: held)
        try b.go(to: items, column: "created_at")
        expectEqual(b.field.string, "created_at timestamp with time zone default ''::character varying", "printed as SQL writes it")
        b.field.setSelectedRange(NSRange(location: 0, length: 7))
        b.type("made")
        b.press(.down)
        expectEqual(b.undoName, "Rename Column")
        var renamed = held[0]
        renamed.name = "made_at"
        renamed.id = b.columns(items)[0].id
        expectEqual(b.columns(items)[0], renamed, "every word as it was")
        expectEqual(b.field.string, "\"order date\" \"Order Status\" null", "a name and an enum's of several words quoted")
        expectEqual(b.field.line.references.map(\.target), [PartAddress(status)], "the enum's name stands for it")
        expect(b.field.highlights.contains { $0.range == NSRange(location: 14, length: 12) }, "its pill under its name, the quotes outside")
        b.field.setSelectedRange(NSRange(location: 1, length: 5))
        b.type("placed")
        b.press(.down)
        expectEqual(b.undoName, "Rename Column")
        expectEqual(b.columns(items)[1].name, "placed date")
        expectEqual(b.columns(items)[1].type, TypeRef("Order Status", shape: status), "still the enum's")
        expectEqual(b.field.string, "due date default \"now() + interval '1 day'\"")
        b.field.setSelectedRange(NSRange(location: 0, length: 3))
        b.type("due_on")
        b.press(.down)
        expectEqual(b.columns(items)[2].default, "now() + interval '1 day'")
        expectEqual(b.field.string, "label \"varchar(255) binary\"", "a type SQL's words don't explain, quoted")
        b.field.setSelectedRange(NSRange(location: 0, length: 5))
        b.type("tag")
        b.press(.down)
        expectEqual(b.columns(items)[3].type.words, "varchar(255) binary")
        expectEqual(b.undoName, "Rename Column")
        b.press(.escape)
    },
    test("typed as SQL writes them: timestamp with time zone, double precision, character varying(255)? and a cast default are each one part") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk"])
        b.begin(orders)
        for line in ["placed_at timestamp with time zone not null default now()", "ratio double precision",
                     "note character varying(255)? default ''::character varying"] {
            b.type(line)
            b.press(.return)
        }
        b.press(.escape)
        expectEqual(b.columns(orders).dropFirst().map(\.type.words), ["timestamp with time zone", "double precision", "character varying(255)"])
        expectEqual(b.columns(orders).dropFirst().map(\.unread), ["", "", ""], "no word left over")
        expectEqual(b.columns(orders).last?.nullable, true)
        expectEqual(b.columns(orders).last?.default, "''::character varying")
    },
    test("the card writes a type and a default of several words whole, and a spaced enum's name binds it") {
        let b = try KitBench()
        let status = b.enumType("Order Status", ["new"])
        let orders = b.table("orders", ["id uuid pk", "state text"])
        let card = try b.openCard(orders, column: "state")
        try require(card.field(of: "type")).selectAll(nil)
        b.type("timestamp with time zone")
        if card.field(of: "type")?.offerList != nil { b.press(.escape) }
        b.press(.down)
        expectEqual(b.columns(orders).last?.type.words, "timestamp with time zone")
        expectEqual(b.columns(orders).last?.unread, "")
        card.go(to: "default")
        b.type("now() + interval '1 day'")
        b.press(.tab)
        expectEqual(b.columns(orders).last?.default, "now() + interval '1 day'")
        expectEqual(b.columns(orders).last?.type.words, "timestamp with time zone", "the type kept whole by a default's change")
        card.go(to: "type")
        try require(card.field(of: "type")).selectAll(nil)
        b.type("Order")
        expectEqual(card.field(of: "type")?.listedOffers.first, "Order Status")
        b.press(.tab)
        expectEqual(card.field(of: "type")?.string, "\"Order Status\"", "picked, quoted as the line reads it")
        b.press(.tab)
        expectEqual(b.columns(orders).last?.type, TypeRef("Order Status", shape: status))
        expectEqual(b.lines(orders).last, "state \"Order Status\" default \"now() + interval '1 day'\"")
        b.press(.escape)
    },
    test("two enums of one name in two databases: typing binds the one in the table's database; both offered, each saying where") {
        let b = try KitBench()
        let billing = b.h.add(Database(frame: CGRect(x: 0, y: 0, width: 400, height: 300)), titled: "billing")
        let shop = b.h.add(Database(frame: CGRect(x: 500, y: 0, width: 500, height: 600)), titled: "shop")
        let paid = b.enumType("status", ["paid", "refunded"], at: CGPoint(x: 40, y: 60))
        let sold = b.enumType("status", ["new", "sold"], at: CGPoint(x: 540, y: 400))
        let orders = b.table("orders", ["id uuid pk"], at: CGPoint(x: 540, y: 60))
        b.editor.transact {
            $0.setContainer(paid, to: billing)
            $0.setContainer(sold, to: shop)
            $0.setContainer(orders, to: shop)
        }
        b.editor.undoHistory.seal()
        b.begin(orders)
        b.type("state stat")
        let listed = Array(zip(b.field.listedOffers, b.field.listedDetails).filter { $0.0 == "status" })
        expectEqual(listed.map(\.1).sorted(), ["Enum · billing", "Enum · shop"], "both, each where it is")
        b.type("us")
        b.press(.return)
        expectEqual(b.columns(orders).last?.type, TypeRef("status", shape: sold), "the one in its own database, not the first made")
        b.press(.escape)
    },
    test("a column whose words name an enum made later is its pill at rest, as on its line; and again once it's deleted and made anew") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "state order_status"])
        @MainActor func drawn(_ bench: KitBench) throws -> Data {
            bench.editor.selectedShapeIDs = []
            return try pngOf(render(bench.editor))
        }
        let words = try drawn(b)
        let status = b.enumType("order_status", ["pending", "paid"], at: CGPoint(x: 1200, y: 100))
        let late = try drawn(b)
        expect(late != words, "made later, the type is its pill at rest")
        // The same column bound when it was typed draws the same.
        let bound = try KitBench()
        let boundStatus = bound.enumType("order_status", ["pending", "paid"], at: CGPoint(x: 1200, y: 100))
        bound.table("orders", columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true), Column(name: "state", type: TypeRef("order_status", shape: boundStatus))])
        expect(late == (try drawn(bound)), "drawn as a column bound to it is")
        b.begin(orders)
        b.press(.up)
        expect(b.field.highlights.contains { $0.range == NSRange(location: 6, length: 12) }, "its line says the same: the enum's pill")
        b.press(.escape)
        b.editor.transact("Delete") { $0.delete(Set([status])) }
        expect((try drawn(b)) == words, "gone, words again")
        b.enumType("order_status", ["pending"], at: CGPoint(x: 1200, y: 100))
        expect((try drawn(b)) == late, "made anew, its pill again")
    },
    test("an enum's values widen it to read whole as each is committed, never narrower, at most a table's widest") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending"])
        let width = { b.editor.document[status]?.box?.width ?? 0 }
        let initial = width()
        b.begin(status)
        b.type("awaiting_customer_confirmation_of_the_shipping_address")
        b.press(.return)
        let whole = width()
        expect(whole > initial && whole <= 560, "\(initial) → \(whole)")
        expectEqual(b.undoName, "Add Value")
        b.type("x")
        b.press(.return)
        expectEqual(width(), whole)
        b.press(.escape)
    },
    test("an enum is as wide as its name reads in its pill down to 50%: a commit of its values widens it so, never narrower (UX walk 5 paste-5-1)") {
        let b = try KitBench()
        let methods = b.enumType("payment_method", ["card"])
        let record = { try require(b.editor.document[methods]) }
        // The name's pill at 100%, view points; at a zoom z the enum is z × its width on screen, and the pill is cut past that.
        let pill = b.editor.adornmentLeastWidth(of: try record())
        expect(pill > 0, "the pill is measured")
        // Put in with its name it is as wide as the name reads already (the title's rule); narrowed by hand, a new enum's 220
        // cuts the name at 50%, and a commit of its values widens it so.
        let initial = try require(record().box).width
        expect(initial * KitStyle.roomKeptZoom >= pill - 0.5, "put in with its name, wide enough: \(initial), the pill \(pill)")
        b.editor.transact("Resize") { $0.update(methods) { $0.box = CGRect(x: 500, y: 100, width: 220, height: 100) } }
        expect(220 * KitStyle.roomKeptZoom < pill, "a new enum's 220 cuts the name at 50%: the pill \(pill)")
        b.begin(methods)
        b.type("cash")
        b.press(.return)
        b.press(.escape)
        let whole = try require(record().box).width
        expect(whole * KitStyle.roomKeptZoom >= pill - 0.5, "the name reads whole at 50%: \(whole), the pill \(pill)")
        expectEqual(b.undoName, "Add Value", "in the value's step")
        // A short name leaves the width to its values, a new enum's at least.
        let status = b.enumType("status", ["new"], at: CGPoint(x: 100, y: 500))
        b.begin(status)
        b.type("old")
        b.press(.return)
        b.press(.escape)
        expectEqual(b.editor.document[status]?.box?.width, 220)
    },
    test("an enum renamed (a name typed in its pill, /title) is as wide as the new name reads at 50%, in the rename's own step, and keeps a width it was given (U14-E3)") {
        let b = try KitBench()
        let methods = b.enumType("method", ["card"])
        let fresh = try require(b.editor.document[methods]?.box).width
        b.editor.transact("Rename") { $0.update(methods) { $0[TitleProperty.self] = "payment_method_chosen_at_checkout" } }
        let renamed = try require(b.editor.document[methods])
        let pill = b.editor.adornmentLeastWidth(of: renamed)
        let width = try require(renamed.box).width
        expect(width > fresh, "wider than a new enum's \(fresh): \(width)")
        expect(width * KitStyle.roomKeptZoom >= pill - 0.5, "the name reads whole at 50%: \(width), the pill \(pill)")
        expectEqual(b.undoName, "Rename")
        b.editor.undo()
        expectEqual(b.editor.document[methods]?.box?.width, fresh, "one step back")
        // A shorter name leaves the width as it is.
        b.editor.redo()
        b.editor.transact("Rename") { $0.update(methods) { $0[TitleProperty.self] = "m" } }
        expectEqual(b.editor.document[methods]?.box?.width, width)
    },
    test("only a line's first → is a key's: its target in the pill, a later → and its target plain; a first that names no table leaves none") {
        let b = try KitBench()
        b.table("customers", ["id uuid pk"])
        b.table("accounts", ["id uuid pk"], at: CGPoint(x: 100, y: 400))
        let orders = b.table("orders", ["id uuid pk"], at: CGPoint(x: 500, y: 100))
        b.begin(orders)
        b.type("ref_id uuid -> customers.id -> accounts.id")
        let text = b.field.string as NSString
        let first = text.range(of: "customers.id"), second = text.range(of: "accounts.id")
        expect(b.field.highlights.contains { $0.range == first }, "the first target in its pill")
        expect(!b.field.highlights.contains { $0.range == second }, "a later one is words")
        b.press(.return)
        b.type("a_id uuid -> nowhere.x -> customers.id")
        let none = (b.field.string as NSString).range(of: "customers.id")
        expect(!b.field.highlights.contains { $0.range == none }, "the first names nothing: the line has no key, and no pill")
        b.press(.escape)
    },
    test("two enums of one name loose on one board are offered once, and the pick is the one typing binds; two tables the same") {
        let b = try KitBench()
        let one = b.enumType("status", ["new"], at: CGPoint(x: 600, y: 100))
        let two = b.enumType("status", ["paid"], at: CGPoint(x: 600, y: 400))
        let first = [one, two].min { $0.description < $1.description }
        b.table("users", ["id uuid pk"], at: CGPoint(x: 100, y: 400))
        b.table("users", ["id uuid pk"], at: CGPoint(x: 100, y: 700))
        let orders = b.table("orders", ["id uuid pk"], at: CGPoint(x: 100, y: 100))
        b.begin(orders)
        b.type("state stat")
        expectEqual(b.field.listedOffers.filter { $0 == "status" }.count, 1, "alike, offered once")
        b.type("us")
        b.press(.tab)
        b.press(.return)
        expectEqual(b.columns(orders).last?.type.shape, first, "the one typing binds")
        b.type("owner uuid -> us")
        expectEqual(b.field.listedOffers.filter { $0 == "users.id" }.count, 1, "two tables alike, offered once")
        b.press(.escape)
    },
    test("a key to a column whose name has a space is printed and read as one word; the row renamed keeps its words and its target's") {
        let b = try KitBench()
        b.table("customers", ["id uuid pk", "\"first name\" text unique"])
        let orders = b.table("orders", ["id uuid pk"], at: CGPoint(x: 500, y: 100))
        b.begin(orders)
        b.type("buyer uuid -> customers.\"first name\" later")
        expectEqual(b.field.string, "buyer uuid → customers.\"first name\" later")
        b.press(.return)
        expectEqual(b.columns(orders).last?.unread, "→ customers.\"first name\" later", "one key's words, kept as the line says them")
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 0, length: 5))
        b.type("owner")
        b.press(.down)
        expectEqual(b.columns(orders).last?.unread, "→ customers.\"first name\" later")
        expectEqual(b.undoName, "Rename Column")
        b.press(.escape)
    },
    test("a column's type cleared in its card keeps the words it had after it; a quoted default in the card is the words between the quotes") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "price numeric check (price > 0)"])
        let card = try b.openCard(orders, column: "price")
        try require(card.field(of: "type")).selectAll(nil)
        b.press(.delete)
        if card.field(of: "type")?.offerList != nil { b.press(.escape) }
        b.press(.escape)
        expectEqual(b.columns(orders).last?.type.words, "", "no type")
        expectEqual(b.columns(orders).last?.unread, "check (price > 0)", "the words after it still words")
        let again = try b.openCard(orders, column: "price")
        again.go(to: "default")
        b.type("\"x y\"")
        b.press(.tab)
        expectEqual(b.columns(orders).last?.default, "x y", "as its line reads a quoted default")
        expectEqual(b.lines(orders).last, "price default \"x y\" check (price > 0)")
        b.press(.escape)
    },
    test("a column's words that name an enum made later are its pill in Find too, and follow the enum's rename away and back") {
        let h = try EditorHarness(plugins: kitPlugins(find: true))
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        h.editor.turn(EngineeringKit.self, on: true)
        let table = h.add(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 100), columns: ["id uuid pk", "state order_status"].compactMap { ColumnGrammar.read($0) }),
                          titled: "orders")
        let find = try require(h.editor.find)
        find.open()
        find.query = "order_status"
        @MainActor func settle() throws {
            var turns = 0
            while find.isIndexing, turns < 10_000 {
                h.wait(0)
                turns += 1
            }
            _ = try awaitResult { await find.settled() }
        }
        try settle()
        expect(find.texts(of: table).contains("state order_status"), "plain words: \(find.texts(of: table))")
        let status = h.add(DatabaseEnum(frame: CGRect(x: 600, y: 100, width: 200, height: 0), values: [EnumValue(text: "new")]), titled: "order_status")
        try settle()
        expect(find.texts(of: table).contains("order_status") && find.texts(of: table).contains("state") && !find.texts(of: table).contains("state order_status"),
               "its pill once the enum is made: \(find.texts(of: table))")
        h.editor.transact("Rename") { $0.update(status) { $0[TitleProperty.self] = "other" } }
        try settle()
        expect(find.texts(of: table).contains("state order_status"), "words again once the enum's name isn't theirs: \(find.texts(of: table))")
        h.editor.transact("Rename") { $0.update(status) { $0[TitleProperty.self] = "order_status" } }
        try settle()
        expect(find.texts(of: table).contains("state") && !find.texts(of: table).contains("state order_status"), "a pill again: \(find.texts(of: table))")
    },
    test("such a column is its pill zoomed out and as wide as a bound one's pill reads, and VoiceOver says its enum as the screen shows it") {
        let long = "customer_order_fulfilment_status_of_the_shipment"
        @MainActor func skeleton(_ b: KitBench) throws -> Data {
            b.editor.camera = Camera(origin: .zero, zoom: 0.3)
            b.editor.selectedShapeIDs = []
            expect(b.editor.drawsSkeletons)
            return try pngOf(render(b.editor, size: CGSize(width: 600, height: 500)))
        }
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "state \(long)"])
        let words = try skeleton(b)
        let status = b.enumType(long, ["new"], at: CGPoint(x: 5000, y: 100))
        let late = try skeleton(b)
        expect(late != words, "a pill's bar zoomed out, not words'")
        let bound = try KitBench()
        let boundStatus = bound.enumType(long, ["new"], at: CGPoint(x: 5000, y: 100))
        let held = bound.table("orders", columns: [Column(name: "id", type: TypeRef("uuid"), primaryKey: true), Column(name: "state", type: TypeRef(long, shape: boundStatus))])
        expect(late == (try skeleton(bound)), "the same bar as a column bound to it")
        // Width: a commit widens each as its pill reads whole.
        b.editor.camera = Camera(origin: .zero, zoom: 1)
        bound.editor.camera = Camera(origin: .zero, zoom: 1)
        for bench in [(b, orders), (bound, held)] {
            bench.0.begin(bench.1)
            bench.0.type("x int")
            bench.0.press(.return)
            bench.0.press(.escape)
        }
        let width = { (bench: KitBench, id: ShapeID) in bench.editor.document[id]?.box?.width ?? 0 }
        expectEqual(width(b, orders), width(bound, held), "as wide as the bound column's pill reads")
        expect(width(b, orders) > 260, "widened: \(width(b, orders))")
        // What VoiceOver says of the row: the enum while the screen shows its pill.
        let state = try require(b.columns(orders).first { $0.name == "state" })
        let context = LineContext(editor: b.editor, shape: orders, row: state.id)
        expectEqual(EngineeringLines.columns.spoken(ColumnLine(state), in: context), "state, \(long) enum")
        b.editor.transact("Delete Enum") { $0.delete(Set([status])) }
        expectEqual(EngineeringLines.columns.spoken(ColumnLine(state), in: context), "state, \(long)", "words once the enum is gone")
    },
    test("SQL's types of several words are offered once typed into past their first word, and a pick replaces the type from its first word; a flag isn't offered in the middle of one") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk"])
        b.begin(orders)
        b.type("ratio doub")
        expect(!b.field.listedOffers.contains("double precision"), "its first word not whole yet: \(b.field.listedOffers)")
        b.type("le p")
        expect(b.field.listedOffers.contains("double precision"), "\(b.field.listedOffers)")
        b.type("re")
        expectEqual(b.field.listedOffers.first, "double precision")
        expect(!b.field.listedOffers.contains("pk"), "the type's second word isn't a flag's place")
        b.press(.tab)
        expectEqual(b.field.string, "ratio double precision")
        b.press(.return)
        expectEqual(b.columns(orders).last?.type.words, "double precision")
        b.type("at timestamp wi")
        expect(b.field.listedOffers.contains("timestamp with time zone"), "\(b.field.listedOffers)")
        b.press(.tab)
        expectEqual(b.field.string, "at timestamp with time zone")
        b.press(.escape)
    },
    test("types are offered in one word: scattered letters offer no spelling of several words, nor a long one beside its short name (UX walk 4 tables-4-3)") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk"])
        b.begin(orders)
        b.type("id u")
        let u = b.field.listedOffers
        expect(u.contains("uuid") && !u.contains { $0.contains(" ") }, "\(u)")
        b.field.setSelectedRange(NSRange(location: 0, length: (b.field.string as NSString).length))
        b.type("created_at time")
        let time = b.field.listedOffers
        expect(time.contains("timestamptz") && time.contains("timetz") && !time.contains { $0.contains(" ") }, "\(time)")
        expectEqual(Set(time).count, time.count, "each once")
        b.field.setSelectedRange(NSRange(location: 0, length: (b.field.string as NSString).length))
        b.type("total in")
        let typed = b.field.listedOffers
        expect(typed.contains("integer") && !typed.contains { $0.contains(" ") }, "T2's one-word types, none of several words: \(typed)")
        b.field.setSelectedRange(NSRange(location: 0, length: (b.field.string as NSString).length))
        b.type("created_at timestamp w")
        expectEqual(Set(b.field.listedOffers.filter { $0.contains(" ") }), ["timestamp with time zone", "timestamp without time zone"])
        b.press(.escape)
        b.press(.escape)
    },
    test("a table widened to its longest name and type keeps the gap a row keeps at the default width between them (UX walk 4 firstminute-4-4)") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk"])
        b.editor.camera = Camera(origin: .zero, zoom: 1)
        let name = "billing_address_line_one_and_then_some", type = "text"
        b.begin(orders)
        b.type("\(name) \(type)")
        b.press(.return)
        b.press(.escape)
        let width = try require(b.editor.document[orders]?.box?.width)
        let nameWidth = NSAttributedString(string: name, attributes: [.font: KitStyle.nameFont]).size().width
        let typeWidth = NSAttributedString(string: type, attributes: [.font: KitStyle.typeFont]).size().width
        expect(width >= KitStyle.nameInset + nameWidth + KitStyle.wholeGap + typeWidth + KitStyle.trailingInset - 2,
               "\(width) holds the name \(nameWidth), the gap \(KitStyle.wholeGap) and the type \(typeWidth)")
    },
    test("a shape put below a table, with no gap said, lands past the room the table keeps below it, as draw's solver spaces it (UX walk 4 paste-4-1)") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk"])
        let bounds = try require(b.editor.shapeContext.geometry(of: orders)?.bounds)
        let surroundings = try require(Surroundings(on: b.editor.board, moving: CGSize(width: 100, height: 40), in: b.editor))
        let below = try require(surroundings.near(orders, sides: [.below])?.rect)
        expect(below.minY - bounds.maxY >= KitStyle.roomKeptBelow - 0.5, "\(below.minY - bounds.maxY) under it, the room is \(KitStyle.roomKeptBelow)")
    },
])
