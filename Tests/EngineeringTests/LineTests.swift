import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import LineRows
import Selection
import TestKit
import TextEditing
import Titles

// A table's columns and an enum's values written a line each (LineRows), as the frames draw them: what a line offers as it's
// typed (T2: types after a name, the flags after a type), a pasted block, ⌥↑ ⌥↑, renaming and adding an enum's values (T4,
// panel 4), and a column's enum bound by name and its pill following the enum's rename. Keys sent to a real canvas in an
// unshown window.

/// The kit on a real canvas in an unshown window.
@MainActor
final class KitBench {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }
    let window: NSWindow
    let canvas: CanvasView

    init() throws {
        h = try kitHarness()
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = CanvasView(editor: h.editor)
        window.contentView = canvas
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    }

    var view: LineRowsView? { canvas.descendants(LineRowsView.self).first }
    var field: LineField { view!.field }

    func begin(_ id: ShapeID) {
        editor.selectedShapeIDs = [id]
        editor.beginEditing(id)
        window.settle()
    }

    func press(_ chord: Chord, times: Int = 1) {
        for _ in 0..<times {
            window.press(chord)
            window.settle()
        }
    }

    func type(_ text: String) {
        window.type(text)
        window.settle()
    }

    func columns(_ id: ShapeID) -> [Column] { editor.document[id]?.typed(as: DatabaseTable.self)?.props.columns ?? [] }
    func lines(_ id: ShapeID) -> [String] { columns(id).map(ColumnGrammar.print) }
    func values(_ id: ShapeID) -> [String] { editor.document[id]?.typed(as: DatabaseEnum.self)?.props.values.map(\.text) ?? [] }
    var undoName: String? { editor.undoHistory.undoName }

    /// A table titled `name` holding `lines`, in a step of its own.
    @discardableResult
    func table(_ name: String, _ lines: [String], at origin: CGPoint = CGPoint(x: 100, y: 100)) -> ShapeID {
        let id = h.add(DatabaseTable(frame: CGRect(origin: origin, size: CGSize(width: 300, height: 100)), columns: lines.compactMap { ColumnGrammar.read($0) }),
                       titled: name)
        editor.undoHistory.seal()
        return id
    }

    @discardableResult
    func enumType(_ name: String, _ values: [String], at origin: CGPoint = CGPoint(x: 500, y: 100)) -> ShapeID {
        let id = h.add(DatabaseEnum(frame: CGRect(origin: origin, size: CGSize(width: 220, height: 100)), values: values.map { EnumValue(text: $0) }),
                       titled: name)
        editor.undoHistory.seal()
        return id
    }
}

/// A bitmap as PNG data, for two renders to be held equal.
@MainActor func pngOf(_ rep: NSBitmapImageRep) throws -> Data {
    try require(rep.representation(using: .png, properties: [:]))
}

/// A corpus of column lines, each a way a person writes one.
let columnCorpus = [
    "id uuid pk", "customer_id uuid", "email text unique", "description text?", "placed_at timestamptz null", "currency char(3)",
    "price numeric(10, 2) default 0", "updated_at timestamptz default now()", "id bigint primary key", "note text not null",
    "status order_status", "customer_id uuid → customers.id", "customer_id uuid -> customers.id unique", "flag bool default 'a b' pk",
    "legacy text whatever words follow", "id", "x int NULL UNIQUE PK",
]

