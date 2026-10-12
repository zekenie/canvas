import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Foundation
import LanguageModels
import Locking
import Mentions
import Queries
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit
import Titles
import Types

// The story file every query example runs on (the skill's, the prompt's, the evaluation's and these
// tests'), "Roadmap", built with the shipped kinds and fixed ids, `00000000-0000-4000-8000-0000000000NN`
// (NN in hex, the design's `…NN`), the design's letters naming them:
//
//     Roadmap (the top board), back to front:
//       P  …01  subboard "Payments"
//       A  …02  sticky-note "API gateway"   text: Owns auth. See @Checkout    (mentions C)
//       U  …03  sticky-note "Auth"          text: JWT, 15 min expiry
//       N1 …04  sticky-note (untitled)      text: TODO: rate limits
//       W  …05  sticky-note "Warehouse"     a type: schema {"type": "object", ...}, text: A warehouse: its id
//       S  …06  sticky-note "Order"         a type: schema {"type": "object", ...}, text: An order: its id, locked
//       V  …07  sticky-note (untitled)      a type: schema {"type": "object" "title": …}   (not JSON: an error), text: An invoice
//       R1 …08  arrow A → U                 channel note-link
//       R2 …09  arrow W → P                 no channel
//       L  …0A  sticky-note "Ledger"        text: Moved to @Old ledger        (Old ledger, …FF, is gone)
//       T1 …0B  sticky-note "Person"        a type: schema {"type": "object", ...}, text: A person: their name
//       T2 …0C  sticky-note "Employee card" a type that is a Person (is: Person), text: A person at work: their desk, when they started, their teams
//       I  …0D  sticky-note "Ann"           an Employee card (is: Employee card), text: Ann, on the platform team;
//                                           fieldValues started 2024-05-01, teams platform and search
//     Payments' board (P):
//       C  …11  sticky-note "Checkout"      text: Calls @API gateway for tokens    (mentions A)
//       F  …12  subboard "Refunds"
//       N2 …13  sticky-note (untitled)      text: Retry on 502
//     Refunds' board (F):
//       Y  …21  sticky-note "Refund policy" text: 30 days, locked
//
// Its window shows the top board, and Auth is selected. File order: P, C, F, Y, N2, A, U, N1, W,
// S, V, R1, R2, L, T1, T2, I.

