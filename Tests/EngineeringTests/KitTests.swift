import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import Engineering
import Keyboard
import Selection
import SlashCommands
import TestKit
import Titles

// The kit off in a file: its tools, their Insert items, `/table`, `/api`, `/database` and Create Database are gone, and an API's
// changes, New Version and Group by Prefix (commands, menu items, typed); its shapes stay, drawn, moved, renamed and deleted as any
// shape; ⇧↩ on a table makes a note.

@MainActor let kitTests = Suite("The kit off", [
    test("off, every way in is gone and its shapes stay; on in one step, they're back") {
        let h = try kitHarness(on: false)
        let tools = [DatabaseTable.kind, DatabaseEnum.kind, API.kind, Database.kind].map(ToolID.init(placing:))
        expect(tools.allSatisfy { !h.editor.isToolEnabled($0) && !h.editor.claims(.insert($0)) })
        let table = h.add(orders(), titled: "orders")
        h.editor.selectedShapeIDs = [table]
        expect(!h.offered.contains("table") && !h.offered.contains("database") && !h.offered.contains("api"))
        expect(!h.editor.claims(.createDatabase))
        expect(!(h.secondaryClick(at: CGPoint(x: 200, y: 150))?.outline ?? []).contains("Create Database"))
        expectEqual(h.editor.toolBeside([table]), nil, "no note tool in this list: nothing to put beside it")
        expect(h.editor.shapeContext.geometry(of: table) != nil, "still drawn")
        h.editor.transact("Move") { $0.update(table, as: DatabaseTable.self) { $0.props.frame.origin.x += 40 } }
        h.editor.beginEditing(table)
        expect(h.editor.editingShapeID == table, "renamed in its pill as ever: the kinds never switch")
        h.editor.endEditing()
        h.editor.turn(EngineeringKit.self, on: true)
        expectEqual(h.editor.undoHistory.undoName, "Turn On Engineering")
        expect(tools.allSatisfy { h.editor.isToolEnabled($0) })
        expect(h.offered.contains("table") && h.offered.contains("database") && h.offered.contains("api"))
        expect(h.editor.claims(.createDatabase))
    },
    test("off, an API's changes are gone with the rest: New Version and Group by Prefix as commands, menu items and typed; on, they're back") {
        let h = try kitHarness(on: false)
        let api = h.add(API(frame: CGRect(x: 100, y: 100, width: 420, height: 100), server: APIServer(host: "api.shop.dev/v1"),
                            endpoints: ["GET /orders/{id}", "POST /orders"].compactMap { EndpointGrammar.read($0) }), titled: "orders API")
        h.editor.selectedShapeIDs = [api]
        let menu = { @MainActor in h.secondaryClick(at: CGPoint(x: 200, y: 150))?.outline ?? [] }
        expect(!h.editor.claims(.newVersion) && !h.editor.claims(.groupByPrefix))
        expect(!h.offered.contains("new-version") && !h.offered.contains("group-by-prefix"), "\(h.offered)")
        expect(!menu().contains("New Version") && !menu().contains("Group by Prefix"), "\(menu())")
        h.editor.turn(EngineeringKit.self, on: true)
        h.editor.selectedShapeIDs = [api]
        expect(h.editor.claims(.newVersion) && h.editor.claims(.groupByPrefix))
        expect(h.offered.contains("new-version") && h.offered.contains("group-by-prefix"), "\(h.offered)")
        expect(menu().contains("New Version") && menu().contains("Group by Prefix"), "\(menu())")
    },
    test("a row's keys are listed in the Keyboard Shortcuts window only while the kit is on") {
        let h = try kitHarness(on: false)
        let hints = { @MainActor (on: Set<KitID>) in
            h.editor.registry.keyboardHelp(kitsOn: on).filter { "\($0)".contains("in a Row") || "\($0)".contains("in a Column") || "\($0)".contains("in an Endpoint") || "\($0)".contains("on a Table or API") }
        }
        expect(hints([]).isEmpty, "off: \(hints([]))")
        expectEqual(hints([EngineeringKit.id]).count, 9)
    },
])
