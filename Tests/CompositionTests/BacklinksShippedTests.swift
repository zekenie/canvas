import AppKit
import Canvas
import CanvasTesting
import CanvasUI
import Composition
import DetailPanel
import LanguageModels
import Mentions
import Selection
import StickyNotes
import Subboards
import TestKit
import Titles

// What mentions a shape, as shipped: Show What Mentions in the context menu of a subboard two notes
// mention, among the subboard's own items and the canvas's (a pasteboard of the test's own); and the
// Mentioned In tab in the app's window (a `BoardWindow`, `InspectorWindow`), on a note and a subboard.

extension InspectorWindow {
    /// The Mentioned In tab's lines: the panel's buttons beside the canvas, under its header, as
    /// tall as a line of a name over a line of text, top first.
    var mentionLines: [NSButton] {
        buttons.filter {
            let frame = $0.convert($0.bounds, to: host)
            return frame.minX >= canvas.frame.maxX && frame.height > 20
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
        expectEqual(h.editor.mentions?.backlinks(of: ship.id).map(\.quote), ["Ask @Ship it first", "@Ship it by Friday"])

        let menu = try require(h.secondaryClick(at: CGPoint(x: 520, y: 180)))
        let outline = menu.outline
        let item = try require(outline.firstIndex(of: "Show What Mentions"), "\(outline)")
        expectEqual(outline.first, "Open", "the subboard's own items first")
        expectEqual(outline[item - 1], "—")
        expectEqual(Array(outline[(item + 1)...].prefix(3)), ["—", "Cut", "Copy"])
        try menu.choose("Show What Mentions")
        h.wait(0)
        expectEqual(h.editor.selectedShapeIDs, [first.id, second.id])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [ship.id])

        let unmentioned = try require(h.secondaryClick(at: CGPoint(x: 200, y: 200))).outline
        expect(!unmentioned.contains("Show What Mentions"), "\(unmentioned)")
    },

    test("a note a titled note mentions has a Mentioned In tab, as a subboard it mentions has: the mentioner's line goes to it, and Back returns") {
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
        expectEqual(panel.layout(for: try require(w.editor.document[groceries.id])).tabs.map(\.title).last, "Mentioned In")
        expectEqual(panel.layout(for: try require(w.editor.document[plans.id])).tabs.map(\.title).last, "Mentioned In")
        expectEqual(panel.layout(for: try require(w.editor.document[ship.id])).tabs.map(\.title).last, "Arrange", "nothing mentions it")

        panel.choose(.of(MentionsTab.self), for: StickyNote.kind)
        w.editor.selection = groceries.id
        let mentions = try require(w.editor.mentions)
        w.window.spin { mentions.backlinksShown[groceries.id] != nil }
        let symbol = try require(w.editor.registry.mentionAppearance(of: AnyShapeRecord(ship))?.systemImage)
        expectEqual(mentions.backlinksShown[groceries.id], [MentionBacklink(id: ship.id, label: "Ship it", systemImage: symbol,
                                                                            quote: "Ask @Groceries first, then @Plans")])
        w.window.spin { w.mentionLines.count == 1 }
        w.mentionLines[0].performClick(nil)
        w.window.spin { w.editor.selection == ship.id }
        w.editor.goBack()
        expectEqual(w.editor.selection, groceries.id)
    },
])