/// The story file: its shapes' ids, the file (`file(in:)`), and the file open as the app has it,
/// in an editor (`harness`) or a board document (`document`).
@MainActor
enum QueryStory {
    /// `…NN`: the story's id for `nn`.
    static func id(_ nn: UInt8) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000000%02X", nn))!)
    }

    static let payments = id(0x01), gateway = id(0x02), auth = id(0x03), todo = id(0x04), warehouse = id(0x05)
    static let order = id(0x06), invoice = id(0x07), gatewayToAuth = id(0x08), warehouseToPayments = id(0x09), ledger = id(0x0A)
    static let person = id(0x0B), employeeCard = id(0x0C), ann = id(0x0D)
    static let checkout = id(0x11), refunds = id(0x12), retry = id(0x13), refundPolicy = id(0x21)
    /// "Old ledger", which Ledger mentions: in no board of the file.
    static let oldLedger = id(0xFF)

    /// Each shape by the design's letter for it.
    static let letters: [String: ShapeID] = [
        "P": payments, "A": gateway, "U": auth, "N1": todo, "W": warehouse, "S": order, "V": invoice, "R1": gatewayToAuth,
        "R2": warehouseToPayments, "L": ledger, "T1": person, "T2": employeeCard, "I": ann, "C": checkout, "F": refunds, "N2": retry, "Y": refundPolicy,
    ]

    /// Shapes by their letters, as the design lists them: "C, Y, N2".
    static func ids(_ list: String) -> [ShapeID] {
        list.split(separator: ",").map { part in
            let letter = part.trimmingCharacters(in: .whitespaces)
            guard let id = letters[letter] else { preconditionFailure("the story has no shape \(letter)") }
            return id
        }
    }

    /// Every shape, in file order: the top board back to front, each subboard followed by its board's.
    static let fileOrder = ids("P, C, F, Y, N2, A, U, N1, W, S, V, R1, R2, L, T1, T2, I")

    /// Order's schema: an object with an id. (A type's name is its note's title, not its schema's.)
    static let orderSchema = #"{"type": "object", "properties": {"id": {"type": "string"}}}"#
    /// Warehouse's: the same.
    static let warehouseSchema = #"{"type": "object", "properties": {"id": {"type": "string"}}}"#
    /// Person's and Employee card's: an object with a name, and with a desk, the day they started and
    /// their teams (each with a name).
    static let personSchema = #"{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}"#
    static let employeeCardSchema = """
        {"type": "object", "properties": {"desk": {"type": "string"}, "started": {"type": "string", "format": "date"}, \
        "teams": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}}}}}}
        """
    /// Invoice's: not JSON, a comma left out before a title, so it's invalid (an error).
    static let invoiceSchema = #"{"type": "object" "title": "Invoice"}"#

    /// The view a board of the story is shown in, as the skill's boards are.
    static let viewport = CGSize(width: 1440, height: 900)

    /// The file, its arrows made by the shipped connector as a connection made by name is
    /// (`ArrowPortsPlugin`: both ends bound at their shapes' centers, R1 on the note-link channel).
    static func file(in registry: Registry) -> CanvasFile {
        func note(_ id: ShapeID, _ title: String?, at x: CGFloat, _ y: CGFloat, _ text: MentionText, locked: Bool = false) -> AnyShapeRecord {
            var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: CGPoint(x: x, y: y), size: StickyNote.defaultSize), text: text))
            note[TitleProperty.self] = title
            note[LockedProperty.self] = locked ? true : nil
            return AnyShapeRecord(note)
        }
        func subboard(_ id: ShapeID, _ title: String, at x: CGFloat, _ y: CGFloat) -> AnyShapeRecord {
            var subboard = ShapeRecord(id: id, Subboard(frame: CGRect(origin: CGPoint(x: x, y: y), size: Subboard.defaultSize)))
            subboard[TitleProperty.self] = title
            return AnyShapeRecord(subboard)
        }
        func type(_ id: ShapeID, _ title: String?, _ schema: String, at x: CGFloat, _ y: CGFloat, _ text: String, locked: Bool = false) -> AnyShapeRecord {
            var record = note(id, title, at: x, y, MentionText(plain: text), locked: locked)
            record[TypeSchemaProperty.self] = SchemaText(schema)
            return record
        }
        func instance(_ id: ShapeID, _ title: String, of types: [ShapeID], at x: CGFloat, _ y: CGFloat, _ text: String) -> AnyShapeRecord {
            var record = note(id, title, at: x, y, MentionText(plain: text))
            record[IsAProperty.self] = types.map(TypeLink.init)
            return record
        }
        let top = [
            subboard(payments, "Payments", at: 80, 80),
            note(gateway, "API gateway", at: 400, 80, MentionText([.text("Owns auth. See "), .mention(checkout, label: "Checkout")])),
            note(auth, "Auth", at: 700, 80, MentionText(plain: "JWT, 15 min expiry")),
            note(todo, nil, at: 1000, 80, MentionText(plain: "TODO: rate limits")),
            type(warehouse, "Warehouse", warehouseSchema, at: 80, 420, "A warehouse: its id"),
            type(order, "Order", orderSchema, at: 400, 420, "An order: its id", locked: true),
            type(invoice, nil, invoiceSchema, at: 700, 420, "An invoice"),
        ]
        func connection(_ id: ShapeID, _ request: ConnectionRequest) -> AnyShapeRecord {
            guard let made = registry.connection(request, in: ShapeContext(document: CanvasDocument(shapes: top), registry: registry)) else {
                preconditionFailure("the shipped connector connects \(request.from) to \(request.to)")
            }
            return made.copy(as: id)
        }
        let arrows = [
            connection(gatewayToAuth, ConnectionRequest(from: gateway, to: auth, channel: NoteLink.id)),
            connection(warehouseToPayments, ConnectionRequest(from: warehouse, to: payments)),
        ]
        let last = note(ledger, "Ledger", at: 1000, 420, MentionText([.text("Moved to "), .mention(oldLedger, label: "Old ledger")]))
        let people = [
            type(person, "Person", personSchema, at: 80, 760, "A person: their name"),
            {
                var card = type(employeeCard, "Employee card", employeeCardSchema, at: 400, 760, "A person at work: their desk")
                card[IsAProperty.self] = [TypeLink(person)]
                return card
            }(),
            {
                var ann = instance(ann, "Ann", of: [employeeCard], at: 700, 760, "Ann, on the platform team")
                ann[FieldValuesProperty.self] = FieldValues(["started": "2024-05-01", "teams": [["name": "platform"], ["name": "search"]]])
                return ann
            }(),
        ]
        return CanvasFile(
            root: CanvasDocument(shapes: top + arrows + [last] + people),
            children: [
                payments: CanvasDocument(shapes: [
                    note(checkout, "Checkout", at: 80, 80, MentionText([.text("Calls "), .mention(gateway, label: "API gateway"), .text(" for tokens")])),
                    subboard(refunds, "Refunds", at: 400, 80),
                    note(retry, nil, at: 700, 80, MentionText(plain: "Retry on 502")),
                ]),
                refunds: CanvasDocument(shapes: [note(refundPolicy, "Refund policy", at: 80, 80, MentionText(plain: "30 days"), locked: true)]),
            ])
    }

    /// The story in an editor of the shipped plugins, their clipboard on `pasteboard` (a test's own)
    /// and their model `model`: the top board shown, in `viewport`, Auth selected.
    static func harness(pasteboard: NSPasteboard, model: any LanguageModel = ScriptedLanguageModel()) throws -> EditorHarness {
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: model)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file(in: registry), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        h.editor.selection = auth
        return h
    }

    /// The story as the app opens it: a board document read from the file as written, with the
    /// boards' configuration (`configureBoards(pasteboard:)`, first), in its window as the app makes
    /// it (unshown), or with none, in `viewport`; the top board shown, Auth selected, not edited.
    static func document(windowed: Bool = true) throws -> BoardDocument {
        let registry = try require(BoardDocument.configuration, "boards are configured").registry
        let board = BoardDocument()
        try board.read(from: try BoardCodec(registry: registry).encode(file(in: registry)), ofType: boardType)
        if windowed {
            board.makeWindowControllers()
            try require(board.windowControllers.first?.window).settle()
        } else {
            board.editor.viewportDidResize(to: viewport)
        }
        board.editor.selection = auth
        return board
    }
}

