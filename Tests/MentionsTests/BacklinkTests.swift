import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology

// What mentions a shape: `mentioners(of:)`, on any board, the board shown's first, and a mentioner's
// quote (`quote(of:around:)`), its text around its first mention of the shape; and Show What
// Mentions, in the canvas's context menu, going to what mentions the shapes the menu is for.

/// Plates "Groceries" and "Errands", token "Milk", then, in this order: a jot that asks for the
/// groceries and the milk; a brief (a kind that can't be mentioned, with no title and no tool)
/// whose plates mention the groceries; and a jot titled "Plan" that mentions them too.
@MainActor
private struct Mentioned {
    let h: EditorHarness
    let groceries: ShapeID, errands: ShapeID, milk: ShapeID, ask: ShapeID, brief: ShapeID, plan: ShapeID
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }

    init(_ more: [any CanvasPlugin] = []) throws {
        h = try mentionHarness(more)
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

    /// The quote of `mentioner`'s text around its mention of `target`.
    func quote(_ mentioner: ShapeID, of target: ShapeID) -> String? {
        state.quote(of: mentioner, around: target)
    }
}

/// An edge of another type than a mention: a tag's to what it's on, as an arrow bound at both ends is
/// an edge of its own.
enum TieEdge {}
extension TieEdge: EdgeType {
    static let id: EdgeTypeID = "tie"
}

/// Tags carry ties.
let tiesPlugin = Contributor(id: "ties") { registrar in
    registrar.edgeType(TieEdge.self)
    registrar.edges(Tag.self) { record, _, sink in
        guard let target = (record.props as? Tag)?.target else { return }
        sink.emit(TieEdge.id, from: record.id, to: target)
    }
}

