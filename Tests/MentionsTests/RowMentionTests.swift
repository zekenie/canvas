import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Geometry
import Mentions
import Selection
import TestKit
import Titles
import Topology

// Mentions of a row (`@[label](shape:UUID/row:ID)`): what one stores and reads; how its pill shows its row live by its shape's name
// and its own ("orders.customer_id"), renamed, deleted and undone; its edge, to the row's shape with the row as its target part,
// and what mentions a row (`mentioners`, `quote`); a copy keeping the row's id; a row moved to another shape (`moveParts`) named
// where it went; and the `@` picker listing rows. Rosters (CanvasTesting's), titled, beside jots.

/// Rosters named by their titles, and mentionable.
@MainActor var rosterNames: Contributor {
    Contributor(id: "roster-names") {
        $0.title(Roster.self, contents: false)
        $0.mentionable(Roster.self)
    }
}

/// Rosters' rows as Selection's items, by their ids: what following a row's mention selects.
@MainActor var rosterItems: Contributor {
    Contributor(id: "roster-items") { registrar in
        registrar.forShapes(adopting: .parts) { parted in
            parted.shapeItems({ editor, shape in
                guard let roster = shape.typed(as: Roster.self), let parts = editor.shapeContext.geometry(of: shape.id)?.parts else { return [] }
                return roster.props.rows.compactMap { row in parts.frame(row.id).map { ShapeItem(id: row.id, title: row.name, rect: $0.rect) } }
            }, at: { _, _, _ in nil }, actions: ShapeItemActions(delete: { _, _, _ in }, move: { _, _, _, _ in }, open: { _, _, _, _ in }))
        }
    }
}

@MainActor private final class RowBoard {
    let h: EditorHarness
    let orders = ShapeID(), customers = ShapeID(), jot = ShapeID()
    let id = RosterRow(name: "id"), customerID = RosterRow(name: "customer_id"), email = RosterRow(name: "email")
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }
    var row: PartAddress { PartAddress(orders, part: customerID.id) }

    init(mentioning: Bool = true) throws {
        h = try mentionHarness([RostersPlugin(), rosterNames, rosterItems, FreezingPlugin()])
        editor.add(Roster(CGRect(x: 0, y: 0, width: 160, height: 80), rows: [id, customerID]), titled: "orders", id: orders)
        editor.add(Roster(CGRect(x: 300, y: 0, width: 160, height: 60), rows: [email]), titled: "customers", id: customers)
        let text: MentionText = mentioning ? MentionText([.text("Ask "), .mention(row, label: "orders.customer_id"), .text(" first")]) : ""
        editor.add(Jot(CGRect(x: 0, y: 200, width: 200, height: 100), text: text), titled: nil, id: jot)
    }

    var text: MentionText? { editor.document[jot]?.typed(as: Jot.self)?.props.text }
}

