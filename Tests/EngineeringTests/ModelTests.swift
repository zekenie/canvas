import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Engineering
import Foundation
import Selection
import SlashCommands
import TestKit
import Titles

// The kinds as they're kept and laid out: the registry's lines, a table, an enum and a database written and read back as
// they were, a table's width its own and its height its rows', its rows its parts, and what VoiceOver says of each.

@MainActor let modelTests = Suite("The kit's kinds", [
    test("the plugin joins the kit and says its kinds, tools, titles, commands and draw words in the registry's report") {
        let registry = try Registry(plugins: kitPlugins())
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("engineering ") })
        for said in ["kit engineering", "shape table", "label Table → table", "tool table", "command insert:table in KitShapes<EngineeringKit>",
                     "shape enum-type", "title pill look → enum-type", "shape database", "title tab → database", "command createDatabase",
                     "CanvasContextMenu in DatabaseMenuGroup", "/database → the command bar's target", "/table → the command bar's target",
                     "draw value columns", "draw value values"] {
            expect(line.contains(said), "the report says \(said): \(line)")
        }
        expectEqual(registry.kits.map(\.id), [EngineeringKit.id])
        expectEqual(registry.kits.map(\.title), ["Engineering"])
        expectEqual(registry.tools.filter { registry.kit(ofTool: $0.id) == EngineeringKit.id }.map(\.label), ["Table", "Enum", "Database"])
        expectEqual(registry.containingKinds.contains(Database.kind), true)
        expectEqual(registry.partedKinds, [DatabaseTable.kind, DatabaseEnum.kind])
        expectEqual(registry.label(of: DatabaseTable.kind).systemImage, "tablecells")
    },
    test("each kind's props round-trip through a board, every member kept, a column's enum by its id") {
        let codec = BoardCodec(registry: try Registry(plugins: kitPlugins()))
        let enumID = ShapeID()
        var table = ShapeRecord(orders(status: enumID))
        table.props.columns[1].default = "gen_random_uuid()"
        table.props.columns[1].onDelete = "cascade"
        table.props.columns[1].onUpdate = "restrict"
        table.props.columns[1].unread = "→ customers.id"
        table[TitleProperty.self] = "orders"
        var values = ShapeRecord(id: enumID, DatabaseEnum(frame: CGRect(x: 0, y: 300, width: 220, height: 68), values: [EnumValue(text: "pending"), EnumValue(text: "paid")]))
        values[TitleProperty.self] = "order_status"
        var database = ShapeRecord(Database(frame: CGRect(x: 0, y: 500, width: 640, height: 400)))
        database[TitleProperty.self] = "shop"
        let document = CanvasDocument(shapes: [AnyShapeRecord(table), AnyShapeRecord(values), AnyShapeRecord(database)])
        let file = CanvasFile(root: document)
        let read = try codec.decode(try codec.encode(file))
        expectEqual(read.file, file)
        let json = String(decoding: try codec.encodeProps(table.props), as: UTF8.self)
        expect(json.contains(#""shape" : "\#(enumID)""#), json)
        expect(json.contains(#""primaryKey" : true"#) && json.contains(#""onDelete" : "cascade""#), json)
    },
    test("a table's width is its own and its height its rows': 8 above, 24 a row, 12 below; a new one is one row, id uuid pk") {
        let h = try kitHarness()
        let id = h.add(DatabaseTable(frame: CGRect(x: 0, y: 0, width: 300, height: 10), columns: DatabaseTable.starter().columns))
        expectEqual(h.editor.shapeContext.geometry(of: id)?.bounds, CGRect(x: 0, y: 0, width: 300, height: 44), "laid out from its rows, whatever it stores")
        h.editor.transact("Rows") { $0.update(id, as: DatabaseTable.self) { $0.props.columns += ColumnGrammar.read(lines: "a text\nb text\nc text") } }
        expectEqual(h.editor.shapeContext.geometry(of: id)?.bounds.height, 116)
        expectEqual(h.editor.document[id]?.box?.height, 10, "a row writes no height: the stored box is as it was")
        expectEqual(DatabaseTable.starter().columns.map(ColumnGrammar.print), ["id uuid pk"])
        let enumType = h.add(DatabaseEnum(frame: CGRect(x: 400, y: 0, width: 220, height: 0)))
        expectEqual(h.editor.shapeContext.geometry(of: enumType)?.bounds.height, 44, "an enum with no values keeps a row's room")
    },
    test("given a frame (a resize, size:) it takes its place and width, and its height stays its rows'; made from properties, its stored height is its rows'") {
        let h = try kitHarness()
        let id = h.add(orders())
        let record = try require(h.editor.document[id])
        let sized = h.editor.registry.sized(record, to: CGRect(x: 50, y: 60, width: 400, height: 900), giving: .both, in: h.editor.shapeContext)
        expectEqual(sized.box, CGRect(x: 50, y: 60, width: 400, height: 116))
        let made = try h.editor.registry.shape(DatabaseTable.kind, properties: ["frame": [[0, 0], [260, 1]],
                                                                              "columns": try JSONValue(encoding: ColumnGrammar.read(lines: "id uuid pk\nname text"))])
        expectEqual(made.box?.height, 68)
    },
    test("its rows are its parts: a column each by its name, a key's symbol before a primary key's, each where its row is in its geometry") {
        let h = try kitHarness()
        let table = orders()
        let id = h.add(table)
        let parts = try require(h.editor.registry.parts(of: try require(h.editor.document[id])))
        expectEqual(parts.map(\.name), ["id", "customer_id", "status", "placed_at"])
        expectEqual(parts.map(\.kindWord), ["Column", "Column", "Column", "Column"])
        expectEqual(parts.map(\.lead), [.symbol("key.horizontal"), .symbol("1.square"), .none, .none])
        expect(parts.allSatisfy { !$0.standsAlone })
        let frames = try require(h.editor.shapeContext.geometry(of: id)?.parts)
        expectEqual(frames.map(\.id), table.columns.map(\.id))
        expectEqual(frames.frame(table.columns[2].id)?.rect, CGRect(x: 100, y: 156, width: 260, height: 24))
        let enumType = h.add(DatabaseEnum(frame: CGRect(x: 400, y: 0, width: 220, height: 68), values: [EnumValue(text: "pending"), EnumValue(text: "paid")]))
        expectEqual(h.editor.registry.parts(of: try require(h.editor.document[enumType]))?.map { "\($0.kindWord) \($0.name)" }, ["Value pending", "Value paid"])
        expectEqual(h.editor.shapeContext.geometry(of: enumType)?.parts.map(\.rect.minY), [8, 32])
    },
    test("VoiceOver: “orders, Table, 4 columns”, “order_status, Enum, 2 values”, “shop, Database, 2 shapes”; untitled, its kind") {
        let h = try kitHarness()
        let table = h.add(orders(), titled: "orders")
        let values = h.add(DatabaseEnum(frame: CGRect(x: 400, y: 100, width: 220, height: 68), values: [EnumValue(text: "pending"), EnumValue(text: "paid")]),
                           titled: "order_status")
        @MainActor func said(_ id: ShapeID) throws -> String {
            let description = try require(h.editor.accessibleDescription(of: id))
            return [description.label, description.value].compactMap { $0 }.joined(separator: ", ")
        }
        expectEqual(try said(table), "orders, Table, 4 columns")
        expectEqual(try said(values), "order_status, Enum, 2 values")
        h.editor.selectedShapeIDs = [table, values]
        h.editor.createDatabaseForTests(named: "shop")
        let database = try require(h.shapes(Database.kind).first).id
        expectEqual(try said(database), "shop, Database, 2 shapes")
        let untitled = h.add(DatabaseTable(frame: CGRect(x: 0, y: 700, width: 260, height: 44), columns: DatabaseTable.starter().columns))
        expectEqual(try said(untitled), "Table, 1 column")
    },
])

extension CanvasEditor {
    /// Create Database on the selection, as its item runs it.
    func createDatabaseForTests(named name: String?) {
        if let name {
            _ = slashCommands?.run("database", for: .selection(selectedShapeIDs), with: SlashArguments(name))
        } else {
            _ = perform(.createDatabase)
        }
    }
}