@MainActor let lineTests = Suite("Columns and values written as lines", [
    test("the column grammar's corpus and the enum's: printing what was read reads back the same, and keeps the unread in order") {
        let b = try KitBench()
        let table = b.table("orders", ["id uuid pk"])
        let context = LineContext(editor: b.editor, shape: table)
        let grammar = try require(b.editor.registry.lineRows(of: DatabaseTable.kind))
        expectEqual(grammar.noun.plural, "columns")
        let lost = TestColumnGrammar.grammar.losses(in: columnCorpus, unread: { $0.unread.split(separator: " ").map(String.init) }, in: context)
        expect(lost.isEmpty, "lost: \(lost)")
        let values = TestColumnGrammar.values.losses(in: ["pending", "  paid  ", "refunded twice"], unread: { $0.text.split(separator: " ").map(String.init) }, in: context)
        expect(values.isEmpty, "lost: \(values)")
    },
    test("T2: `total_cents in` offers int, int8, integer, interval, inet first; after a type and a space, null, unique, default, pk and →") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "customer_id uuid"])
        b.begin(orders)
        b.type("total_cents in")
        expectEqual(Array(b.field.listedOffers.prefix(5)), ["int", "int8", "integer", "interval", "inet"])
        b.press(.tab)
        expectEqual(b.field.string, "total_cents int", "Tab picks")
        b.press(.return)
        expectEqual(b.lines(orders).last, "total_cents int")
        expectEqual(b.undoName, "Add Column")
        b.type("placed_at timestamptz ")
        expectEqual(b.field.listedOffers, ["null", "unique", "default", "pk", "→"])
        expectEqual(b.field.highlightedOffer, "null")
        b.press(.return)
        expectEqual(b.lines(orders).last, "placed_at timestamptz", "Return commits the line, never the highlighted word")
        b.type("email text unique ")
        expectEqual(b.field.listedOffers, ["null", "default", "pk", "→"], "what the line says already isn't offered")
    },
    test("the file's enums are offered after a name, each a purple chip lit on the board while it's highlighted; picked, the column is bound to it") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending", "paid"])
        let orders = b.table("orders", ["id uuid pk"])
        b.begin(orders)
        b.type("status order")
        expectEqual(b.field.listedOffers.first, "order_status")
        expectEqual(b.editor.service(LineRowsService.self)?.light, PartAddress(status), "the enum is lit")
        b.press(.tab)
        expectEqual(b.field.line.references.map(\.target), [PartAddress(status)], "the pick stands for the enum")
        expect(b.field.highlights.contains { $0.range == NSRange(location: 7, length: 12) }, "its pill under its name")
        b.press(.return)
        expectEqual(b.columns(orders).last?.type, TypeRef("order_status", shape: status))
        expectEqual(b.editor.service(LineRowsService.self)?.light, nil)
    },
    test("an enum-typed column is bound to the enum it names, the nearest by name: on its board first; its pill follows the enum's rename") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending"])
        let orders = b.table("orders", ["id uuid pk"])
        b.begin(orders)
        b.type("status order_status")
        b.press(.return)
        b.press(.escape)
        expectEqual(b.columns(orders).last?.type.shape, status, "typed, it's found by name")
        b.editor.transact { $0.update(status) { $0[TitleProperty.self] = "order_state" } }
        let before = b.undoName
        b.begin(orders)
        b.press(.up)
        expectEqual(b.field.string, "status order_state", "its line says the enum's name now")
        b.press(.escape)
        expectEqual(b.columns(orders).last?.type, TypeRef("order_status", shape: status), "an unchanged line keeps naming it, as stored")
        expectEqual(b.undoName, before, "and passing through it writes no step: the line was as it was shown")
        // The pill, at rest, says the enum's name now: as it does where the enum was called so all along.
        let renamed = try pngOf(render(b.editor))
        let other = try KitBench()
        other.enumType("order_state", ["pending"])
        let table = other.table("orders", ["id uuid pk"])
        other.begin(table)
        other.type("status order_state")
        other.press(.return)
        other.press(.escape)
        expect(renamed == (try pngOf(render(other.editor))), "the table drawn after the rename is the table drawn with the enum so named")
        // Only what the person changed names the step: the name alone, on a row whose enum was renamed under it.
        b.begin(orders)
        b.press(.up)
        b.field.setSelectedRange(NSRange(location: 0, length: 6))
        b.type("state")
        b.press(.down)
        expectEqual(b.columns(orders).last?.name, "state")
        expectEqual(b.undoName, "Rename Column", "a rename, though its type reads differently than stored")
        b.press(.escape)
        expectEqual(b.editor.shapeContext.frame(of: try require(b.editor.document[orders]))?.height, KitStyle.height(rows: 2))
    },
    test("the title's ring shows only while its text has the keys; a press on its chip from a row puts the caret there, and Tab goes on from it to the first row") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "sku text"])
        b.begin(orders)
        let view = try require(b.view), title = try require(view.titleField)
        b.press(.up)
        expect(!title.hasKeys, "a row has the keys")
        // The strip just left of the chip, where its ring is drawn: what's in it as the view draws it.
        let strip = { @MainActor () throws -> [[Int]] in
            let area = view.convert(title.frame, from: title.superview).insetBy(dx: -4, dy: -4)
            let rep = try require(view.bitmapImageRepForCachingDisplay(in: area))
            view.cacheDisplay(in: area, to: rep)
            let scale = CGFloat(rep.pixelsWide) / area.width
            return (0..<Int(area.height * scale)).flatMap { y in (0..<Int(3 * scale)).map { x in pixel(rep, at: CGPoint(x: x, y: y)) } }
        }
        let plain = try strip()
        b.window.makeFirstResponder(title.field)
        b.window.settle()
        expectEqual(view.focus, .title, "the session follows the keys")
        expect(title.hasKeys)
        expect(try strip() != plain, "the ring is drawn while its text has the keys, and not while a row has them")
        b.press(.tab)
        expectEqual(view.focus, .row(b.columns(orders)[0].id), "Tab goes on from the title, not from the row the caret left")
        expect(!title.hasKeys)
    },
    test("T2, panel 3: ten lines pasted into products are ten rows, one step, Paste Columns, the caret at the end of the last") {
        let b = try KitBench()
        let products = b.table("products", ["id uuid pk"])
        b.begin(products)
        let block = ["sku text unique", "title text", "description text?", "currency char(3)", "price_cents int", "active bool", "stock int",
                     "weight_grams int", "created_at timestamptz", "updated_at timestamptz default now()"]
        b.field.paste(text: block.joined(separator: "\n"))
        expectEqual(b.lines(products), ["id uuid pk"] + block.map { ColumnGrammar.print(ColumnGrammar.read($0)!) })
        expectEqual(b.undoName, "Paste Columns")
        expectEqual(b.field.string, "updated_at timestamptz default now()")
        expectEqual(b.field.selectedRange().location, ("updated_at timestamptz default now()" as NSString).length)
        b.editor.undo()
        expectEqual(b.lines(products), ["id uuid pk"], "one step")
    },
    test("T2, panel 4: ⌥↑ ⌥↑ on price_cents moves it up two places, one step, Move Column") {
        let b = try KitBench()
        let products = b.table("products", ["id uuid pk", "sku text unique", "title text", "description text?", "currency char(3)", "price_cents int"])
        b.begin(products)
        b.press(.up)
        expectEqual(b.field.string, "price_cents int")
        b.press(Chord(Key.up, .option), times: 2)
        expectEqual(b.columns(products).map(\.name), ["id", "sku", "title", "price_cents", "description", "currency"])
        expectEqual(b.undoName, "Move Column")
        b.editor.undo()
        expectEqual(b.columns(products).map(\.name), ["id", "sku", "title", "description", "currency", "price_cents"], "the two moves, one step")
    },
    test("a column's commit is named by what changed: Rename Column for its name alone, Change Column for its type; Delete Column by ⌘⌫ then ⌫") {
        let b = try KitBench()
        let refunds = b.table("refunds", ["id uuid pk", "payment_id uuid", "amount_cents int"])
        b.begin(refunds)
        b.press(.up, times: 2)
        b.field.setSelectedRange(NSRange(location: ("payment_id " as NSString).length, length: 4))
        b.type("int")
        b.press(.down)
        expectEqual(b.lines(refunds)[1], "payment_id int")
        expectEqual(b.undoName, "Change Column")
        b.field.setSelectedRange(NSRange(location: 0, length: 6))
        b.type("total")
        b.press(.up)
        expectEqual(b.lines(refunds)[2], "total_cents int")
        expectEqual(b.undoName, "Rename Column")
        b.field.setSelectedRange(NSRange(location: (b.field.string as NSString).length, length: 0))
        b.press(Chord(Key.delete, .command))
        b.press(.delete)
        expectEqual(b.columns(refunds).map(\.name), ["id", "total_cents"])
        expectEqual(b.undoName, "Delete Column")
    },
    test("T4, panel 4: in order_status, cancelled renamed canceled, Rename Value; ↩ after refunded, returned typed, Add Value") {
        let b = try KitBench()
        let status = b.enumType("order_status", ["pending", "paid", "shipped", "delivered", "cancelled", "refunded"])
        b.begin(status)
        b.press(.up, times: 2)
        expectEqual(b.field.string, "cancelled")
        b.field.setSelectedRange(NSRange(location: 5, length: 1))
        b.press(.delete)
        b.press(.down)
        expectEqual(b.values(status), ["pending", "paid", "shipped", "delivered", "canceled", "refunded"])
        expectEqual(b.undoName, "Rename Value")
        expectEqual(b.field.string, "refunded")
        b.press(.return)
        b.type("returned")
        b.press(.return)
        expectEqual(b.values(status).last, "returned")
        expectEqual(b.undoName, "Add Value")
        b.press(.return)
        expectEqual(b.editor.editingShapeID, nil, "↩ on the empty line ends it")
    },
    test("VoiceOver: the editing view is Columns of orders, a row Column 2 of 2 with its line and its reading") {
        let b = try KitBench()
        let orders = b.table("orders", ["id uuid pk", "email text unique"])
        b.begin(orders)
        let view = try require(b.view)
        expectEqual(view.accessibilityLabel(), "Columns of orders")
        let children = try require(view.accessibilityChildren())
        expectEqual((children.first as? NSTextView)?.accessibilityLabel(), "Table name", "the title first")
        let email = try require(children[2] as? NSAccessibilityElement)
        expectEqual(email.accessibilityLabel(), "Column 2 of 2")
        expectEqual(email.accessibilityValue() as? String, "email text unique")
        expectEqual(email.accessibilityHelp(), "email, text, unique")
        expectEqual(b.field.accessibilityLabel(), "New column")
    },
])

/// The kit's grammars, as a test reaches them: through the registry's lineRows, a table's model reads its lines.
@MainActor
enum TestColumnGrammar {
    static var grammar: any LineGrammar<Column> { EngineeringLines.columns }
    static var values: any LineGrammar<EnumValue> { EngineeringLines.values }
}