@MainActor let rowMentionTests = Suite("Mentions of a row", [
    test("a row's mention is stored after its shape's id, read back whole, and read as plain text in one pass as its runs read") {
        let shape = ShapeID(), part = PartID()
        let text = MentionText([.text("See "), .mention(PartAddress(shape, part: part), label: "orders.customer_id")])
        expectEqual(text.stored, "See @[orders.customer_id](shape:\(shape.rawValue.uuidString)/row:\(part.rawValue.uuidString))")
        expectEqual(MentionText(stored: text.stored).runs, text.runs)
        expectEqual(text.mentioned, [shape], "its shape is among what it mentions")
        expectEqual(text.mentionedTargets, [PartAddress(shape, part: part)])
        expectEqual(MentionText.plainText(stored: text.stored), "See @orders.customer_id")
        expectEqual(MentionText.plainText(stored: text.stored) { $0.part == part ? "orders.buyer_id" : nil }, "See @orders.buyer_id")
        // A row id in lowercase is read, and written back as read; one that isn't a UUID is text, and a look-alike.
        let lower = "@[x](shape:\(shape.rawValue.uuidString)/row:\(part.rawValue.uuidString.lowercased()))"
        expectEqual(MentionText(stored: lower).mentionedTargets, [PartAddress(shape, part: part)])
        expectEqual(MentionText(stored: lower).stored, lower)
        let broken = "@[x](shape:\(shape.rawValue.uuidString)/row:1234)"
        expectEqual(MentionText(stored: broken).runs, [.text(broken)])
        expectEqual(MentionText(stored: broken).lookalikes, [broken])
        expectEqual(MentionText.plainText(stored: broken), broken)
    },
    test("a copy renames the shape a row's mention names and keeps the row's id; a move renames the row") {
        let shape = ShapeID(), copy = ShapeID(), other = ShapeID(), part = PartID(), moved = PartID()
        let text = MentionText([.mention(PartAddress(shape, part: part), label: "a.b"), .mention(shape, label: "a")])
        expectEqual(text.renamingShapes { $0 == shape ? copy : nil }.mentionedTargets, [PartAddress(copy, part: part), PartAddress(copy)])
        let renamed = text.renamingParts { $0 == PartAddress(shape, part: part) ? PartAddress(other, part: moved) : nil }
        expectEqual(renamed.mentionedTargets, [PartAddress(other, part: moved), PartAddress(shape)], "a shape's own mention isn't a row's")
        expectEqual(text.renamingParts { _ in nil }.stored, text.stored, "nothing renamed, nothing written")
    },
    test("a row's pill is live by its shape's name and its own, follows a rename of either, is missing once the row goes, and live with Undo") {
        let b = try RowBoard()
        expectEqual(b.state.resolve(b.row).appearance?.label, "orders.customer_id")
        expectEqual(b.state.resolve(b.row).appearance?.kindName, "Member")
        var heard: [Set<ShapeID>] = []
        let observation = b.state.observe([b.orders], rows: [b.row]) { heard.append($0) }
        defer { observation.cancel() }
        b.editor.transact("Rename") { $0.update(b.orders, as: Roster.self) { $0.props.rows[1].name = "buyer_id" } }
        expectEqual(b.state.resolve(b.row).appearance?.label, "orders.buyer_id")
        expectEqual(b.state.labels.label(of: b.row), "orders.buyer_id", "kept, for what reads off the main actor")
        expectEqual(heard, [[b.orders]], "the row's shape is told")
        b.editor.rename(b.orders, "purchases")
        expectEqual(b.state.labels.label(of: b.row), "purchases.buyer_id", "the shape's name too")
        expectEqual(b.state.plainText(try require(b.text)), "Ask @purchases.buyer_id first")
        b.editor.transact("Delete Column") { $0.update(b.orders, as: Roster.self) { $0.props.rows.remove(at: 1) } }
        expectEqual(b.state.resolve(b.row), .missing, "the row gone, its shape there")
        expectEqual(b.state.plainText(try require(b.text)), "Ask @purchases.buyer_id first", "the name it last showed, not the one it holds")
        b.editor.undo()
        expectEqual(b.state.resolve(b.row).appearance?.label, "purchases.buyer_id")
        b.editor.delete(b.orders)
        expectEqual(b.state.resolve(b.row), .missing, "its shape gone")
        b.editor.undo()
        expect(b.state.resolve(b.row).isLive)
    },
    test("a row's mention is an edge to its shape at the row: what mentions the shape counts it, what mentions the row is it alone") {
        let b = try RowBoard()
        let other = b.editor.add(Jot(CGRect(x: 300, y: 200, width: 200, height: 100), text: MentionText([.text("All of "), .mention(b.orders, label: "orders")])),
                                 titled: nil)
        let edges = try require(b.editor.topology).edges(of: b.orders, .incoming, types: .only(MentionEdge.id))
        expectEqual(Set(edges.map(\.targetPart)), [b.customerID.id, nil])
        expectEqual(Set(b.state.mentioners(of: b.orders)), [b.jot, other], "what mentions the shape: its rows' mentions too")
        expectEqual(b.state.mentioners(of: b.row), [b.jot], "what mentions the row")
        expectEqual(b.state.mentioners(of: PartAddress(b.orders, part: b.id.id)), [])
        expect(b.state.isMentioned(b.row))
        expect(!b.state.isMentioned(PartAddress(b.orders, part: b.id.id)))
        expectEqual(b.state.quote(of: b.jot, around: b.row), "Ask @orders.customer_id first")
        expectEqual(b.state.quote(of: other, around: b.row), nil, "a mention of the shape isn't of the row")
        expectEqual(b.state.quote(of: b.jot, around: b.orders), "Ask @orders.customer_id first", "a mention of a row is of its shape")
    },
    test("rows moved to another shape are mentioned where they went, in the step that moves them, and back with Undo") {
        let b = try RowBoard()
        let moved = PartAddress(b.customers, part: b.customerID.id)
        b.editor.transact("Move Column") { tx in
            tx.update(b.orders, as: Roster.self) { $0.props.rows.remove(at: 1) }
            tx.update(b.customers, as: Roster.self) { $0.props.rows.append(b.customerID) }
            tx.moveParts([b.row: moved])
        }
        expectEqual(b.text?.mentionedTargets, [moved])
        expectEqual(b.state.resolve(moved).appearance?.label, "customers.customer_id", "live where it went")
        expectEqual(b.state.mentioners(of: moved), [b.jot])
        b.editor.undo()
        expectEqual(b.text?.mentionedTargets, [b.row])
        expect(b.state.resolve(b.row).isLive)
    },
    test("a locked mentioner keeps its text as rows move, its pill then naming a row that's gone") {
        let b = try RowBoard()
        b.editor.freeze([b.jot])
        let moved = PartAddress(b.customers, part: b.customerID.id)
        b.editor.transact("Move Column") { tx in
            tx.update(b.orders, as: Roster.self) { $0.props.rows.remove(at: 1) }
            tx.update(b.customers, as: Roster.self) { $0.props.rows.append(b.customerID) }
            tx.moveParts([b.row: moved])
        }
        expectEqual(b.text?.mentionedTargets, [b.row], "a read-only shape isn't written")
        expectEqual(b.state.resolve(b.row), .missing)
    },
    test("the @ picker lists rows in a shape's own text, a column under its table's name; a pick holds the row's live name") {
        let b = try RowBoard(mentioning: false)
        let picker = MentionPicker(at: 0, mentions: b.state, scope: AnyMentionable.self, owners: [b.jot], listingRows: true)
        let text = "@orders cust"
        expectEqual(picker.read(text as NSString, selection: NSRange(location: (text as NSString).length, length: 0), isEdit: true), nil)
        let first = try require(picker.rows.compactMap(\.candidate).first)
        expectEqual(first.address, b.row)
        let plain = MentionPicker(at: 0, mentions: b.state, scope: AnyMentionable.self, owners: [b.jot])
        expectEqual(plain.read(text as NSString, selection: NSRange(location: (text as NSString).length, length: 0), isEdit: true), nil)
        expect(plain.rows.compactMap(\.candidate).allSatisfy { $0.part == nil }, "a picker that doesn't list rows lists none")
    },
    test("a row's pill drawn on the canvas is where mentionPills says, naming the row; following it goes to its shape and selects the row") {
        let b = try RowBoard()
        let pills = b.editor.mentionPills(of: b.jot)
        expectEqual(pills.map(\.target), [b.row])
        expect(pills.allSatisfy(\.isLive))
        b.state.follow(b.row)
        b.h.wait(10)
        expectEqual(b.editor.selectedShapeIDs, [b.orders])
        expectEqual(b.editor.selectedItems?.ids, [AnyHashable(b.customerID.id)], "the row selected, an item of its shape")
    },
    test("a frame's row pills read their shape's parts once for them all, and again once the shape changes") {
        let b = try RowBoard()
        let many = MentionText((0..<20).flatMap { _ in [MentionRun.text(" "), .mention(b.row, label: "orders.customer_id")] })
        let busy = b.editor.add(Jot(CGRect(x: 300, y: 300, width: 400, height: 300), text: many), titled: nil)
        let before = MentionDrawingCounts.partsRead
        expectEqual(b.editor.mentionPills(of: busy).count, 20)
        expectEqual(MentionDrawingCounts.partsRead, before + 1, "twenty pills of one row, one read of the shape's parts")
        _ = b.editor.mentionPills(of: busy)
        _ = b.editor.mentionPills(of: b.jot)
        expectEqual(MentionDrawingCounts.partsRead, before + 1, "and the next sweep, of these or others, none")
        b.editor.transact("Rename") { $0.update(b.orders, as: Roster.self) { $0.props.rows[1].name = "buyer_id" } }
        _ = b.editor.mentionPills(of: busy)
        expectEqual(MentionDrawingCounts.partsRead, before + 2, "the shape changed: read again, once")
        expectEqual(b.state.resolve(b.row).appearance?.label, "orders.buyer_id")
    },
])

