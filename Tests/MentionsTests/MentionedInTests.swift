import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Mentions
import Selection
import TestKit
import Titles

// The Mentioned In tab: what mentions a shape, in its panel, on the kinds that opt into being
// mentioned. Headless (the layout), and in the panel in an unshown window (its lines).

private let planFrame = CGRect(x: 0, y: 300, width: 200, height: 200)
private let noteFrame = CGRect(x: 0, y: 600, width: 200, height: 200)

extension CanvasEditor {
    /// The titles of the tabs the panel shows for a shape.
    fileprivate func tabs(_ id: ShapeID) -> [String] {
        guard let record = document[id], let state = detailPanel else { return [] }
        return state.layout(for: record).tabs.map(\.title)
    }
}

/// Two jots that mention the plate "Groceries" (idA): "Plan", titled, then an untitled one.
@MainActor private func mentioners(in editor: CanvasEditor) -> (plan: ShapeID, note: ShapeID) {
    let plan = editor.add(Jot(planFrame, text: MentionText([.text("Ask "), .mention(idA, label: "Groceries"), .text(" first")])), titled: "Plan")
    let note = editor.add(Jot(noteFrame, text: MentionText([.mention(idA, label: "Groceries"), .text(" by Friday")])), titled: nil)
    return (plan, note)
}

@MainActor let mentionedInTests = Suite("Mentioned In", [
    test("the tab shows while another shape on the board mentions the shape, last among the tabs; not for its own mention, nor once the last mention goes") {
        let h = try mentionHarness()
        h.editor.add(Plate(CGRect(x: 300, y: 0, width: 120, height: 80)), titled: "Groceries", id: idA)
        expect(!h.editor.tabs(idA).contains("Mentioned In"), "\(h.editor.tabs(idA))")
        let (plan, note) = mentioners(in: h.editor)
        expectEqual(h.editor.tabs(idA).last, "Mentioned In")
        let layout = try require(h.editor.detailPanel?.layout(for: try require(h.record(idA))))
        expectEqual(layout.sections(in: .of(MentionsTab.self)).map(\.description), ["plate Mentioned In/mentioned-in"])
        expect(!h.editor.tabs(plan).contains("Mentioned In"), "nothing mentions the plan")

        let own = h.editor.add(Jot(CGRect(x: 400, y: 300, width: 200, height: 200)), titled: "Self")
        h.editor.setText(own, MentionText([.text("See "), .mention(own, label: "Self")]))
        expect(!h.editor.tabs(own).contains("Mentioned In"), "a shape's mention of itself isn't what mentions it")

        h.editor.delete(plan)
        expectEqual(h.editor.tabs(idA).last, "Mentioned In")
        h.editor.setText(note, "")
        expect(!h.editor.tabs(idA).contains("Mentioned In"), "the last mention gone")
        h.editor.undo()
        expectEqual(h.editor.tabs(idA).last, "Mentioned In", "and back with it")
    },

    test("the tab comes with a kind's opt-in: every kind made mentionable at once gets none") {
        let every = Contributor(id: "every") { $0.mentionableEveryShape(where: { !($0 is any PaintOrderAnchored) }) }
        let h = try mentionHarness([every])
        let box = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        h.editor.add(Jot(planFrame, text: MentionText([.mention(box, label: "Box")])), titled: nil)
        expect(h.editor.mentionState.isMentioned(box))
        expect(!h.editor.tabs(box).contains("Mentioned In"), "\(h.editor.tabs(box))")
        let registry = h.editor.registry
        let line = try require(registry.report.split(separator: "\n").first { $0.hasPrefix("mention-fixtures") })
        expect(line.contains("mentionable → plate · ShapeDetails → plate"), String(line))
    },

    test("in the panel, a line per mentioner in document order: its name and its text around the mention; a click goes to it, and Back returns") {
        let panel = try MentionPanel()
        let (plan, note) = mentioners(in: panel.editor)
        let mentions = panel.editor.mentionState
        try require(panel.editor.detailPanel).choose(.of(MentionsTab.self), for: Plate.kind)
        panel.editor.selection = idA
        panel.window.spin { mentions.backlinksShown[idA]?.count == 2 }
        let shown = try require(mentions.backlinksShown[idA])
        expectEqual(shown.map(\.id), [plan, note])
        expectEqual(shown.map(\.label), ["Plan", "@… by Friday"], "an untitled jot is called by its first line, which names no other shape")
        expectEqual(shown.map(\.systemImage), ["note.text", "note.text"])
        expectEqual(shown.map(\.quote), ["Ask @Groceries first", "@Groceries by Friday"])
        panel.window.spin { panel.lines.count == 2 }
        panel.lines[1].performClick(nil)
        panel.window.spin { panel.editor.selectedShapeIDs == [note] }
        panel.editor.goBack()
        expectEqual(panel.editor.selectedShapeIDs, [idA])
    },

    test("the lines follow what mentions the shape, which the shape doesn't: a mentioner renamed, one added or gone; a drag redraws none") {
        let panel = try MentionPanel()
        let (plan, note) = mentioners(in: panel.editor)
        let mentions = panel.editor.mentionState
        try require(panel.editor.detailPanel).choose(.of(MentionsTab.self), for: Plate.kind)
        panel.editor.selection = idA
        panel.window.spin { mentions.backlinksShown[idA]?.count == 2 }
        let plate = panel.editor.document[idA]

        panel.editor.rename(plan, "Plan B")
        panel.window.spin { mentions.backlinksShown[idA]?.first?.label == "Plan B" }
        expect(panel.editor.document[idA] == plate, "the plate itself didn't change")

        mentions.backlinksShown = [:]
        for step in 1...3 { panel.editor.transact { $0.moveBox(plan, to: CGPoint(x: 40, y: 300 + CGFloat(step))) } }
        panel.window.settle()
        expectEqual(mentions.backlinksShown[idA]?.map(\.id), nil, "a drag of a mentioner draws no line again")

        let late = panel.editor.add(Jot(CGRect(x: 400, y: 600, width: 200, height: 200),
                                        text: MentionText([.text("and "), .mention(idA, label: "Groceries")])), titled: "Late")
        panel.window.spin { mentions.backlinksShown[idA]?.map(\.id) == [plan, note, late] }
        panel.editor.delete(plan, late)
        panel.window.spin { mentions.backlinksShown[idA]?.map(\.id) == [note] }
        panel.editor.delete(note)
        panel.window.spin { panel.lines.isEmpty }
        expect(!panel.editor.tabs(idA).contains("Mentioned In"), "gone with the last mention")
    },

    test("a read-only shape's lines still go to what mentions it") {
        let panel = try MentionPanel(plugins: [FreezingPlugin()])
        let (plan, _) = mentioners(in: panel.editor)
        try require(panel.editor.detailPanel).choose(.of(MentionsTab.self), for: Plate.kind)
        panel.editor.freeze([idA])
        panel.editor.selection = idA
        panel.window.spin { panel.lines.count == 2 }
        expect(panel.lines.allSatisfy(\.isEnabled), "going to a mentioner changes nothing of the shape")
        panel.lines[0].performClick(nil)
        panel.window.spin { panel.editor.selectedShapeIDs == [plan] }
    },
])
