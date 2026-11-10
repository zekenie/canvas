import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Geometry
import Keyboard
import Mentions
import Selection
import TestKit
import Titles
import Topology

// Following a row's mention, and what mentions a row, by every way a person has: ⌥Tab to the "Go to" part and Return, a double-click on
// its pill, the pill's menu in the text being edited, the canvas's Show What Mentions for the row selected; on the board shown and
// from another; Show What Mentions for a row going to what mentions that row alone. Rosters (CanvasTesting's), as RowMentionTests has.

/// Two rosters and two jots on the root: one mentions `customer_id` of "orders", the other `id` of it; and a pocket, on whose board a
/// third mentions `customer_id` from there. The view is 800 × 600 at zoom 1.
@MainActor private final class RowFollowBoard {
    let h: EditorHarness
    let orders = ShapeID(), customers = ShapeID(), pocket = ShapeID(), jot = ShapeID(), second = ShapeID(), inner = ShapeID()
    let id = RosterRow(name: "id"), customerID = RosterRow(name: "customer_id")
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }
    var row: PartAddress { PartAddress(orders, part: customerID.id) }
    var idRow: PartAddress { PartAddress(orders, part: id.id) }
    var pocketBoard: BoardID { BoardID(owner: pocket) }

    init() throws {
        func titled(_ props: some ShapeProps, _ id: ShapeID, _ title: String) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, props))
            record[TitleProperty.self] = title
            return record
        }
        let ask = MentionText([.text("Ask "), .mention(PartAddress(orders, part: customerID.id), label: "orders.customer_id"), .text(" first")])
        let key = MentionText([.mention(PartAddress(orders, part: id.id), label: "orders.id")])
        let root = [titled(Roster(CGRect(x: 0, y: 0, width: 160, height: 80), rows: [id, customerID]), orders, "orders"),
                    titled(Roster(CGRect(x: 300, y: 0, width: 160, height: 60), rows: []), customers, "customers"),
                    AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 1200, y: 1200, width: 100, height: 100)))),
                    AnyShapeRecord(ShapeRecord(id: jot, Jot(CGRect(x: 0, y: 200, width: 220, height: 100), text: ask))),
                    AnyShapeRecord(ShapeRecord(id: second, Jot(CGRect(x: 300, y: 200, width: 200, height: 100), text: key)))]
        let inside = [AnyShapeRecord(ShapeRecord(id: inner, Jot(CGRect(x: 20, y: 20, width: 220, height: 100), text: ask)))]
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin(), RostersPlugin(), rosterNames, rosterItems, FreezingPlugin()]),
                              file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: inside)]))
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    }

    /// What the row selected as an item of "orders" is, if one is.
    var selectedRows: [AnyHashable]? { editor.selectedItems?.ids }
}