// MARK: Across boards

/// The orders and customers rosters on the root, a pocket, and on the pocket's board a jot mentioning orders' `customer_id`.
@MainActor private final class RowPocket {
    let h: EditorHarness
    let orders = ShapeID(), customers = ShapeID(), pocket = ShapeID(), jot = ShapeID()
    let id = RosterRow(name: "id"), customerID = RosterRow(name: "customer_id")
    var editor: CanvasEditor { h.editor }
    var state: MentionState { h.editor.mentionState }
    var row: PartAddress { PartAddress(orders, part: customerID.id) }
    var pocketBoard: BoardID { BoardID(owner: pocket) }
    var text: MentionText? { editor.file.record(jot)?.typed(as: Jot.self)?.props.text }

    init() throws {
        func titled(_ props: some ShapeProps, _ id: ShapeID, _ title: String) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, props))
            record[TitleProperty.self] = title
            return record
        }
        let root = [titled(Roster(CGRect(x: 0, y: 0, width: 160, height: 80), rows: [id, customerID]), orders, "orders"),
                    titled(Roster(CGRect(x: 300, y: 0, width: 160, height: 60), rows: []), customers, "customers"),
                    AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 1200, y: 1200, width: 100, height: 100))))]
        let text = MentionText([.text("Ask "), .mention(PartAddress(orders, part: customerID.id), label: "orders.customer_id")])
        let inside = [AnyShapeRecord(ShapeRecord(id: jot, Jot(CGRect(x: 20, y: 20, width: 220, height: 100), text: text)))]
        h = try EditorHarness(plugins: mentionPlugins([PocketsPlugin(), RostersPlugin(), rosterNames, rosterItems, FreezingPlugin()]),
                              file: CanvasFile(root: CanvasDocument(shapes: root), children: [pocket: CanvasDocument(shapes: inside)]))
        editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    }

    /// The column moved from "orders" to "customers", as a step.
    func move() -> PartAddress {
        let moved = PartAddress(customers, part: customerID.id)
        editor.transact("Move Column") { tx in
            tx.update(orders, as: Roster.self) { $0.props.rows.remove(at: 1) }
            tx.update(customers, as: Roster.self) { $0.props.rows.append(customerID) }
            tx.moveParts([row: moved])
        }
        return moved
    }
}

