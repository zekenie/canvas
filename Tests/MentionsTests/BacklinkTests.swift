import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Observation
import Selection
import TableOfContents
import TestKit
import Titles

// What mentions a shape: `backlinks(of:)`, each mentioner named and quoted around its mention, on
// the board shown; and Show What Mentions, in the canvas's context menu, selecting what mentions
// the shapes the menu is for.

/// Plates "Groceries" and "Errands", token "Milk", then, in this order: a jot that asks for the
/// groceries and the milk; a brief (a kind that can't be mentioned, with no title and no tool)
/// whose plates mention the groceries; and a jot titled "Plan" that mentions them too.
@MainActor
private struct Mentioned {
    let h: EditorHarness
    let groceries: ShapeID, errands: ShapeID, milk: ShapeID, ask: ShapeID, brief: ShapeID, plan: ShapeID
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }

    init() throws {
        h = try mentionHarness()
        groceries = h.editor.add(Plate(CGRect(x: 400, y: 0, width: 120, height: 80)), titled: "Groceries")
        errands = h.editor.add(Plate(CGRect(x: 400, y: 200, width: 120, height: 80)), titled: "Errands")
        milk = h.add(Token(CGRect(x: 600, y: 0, width: 60, height: 60), caption: "Milk"))
        ask = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200),
                        text: MentionText([.text("Ask "), .mention(groceries, label: "Groceries"), .text(" and "), .mention(milk, label: "Milk")])))
        var plates = Brief(CGRect(x: 0, y: 250, width: 200, height: 100))
        plates.plates = ScopedMentionText([.mention(groceries, label: "Groceries")])
        brief = h.add(plates)
        plan = h.editor.add(Jot(CGRect(x: 0, y: 400, width: 200, height: 200),
                                text: MentionText([.mention(groceries, label: "Groceries"), .text(" on Friday")])), titled: "Plan")
    }

    /// The quote of `mentioner`'s backlink to `target`.
    func quote(_ mentioner: ShapeID, of target: ShapeID) -> String? {
        state.backlinks(of: target).first { $0.id == mentioner }?.quote
    }
}