@MainActor let rowFollowTests = Suite("Following a row's mention, and what mentions a row", [
    test("a note's ⌥Tab walk lists Go to the row by its name, and Return goes to its shape with the row selected, one step back") {
        let b = try RowFollowBoard()
        b.editor.selection = b.jot
        let parts = b.editor.shapeParts(of: b.jot)
        expectEqual(parts.map(\.title), ["Go to orders.customer_id"])
        expectEqual(parts.map(\.role), [.link])
        expectEqual(parts.first?.rect, b.editor.mentionPills(of: b.jot).first?.frame, "the pill's own rect")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let canvas = CanvasView(editor: b.editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = canvas
        window.makeFirstResponder(canvas)
        let walk = KeyWalk(window, editor: b.editor, readers: [.canvas(canvas, selection: { ["note"] }, part: { [editor = b.editor] in editor.focusedPart?.title },
                                                                       frame: { [editor = b.editor, canvas] in
                                                                           editor.focusedPart.flatMap { editor.shownFrame(ofWorld: $0.rect, in: canvas) }
                                                                       })],
                           settle: .manual(b.h.scheduler))
        expectEqual(walk.press(.optionTab).id, "canvas/note/Go to orders.customer_id")
        walk.press(.return)
        expectEqual(b.editor.selectedShapeIDs, [b.orders], "Return follows the focused part")
        expectEqual(b.selectedRows, [AnyHashable(b.customerID.id)], "the row selected, an item of its shape")
        b.editor.goBack()
        expectEqual(b.editor.selectedShapeIDs, [b.jot])
    },
    test("a double-click on a row's pill goes to its shape with the row selected; the pill reads aloud as the row, and as deleted once the row is gone") {
        let b = try RowFollowBoard()
        let pill = try require(b.editor.mentionPills(of: b.jot).first)
        let at = b.h.view(CGPoint(x: pill.frame.midX, y: pill.frame.midY))
        b.h.click(at: at, clickCount: 2)
        expectEqual(b.editor.selectedShapeIDs, [b.orders])
        expectEqual(b.selectedRows, [AnyHashable(b.customerID.id)])
        b.editor.goBack()
        expectEqual(b.editor.selectedShapeIDs, [b.jot])
        b.editor.transact("Delete Column") { $0.update(b.orders, as: Roster.self) { $0.props.rows.remove(at: 1) } }
        expect(b.editor.mentionPills(of: b.jot).allSatisfy { !$0.isLive }, "a row that's gone is a pill that isn't live")
        b.h.click(at: at, clickCount: 2)
        expect(b.editor.selectedShapeIDs != [b.orders] || b.selectedRows == nil, "a pill that isn't live is not followed")
    },
    test("in the text being edited a row pill's menu goes to the row, and shows what mentions that row, not its shape's other rows") {
        let session = try EditedJot(MentionText([.text("See "), .mention(PartAddress(rowShape, part: rowOfIt.id), label: "orders.customer_id")]),
                                    plugins: [RostersPlugin(), rosterNames, rosterItems]) { editor in
            var roster = ShapeRecord(id: rowShape, Roster(CGRect(x: 300, y: 300, width: 160, height: 80), rows: [rowOfOthers, rowOfIt]))
            roster[TitleProperty.self] = "orders"
            editor.transact { $0.insert(roster) }
            editor.add(Jot(CGRect(x: 600, y: 300, width: 200, height: 100), text: MentionText([.mention(PartAddress(rowShape, part: rowOfOthers.id), label: "orders.id")])),
                       titled: "Other")
        }
        let menu = try require(session.textView.menu(for: session.mouse(.rightMouseDown, at: session.point(of: 4))))
        expectEqual(Array(menu.outline.prefix(4)), ["Go to “orders.customer_id”", "Show What Mentions “orders.customer_id”", "Remove Mention", "—"])
        try menu.choose("Show What Mentions “orders.customer_id”")
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot], "this jot mentions that row; the other jot mentions another row")

        let going = try EditedJot(MentionText([.text("See "), .mention(PartAddress(rowShape, part: rowOfIt.id), label: "orders.customer_id")]),
                                  plugins: [RostersPlugin(), rosterNames, rosterItems]) { editor in
            var roster = ShapeRecord(id: rowShape, Roster(CGRect(x: 300, y: 300, width: 160, height: 80), rows: [rowOfOthers, rowOfIt]))
            roster[TitleProperty.self] = "orders"
            editor.transact { $0.insert(roster) }
        }
        try require(going.textView.menu(for: going.mouse(.rightMouseDown, at: going.point(of: 4)))).choose("Go to “orders.customer_id”")
        going.h.scheduler.advance(by: .zero)
        expectEqual(going.h.editor.selectedShapeIDs, [rowShape])
        expectEqual(going.h.editor.selectedItems?.ids, [AnyHashable(rowOfIt.id)])
    },
    test("Show What Mentions of a row goes to what mentions that row alone; of its shape, to every mentioner of any of its rows") {
        let b = try RowFollowBoard()
        b.state.showWhatMentions([b.row])
        b.h.wait(10)
        expectEqual(Set(b.editor.selectedShapeIDs), [b.jot], "the note that mentions customer_id, not the one that mentions id")
        b.editor.goBack()
        b.state.showWhatMentions([b.idRow])
        b.h.wait(10)
        expectEqual(Set(b.editor.selectedShapeIDs), [b.second])
        b.editor.goBack()
        b.state.showWhatMentions([b.orders])
        b.h.wait(10)
        expectEqual(Set(b.editor.selectedShapeIDs), [b.jot, b.second], "the shape as a whole: both")
    },
    test("with a row selected, the canvas's Show What Mentions is about that row: it's there while the row is mentioned, and goes to what mentions it") {
        let b = try RowFollowBoard()
        let menu = try require(b.h.secondaryClick(at: CGPoint(x: 80, y: 40)))
        expect(menu.outline.contains("Show What Mentions"), "the shape is mentioned: \(menu.outline)")

        // `customers` has no rows and no mention: its menu has none. A row of `orders` selected: its menu names that row's mentioners.
        b.editor.selectedShapeIDs = [b.orders]
        b.editor.selectItems([AnyHashable(b.id.id)], of: b.orders)
        let rowMenu = try require(b.h.secondaryClick(at: CGPoint(x: 80, y: 40)))
        expect(rowMenu.outline.contains("Show What Mentions"), "the row is mentioned: \(rowMenu.outline)")
        try rowMenu.choose("Show What Mentions")
        b.h.wait(10)
        expectEqual(Set(b.editor.selectedShapeIDs), [b.second], "the note that mentions `id`, not `customer_id`")
    },
    test("a row's mention followed from a board it isn't on shows its board, selects the row there, and Back returns") {
        let b = try RowFollowBoard()
        expect(b.editor.showBoard(b.pocketBoard))
        b.state.follow(b.row)
        b.h.wait(10)
        expectEqual(b.editor.board, .root)
        expectEqual(b.editor.selectedShapeIDs, [b.orders])
        expectEqual(b.selectedRows, [AnyHashable(b.customerID.id)], "the row selected on the board shown by following")
        b.editor.goBack()
        expectEqual(b.editor.board, b.pocketBoard, "Back returns to the board left")
    },
    test("with the caret just after a row's pill, ⌥⌘↩ follows it to its shape with the row selected, and the pill reads as the row, and as deleted once the row is gone") {
        let session = try EditedJot(MentionText([.text("See "), .mention(PartAddress(rowShape, part: rowOfIt.id), label: "orders.customer_id")]),
                                    plugins: [RostersPlugin(), rosterNames, rosterItems]) { editor in
            var roster = ShapeRecord(id: rowShape, Roster(CGRect(x: 300, y: 300, width: 160, height: 80), rows: [rowOfOthers, rowOfIt]))
            roster[TitleProperty.self] = "orders"
            editor.transact { $0.insert(roster) }
        }
        let view = session.textView
        let whole = NSRange(location: 0, length: session.storage.length)
        expectEqual(view.accessibilityString(for: whole), "See orders.customer_id, Member")
        let items = CommandItems(session.h.editor)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        expect(try items.isOn("Go", "Go to Mention"))
        let delivery = KeyDriver(session.window, menu: items.menu).send(goToMentionChord)
        expect(delivery.isMenu, "the menu bar took the key: \(delivery)")
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, nil)
        expectEqual(session.h.editor.selectedShapeIDs, [rowShape])
        expectEqual(session.h.editor.selectedItems?.ids, [AnyHashable(rowOfIt.id)])
        session.h.editor.goBack()
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot])

        let gone = try EditedJot(MentionText([.text("See "), .mention(PartAddress(rowShape, part: rowOfIt.id), label: "orders.customer_id")]),
                                 plugins: [RostersPlugin(), rosterNames, rosterItems]) { editor in
            var roster = ShapeRecord(id: rowShape, Roster(CGRect(x: 300, y: 300, width: 160, height: 80), rows: [rowOfOthers]))
            roster[TitleProperty.self] = "orders"
            editor.transact { $0.insert(roster) }
        }
        expectEqual(gone.textView.accessibilityString(for: NSRange(location: 0, length: gone.storage.length)), "See orders.customer_id, deleted")
        gone.textView.setSelectedRange(NSRange(location: 4, length: 1))
        expect(!(try CommandItems(gone.h.editor).isOn("Go", "Go to Mention")), "a row that's gone can't be followed")
    },
])

private let rowShape = ShapeID(), rowOfIt = RosterRow(name: "customer_id"), rowOfOthers = RosterRow(name: "id")