@MainActor let rowCrossBoardTests = Suite("Mentions of a row, across boards", [
    test("a row moved to another shape renames the mentions on another board in the same step, Undo gives them back, and a locked one there keeps its text") {
        let b = try RowPocket()
        expectEqual(b.state.labels.label(of: b.row), "orders.customer_id", "kept from the file's open, read for all of a shape's rows at once")
        expectEqual(b.state.resolve(b.row).appearance?.label, "orders.customer_id", "live from the pocket's board")
        let moved = b.move()
        expectEqual(b.editor.board, .root, "written from the root; the pocket's board was never shown")
        expectEqual(b.text?.mentionedTargets, [moved], "the mention on the other board names where the row went")
        expectEqual(b.state.resolve(moved).appearance?.label, "customers.customer_id")
        expectEqual(b.state.mentioners(of: moved), [b.jot])
        b.editor.undo()
        expectEqual(b.text?.mentionedTargets, [b.row], "one step gives it back")
        expect(b.state.resolve(b.row).isLive)

        b.editor.transact(on: b.pocketBoard, "Lock") { $0.update(b.jot) { $0[Frozen.self] = true } }
        _ = b.move()
        expectEqual(b.text?.mentionedTargets, [b.row], "a locked mention's text is left as it was")
        expectEqual(b.state.resolve(b.row), .missing, "its pill naming a row that's gone")
    },
])