@MainActor let backlinkTests = Suite("Backlinks", [
    test("what mentions a shape, on the board shown, in document order, the shape itself left out: each named and marked as it's mentioned, else by its title or its kind") {
        let b = try Mentioned()
        let links = b.state.backlinks(of: b.groceries)
        expectEqual(links.map(\.id), [b.ask, b.brief, b.plan])
        expectEqual(links.map(\.label), ["Ask @… and @…", "brief", "Plan"])
        expectEqual(links.map(\.systemImage), ["note.text", "square.dashed", "note.text"])
        expectEqual(b.state.backlinks(of: b.milk).map(\.id), [b.ask])
        expectEqual(b.state.backlinks(of: b.errands), [])
        b.editor.transact { $0.sendToBack(b.plan) }
        expectEqual(b.state.backlinks(of: b.groceries).map(\.id), [b.plan, b.ask, b.brief], "as the board orders them now")

        b.editor.setText(b.plan, MentionText([.text("See "), .mention(b.plan, label: "Plan"), .text(" and "), .mention(b.groceries, label: "Groceries")]))
        expectEqual(b.state.backlinks(of: b.plan), [], "its own mention of itself")
        expectEqual(b.state.backlinks(of: b.groceries).map(\.id), [b.plan, b.ask, b.brief])
        b.editor.rename(b.plan, nil)
        expectEqual(b.state.backlinks(of: b.groceries).first?.label, "See @… and @…", "named as it's mentioned: untitled, by its first line")
        b.editor.delete(b.groceries)
        expectEqual(b.state.backlinks(of: b.groceries).map(\.id), [b.plan, b.ask, b.brief], "a deleted shape's mentioners still mention it")
    },

    test("a quote: the mentioner's text around its first mention of the shape, with the names its mentions show now, on one line, cut between words with “…” where text is left out") {
        let b = try Mentioned()
        expectEqual(b.quote(b.ask, of: b.groceries), "Ask @Groceries and @Milk")
        expectEqual(b.quote(b.ask, of: b.milk), "Ask @Groceries and @Milk")
        expectEqual(b.quote(b.plan, of: b.groceries), "@Groceries on Friday", "a mention at the start")
        expectEqual(b.quote(b.brief, of: b.groceries), "@Groceries", "wherever the shape keeps its text")

        b.editor.setText(b.ask, MentionText([.text("The shopping for the week:\n\n  ask "), .mention(b.groceries, label: "Groceries"),
                                             .text(" about oat milk, bread, eggs, apples and everything else we need before the weekend.")]))
        expectEqual(b.quote(b.ask, of: b.groceries), "…for the week: ask @Groceries about oat milk, bread…", "cut at both ends")
        b.editor.setText(b.ask, MentionText([.mention(b.groceries, label: "Groceries"),
                                             .text(" first, then everything else on the list for the whole long week ahead of us")]))
        expectEqual(b.quote(b.ask, of: b.groceries), "@Groceries first, then everything else on the list for the…", "the room before it goes after it")
        b.editor.setText(b.ask, MentionText([.text("Everything else on the list for the whole long week ahead of us, and then "),
                                             .mention(b.groceries, label: "Groceries"), .text(".")]))
        expectEqual(b.quote(b.ask, of: b.groceries), "…for the whole long week ahead of us, and then @Groceries.", "and the room after it before it")
        b.editor.setText(b.ask, MentionText([.text("Ask "), .mention(b.groceries, label: "Groceries"), .text(" and "), .mention(b.milk, label: "Milk"),
                                             .text(", then "), .mention(b.groceries, label: "Groceries"), .text(" again")]))
        expectEqual(b.quote(b.ask, of: b.milk), "Ask @Groceries and @Milk, then @Groceries again")

        // The names as they are now, the shape's own and the others'; one that's gone, as the text holds it.
        b.editor.rename(b.groceries, "Food")
        b.editor.transact { $0.update(b.milk, as: Token.self) { $0.props.caption = "Oat milk" } }
        expectEqual(b.quote(b.ask, of: b.groceries), "Ask @Food and @Oat milk, then @Food again")
        b.editor.delete(b.milk)
        expectEqual(b.quote(b.ask, of: b.groceries), "Ask @Food and @Milk, then @Food again")
    },

    test("Show What Mentions, in the context menu of a shape something on the board mentions, selects what mentions it on the next turn, one step back") {
        let b = try Mentioned()
        expect(b.h.secondaryClick(at: CGPoint(x: 460, y: 240)) == nil, "nothing mentions the errands, and they have no other item")
        let menu = try require(b.h.secondaryClick(at: CGPoint(x: 460, y: 40)))
        expectEqual(menu.outline, ["Show What Mentions"])
        expectEqual(b.editor.selectedShapeIDs, [b.groceries], "the right-click selected it")
        try menu.choose("Show What Mentions")
        expectEqual(b.editor.selectedShapeIDs, [b.groceries], "not yet")
        b.h.wait(0)
        expectEqual(b.editor.selectedShapeIDs, [b.ask, b.brief, b.plan])
        b.editor.goBack()
        expectEqual(b.editor.selectedShapeIDs, [b.groceries])

        // For several shapes, when one of them is mentioned: what mentions any of them.
        b.editor.selectedShapeIDs = [b.errands, b.milk]
        try require(b.h.secondaryClick(at: CGPoint(x: 630, y: 30))).choose("Show What Mentions")
        b.h.wait(0)
        expectEqual(b.editor.selectedShapeIDs, [b.ask])

        // A shape's mention of itself is none.
        b.editor.setText(b.plan, MentionText([.mention(b.plan, label: "Plan")]))
        b.editor.selectedShapeIDs = []
        expect(b.h.secondaryClick(at: CGPoint(x: 100, y: 500)) == nil, "the plan mentions only itself")
    },

    test("a list with Mentions needs ContextMenus, for Show What Mentions") {
        expectThrows(RegistryError.ownerNotInstalled(point: "CanvasContextMenu", owner: .contextMenus, contributor: .mentions)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), MentionFixturesPlugin(), AdornmentsPlugin(),
                                       DetailPanelPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin()])
        }
    },

    test("what mentions a shape is read on the board shown: a mentioner on another board isn't listed, and showing another board changes every backlinkRevision") {
        let groceries = ShapeID(), pocket = ShapeID(), outer = ShapeID(), inner = ShapeID()
        var plate = ShapeRecord(id: groceries, Plate(CGRect(x: 400, y: 0, width: 120, height: 80)))
        plate[TitleProperty.self] = "Groceries"
        let text = MentionText([.text("Buy "), .mention(groceries, label: "Groceries")])
        let root = [AnyShapeRecord(plate), AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
                    AnyShapeRecord(ShapeRecord(id: outer, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: text)))]
        let inside = [AnyShapeRecord(ShapeRecord(id: inner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: text)))]
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                                  file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: inside)]))
        let state = h.editor.mentionState
        expectEqual(state.backlinks(of: groceries).map(\.id), [outer])
        let flag = Flag()
        let revision = state.backlinkRevision(of: groceries)
        withObservationTracking { _ = state.backlinkRevision(of: groceries) } onChange: { flag.fired = true }
        expect(h.enter(pocket))
        expect(flag.fired)
        expect(state.backlinkRevision(of: groceries) != revision)
        expectEqual(state.backlinks(of: groceries), [MentionBacklink(id: inner, label: "Buy @…", systemImage: "note.text", quote: "Buy @Groceries")],
                    "what mentions it here, though it's on the root")
        expect(h.editor.showBoard(.root))
        expectEqual(state.backlinks(of: groceries).map(\.id), [outer])
    },

    test("a name a quote shows changing on another board tells backlinkRevision's observers: a write there, its board deleted, and the deletion undone") {
        let target = ShapeID(), cellar = ShapeID(), pocket = ShapeID(), note = ShapeID()
        var plate = ShapeRecord(id: target, Plate(CGRect(x: 400, y: 0, width: 120, height: 80)))
        plate[TitleProperty.self] = "Target"
        var inside = ShapeRecord(id: cellar, Plate(CGRect(x: 0, y: 0, width: 120, height: 80)))
        inside[TitleProperty.self] = "Cellar"
        let text = MentionText([.mention(target, label: "Target"), .text(" and "), .mention(cellar, label: "Cellar")])
        let root = [AnyShapeRecord(plate), AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
                    AnyShapeRecord(ShapeRecord(id: note, Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: text)))]
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                                  file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(inside)])]))
        let state = h.editor.mentionState
        @MainActor func quote() -> String? { state.backlinks(of: target).first?.quote }
        /// Observes the target's revision, as an open Mentioned In list does, having read its quote.
        @MainActor func observed() -> Flag {
            let flag = Flag()
            withObservationTracking { _ = state.backlinkRevision(of: target) } onChange: { flag.fired = true }
            return flag
        }
        expectEqual(quote(), "@Target and @Cellar")

        var flag = observed()
        h.editor.transact(on: BoardID(owner: pocket), "Rename") { $0.update(cellar) { $0[TitleProperty.self] = "Inside" } }
        expectEqual(h.editor.board, .root, "written where it isn't shown")
        expect(flag.fired, "renamed on the pocket's board")
        expectEqual(quote(), "@Target and @Inside")

        flag = observed()
        h.editor.delete(pocket)
        expect(flag.fired, "its board deleted with the pocket")
        expectEqual(quote(), "@Target and @Cellar", "missing: the name the mention holds")

        flag = observed()
        h.editor.undo()
        expectEqual(h.editor.board, .root)
        expect(flag.fired, "the deletion undone")
        expectEqual(quote(), "@Target and @Inside", "live again, as it's called now")
    },
])