@MainActor let backlinkTests = Suite("Backlinks", [
    test("what mentions a shape, the board shown's in document order; a shape's own mention of itself doesn't make it mentioned") {
        let b = try Mentioned()
        expectEqual(b.state.mentioners(of: b.groceries), [b.ask, b.brief, b.plan])
        expectEqual(b.state.mentioners(of: b.milk), [b.ask])
        expectEqual(b.state.mentioners(of: b.errands), [])
        b.editor.transact { $0.sendToBack(b.plan) }
        expectEqual(b.state.mentioners(of: b.groceries), [b.plan, b.ask, b.brief], "as the board orders them now")

        b.editor.setText(b.plan, MentionText([.text("See "), .mention(b.plan, label: "Plan"), .text(" and "), .mention(b.groceries, label: "Groceries")]))
        expect(!b.state.isMentioned(b.plan), "its own mention of itself")
        expectEqual(b.state.mentioners(of: b.groceries), [b.plan, b.ask, b.brief])
        b.editor.delete(b.groceries)
        expectEqual(b.state.mentioners(of: b.groceries), [b.plan, b.ask, b.brief], "a deleted shape's mentioners still mention it")
    },

    test("a quote: the mentioner's text around its first mention of the shape, with the names its mentions show now, on one line, cut between words with “…” where text is left out") {
        let b = try Mentioned()
        expectEqual(b.quote(b.ask, of: b.groceries), "Ask @Groceries and @Milk")
        expectEqual(b.quote(b.ask, of: b.milk), "Ask @Groceries and @Milk")
        expectEqual(b.quote(b.plan, of: b.groceries), "@Groceries on Friday", "a mention at the start")
        expectEqual(b.quote(b.brief, of: b.groceries), "@Groceries", "wherever the shape keeps its text")
        expectEqual(b.quote(b.ask, of: b.errands), nil, "a shape its text doesn't mention has no quote")

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

    test("Show What Mentions, in the context menu of a shape something mentions, selects what mentions it on the next turn, one step back") {
        let b = try Mentioned()
        expectEqual(try require(b.h.secondaryClick(at: CGPoint(x: 460, y: 240))).outline, ["Delete"], "nothing mentions the errands")
        let menu = try require(b.h.secondaryClick(at: CGPoint(x: 460, y: 40)))
        expectEqual(menu.outline, ["Show What Mentions", "—", "Delete"])
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
        expectEqual(try require(b.h.secondaryClick(at: CGPoint(x: 100, y: 500))).outline, ["Delete"], "the plan mentions only itself")
    },

    test("a list with Mentions needs ContextMenus, for Show What Mentions") {
        expectThrows(RegistryError.ownerNotInstalled(point: "CanvasContextMenu", owner: .contextMenus, contributor: .mentions)) {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), MentionFixturesPlugin(), AdornmentsPlugin(),
                                       DetailPanelPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin()])
        }
    },

    // The user chose file-wide backlinks when Topology took over the index of who mentions whom:
    // main's per-board list followed only from its per-board index, not from a decision.
    test("what mentions a shape is the file's: a mentioner on another board is listed after the board shown's, and showing another board puts its own first") {
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
        expectEqual(state.mentioners(of: groceries), [outer, inner], "the board shown's first (the user chose file-wide)")
        expect(h.enter(pocket))
        expectEqual(state.mentioners(of: groceries), [inner, outer], "what mentions it here first, though it's on the root")
        expect(h.editor.showBoard(.root))
        expectEqual(state.mentioners(of: groceries), [outer, inner])
    },

    test("over Topology's file-wide index, a mentioner on another board counts, with its quote, and Show What Mentions goes there; a shape's mention of itself is none of it, but keeps what it mentions resolved") {
        let groceries = ShapeID(), pocket = ShapeID(), own = ShapeID(), inner = ShapeID()
        var plate = ShapeRecord(id: groceries, Plate(CGRect(x: 400, y: 0, width: 120, height: 80)))
        plate[TitleProperty.self] = "Groceries"
        let root = [AnyShapeRecord(plate), AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
                    AnyShapeRecord(ShapeRecord(id: own, Jot(CGRect(x: 0, y: 0, width: 200, height: 200),
                                                            text: MentionText([.text("Me: "), .mention(own, label: "Me")]))))]
        let inside = [AnyShapeRecord(ShapeRecord(id: inner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200),
                                                                text: MentionText([.text("Buy "), .mention(groceries, label: "Groceries")]))))]
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                                  file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: inside)]))
        let state = h.editor.mentionState
        expectEqual(state.mentioners(of: groceries), [inner])
        expect(state.isMentioned(groceries), "mentioned on the pocket's board, which the user chose to count")
        expectEqual(state.quote(of: inner, around: groceries), "Buy @Groceries", "read where it is")
        expect(!state.isMentioned(own), "its own mention")

        // Both are mentioned, so how each shows is kept: a change to it tells its pills.
        let label = state.labelRevision(of: groceries), itsOwn = state.labelRevision(of: own)
        h.editor.rename(groceries, "Food")
        expectEqual(state.labelRevision(of: groceries), label + 1, "mentioned from another board")
        expectEqual(state.quote(of: inner, around: groceries), "Buy @Food")
        h.editor.setText(own, MentionText([.text("Myself: "), .mention(own, label: "Me")]))
        expectEqual(state.labelRevision(of: own), itsOwn + 1, "mentioned by itself")

        // Show What Mentions shows the mentioner's board, and selects it there, one step back.
        let menu = try require(h.secondaryClick(at: CGPoint(x: 460, y: 40)))
        expectEqual(menu.outline, ["Show What Mentions", "—", "Delete"])
        try menu.choose("Show What Mentions")
        h.wait(0)
        expectEqual(h.editor.board, BoardID(owner: pocket))
        expectEqual(h.editor.selectedShapeIDs, [inner])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [groceries])
    },

    test("a mentioner's text changed on another board, keeping its mention, quotes what it says now") {
        let groceries = ShapeID(), pocket = ShapeID(), inner = ShapeID()
        var plate = ShapeRecord(id: groceries, Plate(CGRect(x: 400, y: 0, width: 120, height: 80)))
        plate[TitleProperty.self] = "Groceries"
        let root = [AnyShapeRecord(plate), AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100))))]
        let inside = [AnyShapeRecord(ShapeRecord(id: inner, Jot(CGRect(x: 0, y: 0, width: 200, height: 200),
                                                                text: MentionText([.text("Buy "), .mention(groceries, label: "Groceries")]))))]
        let h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin()]),
                                  file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: inside)]))
        let state = h.editor.mentionState
        expectEqual(state.quote(of: inner, around: groceries), "Buy @Groceries")
        h.editor.transact(on: BoardID(owner: pocket), "Edit") {
            $0.update(inner, as: Jot.self) { $0.props.text = MentionText([.text("Sell "), .mention(groceries, label: "Groceries")]) }
        }
        expectEqual(h.editor.board, .root, "written where it isn't shown")
        expectEqual(state.quote(of: inner, around: groceries), "Sell @Groceries", "its quote says it now, and it's still a mentioner")
        expectEqual(state.mentioners(of: groceries), [inner])
    },

    test("an edge of another type to a mentioned shape (a tie, as an arrow bound to it) isn't a mention: it changes neither what mentions it nor whether it's mentioned") {
        let b = try Mentioned([tiesPlugin])
        let topology = try require(b.editor.topology)
        let tag = ShapeID()
        b.editor.transact { $0.insert(ShapeRecord(id: tag, Tag(target: b.groceries))) }
        expect(topology.hasEdges(of: b.groceries, .incoming, types: .only(TieEdge.id)), "tied")
        expect(topology.touched.contains(b.groceries))
        b.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = b.errands } }
        b.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = b.groceries } }
        b.editor.delete(tag)
        b.editor.undo()
        expectEqual(b.state.mentioners(of: b.groceries), [b.ask, b.brief, b.plan], "the ties add no mentioner")
        expect(b.state.isMentioned(b.groceries))
        expect(!b.state.isMentioned(tag), "a tie isn't a mention")
        b.editor.transact { $0.update(tag, as: Tag.self) { $0.props.target = b.errands } }
        expect(!b.state.isMentioned(b.errands), "a tie isn't a mention")
        expectEqual(b.state.mentioners(of: b.errands), [])
    },

    test("a drag, of a mentioner or of what it mentions, changes neither what mentions it nor its quote") {
        let b = try Mentioned()
        b.h.move(to: CGPoint(x: 100, y: 100))
        b.h.press()
        b.h.drag(to: CGPoint(x: 160, y: 140))
        b.h.drag(to: CGPoint(x: 220, y: 180))
        b.h.release()
        expectEqual(b.editor.document[b.ask]?.box?.origin, CGPoint(x: 120, y: 80), "the asking jot dragged")
        b.h.move(to: CGPoint(x: 460, y: 40))
        b.h.press()
        b.h.drag(to: CGPoint(x: 500, y: 40))
        b.h.release()
        expectEqual(b.editor.document[b.groceries]?.box?.origin, CGPoint(x: 440, y: 0), "the groceries dragged")
        expectEqual(b.state.mentioners(of: b.groceries), [b.ask, b.brief, b.plan])
        expectEqual(b.quote(b.ask, of: b.groceries), "Ask @Groceries and @Milk")
    },

    test("a name a quote shows, changed on another board: a write there, its board deleted, and the deletion undone, each as the quote says it now") {
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
        @MainActor func quote() -> String? { state.quote(of: note, around: target) }
        expectEqual(quote(), "@Target and @Cellar")

        h.editor.transact(on: BoardID(owner: pocket), "Rename") { $0.update(cellar) { $0[TitleProperty.self] = "Inside" } }
        expectEqual(h.editor.board, .root, "written where it isn't shown")
        expectEqual(quote(), "@Target and @Inside", "renamed on the pocket's board")

        h.editor.delete(pocket)
        expectEqual(quote(), "@Target and @Cellar", "its board deleted with the pocket: missing, the name the mention holds")

        h.editor.undo()
        expectEqual(h.editor.board, .root)
        expectEqual(quote(), "@Target and @Inside", "the deletion undone: live again, as it's called now")
    },
])
