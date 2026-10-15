import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import LanguageModels
import Mentions
import Neighbors
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles

// What mentions a shape, as shipped: Show What Mentions in the context menu of a subboard two notes
// mention, among the subboard's own items and the canvas's (a pasteboard of the test's own); and the
// Connections tab's "Mentioned By" list in the app's window (a `BoardWindow`, `InspectorWindow`), on a
// note and a subboard.

extension InspectorWindow {
    /// The Connections tab's rows: the panel's buttons beside the canvas, under its header, as
    /// tall as a line of a name (a list's head is shorter), top first.
    var connectionRows: [NSButton] {
        buttons.filter {
            let frame = $0.convert($0.bounds, to: host)
            return frame.minX >= canvas.frame.maxX && frame.height > 21
        }
        .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
    }
}

@MainActor let backlinksShippedTests = Suite("Backlinks, as shipped", [
    test("a subboard two notes mention: Show What Mentions in its menu, after its own items and before the clipboard's, selects the notes, one step back") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
        var ship = ShapeRecord(Subboard(frame: CGRect(x: 400, y: 100, width: 240, height: 160)))
        ship[TitleProperty.self] = "Ship it"
        let first = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                           text: MentionText([.text("Ask "), .mention(ship.id, label: "Ship it"), .text(" first")])))
        let second = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 400, width: 200, height: 200),
                                            text: MentionText([.mention(ship.id, label: "Ship it"), .text(" by Friday")])))
        h.editor.transact { transaction in
            transaction.insert(ship)
            transaction.insert(first)
            transaction.insert(second)
        }
        let mentions = try require(h.editor.mentions)
        expectEqual(mentions.mentioners(of: ship.id).map { mentions.quote(of: $0, around: ship.id) }, ["Ask @Ship it first", "@Ship it by Friday"])

        let menu = try require(h.secondaryClick(at: CGPoint(x: 520, y: 180)))
        let outline = menu.outline
        let item = try require(outline.firstIndex(of: "Show What Mentions"), "\(outline)")
        expectEqual(outline.first, "Open", "the subboard's own items first")
        expectEqual(outline[item - 1], "—")
        expectEqual(Array(outline[(item + 1)...].prefix(5)), ["—", "Create Frame", "—", "Cut", "Copy"])
        try menu.choose("Show What Mentions")
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [first.id, second.id])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [ship.id])

        let unmentioned = try require(h.secondaryClick(at: CGPoint(x: 200, y: 200))).outline
        expect(!unmentioned.contains("Show What Mentions"), "\(unmentioned)")
    },

    test("a note a titled note mentions has Connections and Style tabs, as a subboard it mentions has, listing the mentioner under Mentioned By: its line goes to it, and Back returns") {
        let w = try InspectorWindow()
        let groceries = ShapeRecord(StickyNote(frame: CGRect(x: 100, y: 400, width: 200, height: 200), text: "Groceries"))
        var plans = ShapeRecord(Subboard(frame: CGRect(x: 700, y: 100, width: 240, height: 160)))
        plans[TitleProperty.self] = "Plans"
        var ship = ShapeRecord(StickyNote(frame: CGRect(x: 400, y: 100, width: 200, height: 200),
                                          text: MentionText([.text("Ask "), .mention(groceries.id, label: "Groceries"), .text(" first, then "),
                                                             .mention(plans.id, label: "Plans")])))
        ship[TitleProperty.self] = "Ship it"
        w.editor.transact { transaction in
            transaction.insert(groceries)
            transaction.insert(plans)
            transaction.insert(ship)
        }
        let panel = try require(w.editor.detailPanel)
        expectEqual(panel.layout(for: try require(w.editor.document[groceries.id])).tabs.map(\.title), ["Connections", "Style"], "a note's tabs")
        expectEqual(panel.layout(for: try require(w.editor.document[plans.id])).tabs.map(\.title), ["Connections", "Style"])
        expectEqual(panel.layout(for: try require(w.editor.document[ship.id])).tabs.map(\.title), ["Connections", "Style"], "it mentions, and nothing mentions it")

        w.editor.selection = groceries.id
        let list = try require(w.editor.neighborList)
        w.window.spin { list.subject == groceries.id && list.hasLanded && !list.isAsking }
        let symbol = try require(w.editor.registry.label(of: StickyNote.kind).systemImage)
        expectEqual(list.panel, [ConnectionGroup(title: "Mentioned By", count: 1, rows: [
            ConnectionRow(id: ship.id, name: "Ship it", detail: nil, caption: "Ask @Groceries first, then @Plans", symbol: symbol)])],
                    "the mentioner by its title, and its text around the mention")
        expectEqual(w.editor.registry.label(of: StickyNote.kind).tint, .systemYellow, "its symbol a note's yellow, as in its row and the @ picker")
        w.window.spin { w.connectionRows.count == 1 }
        w.connectionRows[0].performClick(nil)
        w.window.spin { w.editor.selection == ship.id }
        w.editor.goBack()
        expectEqual(w.editor.selection, groceries.id)

        // The subboard has it too, and its panel's other tab is the board's.
        w.editor.selection = plans.id
        panel.choose(.of(NeighborsTab.self), for: Subboard.kind)
        w.window.spin { list.subject == plans.id && list.hasLanded && !list.isAsking }
        expectEqual(list.panel.map(\.title), ["Mentioned By"])
        expectEqual(list.panel.first?.rows.map(\.id), [ship.id])
        expectEqual(list.panel.first?.rows.first?.caption, "Ask @Groceries first, then @Plans")
    },
])