@MainActor let queryStoryTests = Suite("Query story", [
    test("the story file: * answers its 17 shapes in file order, as an editor and a board document have it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryStory.harness(pasteboard: pasteboard)
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [QueryStory.auth])
        expectEqual(h.file.root.shapes.count, 13)
        expectEqual(h.file.children.count, 2, "Payments' board and Refunds'")
        let queries = try require(h.editor.queries)
        let all = try awaitResult { try await queries.run(QueryRequest("*", limit: QueryBudget.maxRows, properties: .none)) }
        expectEqual(all.count, 17)
        expectEqual(all.rows.map(\.id), QueryStory.fileOrder)

        // What the rows say of it: titles (Order's its own, Invoice untitled), where each is, and
        // the arrows bound at both ends as the connector binds them.
        let rows = Dictionary(uniqueKeysWithValues: all.rows.map { ($0.id, $0) })
        expectEqual(rows[QueryStory.order]?.title, "Order")
        expectEqual(rows[QueryStory.invoice]?.title, nil)
        expectEqual(rows[QueryStory.todo]?.title, nil)
        expectEqual(rows[QueryStory.refundPolicy]?.inside, ["Payments", "Refunds"])
        expectEqual(rows[QueryStory.gatewayToAuth]?.connection?.from.id, QueryStory.gateway)
        expectEqual(rows[QueryStory.gatewayToAuth]?.connection?.to.id, QueryStory.auth)
        expectEqual(rows[QueryStory.gatewayToAuth]?.connection.map { "\($0.type)" }, NoteLink.id.rawValue)
        expectEqual(rows[QueryStory.warehouseToPayments]?.connection?.from.id, QueryStory.warehouse)
        expectEqual(h.file.record(QueryStory.gatewayToAuth)?[ChannelProperty.self], NoteLink.id)
        expectEqual(h.file.record(QueryStory.warehouseToPayments)?[ChannelProperty.self], nil)
        expect(h.file.record(QueryStory.order)?.isLocked == true && h.file.record(QueryStory.refundPolicy)?.isLocked == true)
        expectEqual(h.editor.mentions?.mentions(in: QueryStory.ledger), [QueryStory.oldLedger])
        expectEqual(h.file.record(QueryStory.oldLedger), nil, "gone from the file")

        // The same file as the app opens it, in its window.
        try configureBoards(pasteboard: pasteboard)
        let board = try QueryStory.document()
        defer { board.close() }
        expect(board.windowControllers.first?.window != nil)
        expectEqual(board.editor.selectedShapeIDs, [QueryStory.auth])
        expect(!board.isDocumentEdited)
        let opened = try require(board.editor.queries)
        let listed = try awaitResult { try await opened.run(QueryRequest("*", limit: QueryBudget.maxRows, properties: .none)) }
        expectEqual(listed.rows.map(\.id), QueryStory.fileOrder)

        // And as `canvas`, as built, asks the app for it.
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let asked = try canvas(server, ["query", "*", "--brief", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        let answer = try JSON(text: asked.output)
        expectEqual(answer["count"], 17)
        expectEqual(answer["rows"]?.arrayValue?.map { $0["id"] }, QueryStory.fileOrder.map { .string($0.description) })
        expect(!board.isDocumentEdited, "a query changes nothing")
    },
])
