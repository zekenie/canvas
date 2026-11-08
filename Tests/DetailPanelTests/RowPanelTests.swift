@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import Selection
import SwiftUI
import TestKit

// A row as the panel's subject (`editor.detailRow`): one shape selected with one of its rows selected as an item, else the row its
// editing has the keys on (`editingPart`), for a kind that has row tabs (`RowDetails`). Its layout is the row's: its header (the
// row's lead and name), the tabs its kind's rows have, in their order, no status lines; a kind with none keeps the shape's.
// Rosters (CanvasTesting's), their rows listed as items.

/// A row's own tab, first, and another plugin's tab for every kind with parts.
private enum MemberTab {}
extension MemberTab: DetailTab {
    static var title: String { "Member" }
    static var order: Order<Self> { .first }
}

private enum LinksTab {}
extension LinksTab: DetailTab { static var title: String { "Links" } }

/// Rows' tabs: Links on every kind with parts, from one plugin; Member on rosters, from another, after it in the list but first by
/// its order; and a footer line on every shape, which a row's panel doesn't show.
@MainActor private func rowTabs() -> [any CanvasPlugin] {
    [Contributor(id: "row-links") { registrar in
        registrar.forShapes(adopting: .parts) { $0.rowDetails(in: LinksTab.self, id: "links") { row in Text("links of \(row.part.name)") } }
        registrar.forEveryShape { $0.detailStatus { _, _ in [DetailStatus("a footer line")] } }
     },
     Contributor(id: "row-members") { registrar in
        registrar.forShapes(adopting: .parts) { parted in
            parted.rowDetails(in: MemberTab.self, id: "member", when: { $0.name != "head" }) { row in Text(row.part.name) }
        }
     }]
}

/// Rosters' rows as Selection's items, by their ids.
@MainActor private var rosterItems: Contributor {
    Contributor(id: "roster-items") { registrar in
        registrar.forShapes(adopting: .parts) { parted in
            parted.shapeItems({ editor, shape in
                guard let roster = shape.typed(as: Roster.self), let parts = editor.shapeContext.geometry(of: shape.id)?.parts else { return [] }
                return roster.props.rows.compactMap { row in parts.frame(row.id).map { ShapeItem(id: row.id, title: row.name, rect: $0.rect) } }
            }, at: { _, _, _ in nil }, actions: ShapeItemActions(delete: { _, _, _ in }, move: { _, _, _, _ in }, open: { _, _, _, _ in }))
        }
    }
}

@MainActor let rowPanelTests = Suite("A row as the panel's subject", [
    test("one row selected as an item, or edited, is the subject; several rows, none, or two shapes aren't") {
        let editor = try gadgetEditor([RostersPlugin(), rosterItems] + rowTabs())
        let head = RosterRow(name: "head"), a = RosterRow(name: "a"), b = RosterRow(name: "b")
        let roster = editor.add(Roster(gadgetFrame, rows: [head, a, b]))
        let other = editor.add(Roster(gadgetFrame.offsetBy(dx: 400, dy: 0), rows: [RosterRow(name: "x")]))
        editor.selectedShapeIDs = [roster]
        expectEqual(editor.detailRow, nil, "the shape alone")
        editor.selectItems([AnyHashable(a.id)], of: roster)
        expectEqual(editor.detailRow, PartAddress(roster, part: a.id))
        editor.selectItems([AnyHashable(a.id), AnyHashable(b.id)], of: roster)
        expectEqual(editor.detailRow, nil, "two rows: the shape")
        editor.selectedShapeIDs = [roster, other]
        expectEqual(editor.detailRow, nil)
        editor.selectedShapeIDs = [roster]
        expectEqual(editor.detailRow, nil)
    },
    test("its layout: the row's header, its kind's rows' tabs in their order, none of the shape's and no status lines; per row") {
        let editor = try gadgetEditor([RostersPlugin(), rosterItems] + rowTabs())
        let head = RosterRow(name: "head"), a = RosterRow(name: "a")
        let roster = editor.add(Roster(gadgetFrame, rows: [head, a]))
        let state = try require(editor.detailPanel)
        let record = try require(editor.document[roster])
        let layout = try require(state.rowLayout(for: record, part: a.id))
        expectEqual(layout.tabs.map(\.title), ["Member", "Links"], "the row's own first, by its order")
        expectEqual(layout.header(as: DetailRowHeader.self)?.part.name, "a")
        expectEqual(layout.header(as: DetailRowHeader.self)?.subtitle, "Member", "a row read with its shape says its kind word")
        expectEqual(layout.statuses(in: .of(LinksTab.self)), [])
        expectEqual(try require(state.rowLayout(for: record, part: head.id)).tabs.map(\.title), ["Links"], "a tab that isn't for the row")
        expect(state.rowLayout(for: record, part: PartID()) == nil, "a row the shape doesn't have")
        expect(state.layout(for: record).tabs.allSatisfy { $0.title != "Member" && $0.title != "Links" }, "the shape's panel has none of them")
    },
    test("a row's chosen tab is kept apart from the shape's; Next Inspector Tab steps the row's") {
        let editor = try gadgetEditor([RostersPlugin(), rosterItems] + rowTabs())
        let a = RosterRow(name: "a")
        let roster = editor.add(Roster(gadgetFrame, rows: [a]))
        let state = try require(editor.detailPanel)
        editor.selectedShapeIDs = [roster]
        editor.selectItems([AnyHashable(a.id)], of: roster)
        expect(state.canStepTab)
        expect(state.stepTab(by: 1))
        let record = try require(editor.document[roster])
        let rows = try require(state.rowLayout(for: record, part: a.id))
        expectEqual(state.currentTab(in: rows, for: ShapeKind(rawValue: Roster.kind.rawValue + "#row"))?.title, "Links")
        expectEqual(state.chosenTab(for: Roster.kind), nil, "the shape's choice is its own")
    },
    test("a kind no plugin gives row tabs has no row as the subject") {
        let editor = try gadgetEditor([RostersPlugin(), rosterItems])
        let a = RosterRow(name: "a")
        let roster = editor.add(Roster(gadgetFrame, rows: [a]))
        editor.selectedShapeIDs = [roster]
        editor.selectItems([AnyHashable(a.id)], of: roster)
        expectEqual(editor.detailRow, nil)
    },
    test("a row's tab titled as a shape's is refused, as two shape tabs are") {
        do {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), RostersPlugin(), DetailPanelPlugin(), GadgetsPlugin(), RemarksPlugin(),
                                       Contributor(id: "twins") { registrar in
                                           registrar.forShapes(adopting: .parts) { $0.rowDetails(in: LookalikeStyleTab.self, id: "x") { _ in EmptyView() } }
                                       }])
            expect(false, "two tabs titled Style were let through")
        } catch {
            expect("\(error)".contains("titled \"Style\""), "\(error)")
        }
    },
])
