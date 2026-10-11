import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Publishing
import Queries
import References
import ShippedTesting
import StickyNotes
import TestKit
import Titles
import Topology

// The story file the skill's reference/references.md runs on, "Services": a small board with a public
// note, a reference to it, and the arrows that run into the reference (not into the note), built
// with fixed ids, `00000000-0000-4000-8000-0000000000NN` (NN in hex), and the Roadmap's (`QueryStory`)
// style, but a story of its own, since its expected rows would all move the Roadmap's.
//
//     Services (the top board), back to front:
//       A  …01  sticky-note "Auth"      text: JWT, 15 min expiry   public
//       B  …02  sticky-note "Checkout"  text: Takes the payment
//       C  …03  sticky-note "Billing"   text: Sends the invoice
//       D  …04  sticky-note "Drafts"    text: Not for sharing yet   (private)
//       R  …05  reference to Auth       (a pill: it stands for Auth while Auth is public)
//       X1 …06  arrow Checkout → R      no channel
//       X2 …07  arrow Billing → R       no channel
//
// The arrows are made by hand, bound at both ends and on no channel: a port drag always sets a
// channel, and a channeled end binds only where the registry takes it, so none can end on a pill
// by hand yet. File order: A, B, C, D, R, X1, X2. Its window shows the board, and nothing is selected.

/// The story file: its shapes' ids, the file (`file(in:)`), and the file open as the app has it, in an
/// editor (`harness`) or a board document (`document`).
@MainActor
enum QueryReferenceStory {
    /// `…NN`: the story's id for `nn`.
    static func id(_ nn: UInt8) -> ShapeID {
        ShapeID(UUID(uuidString: String(format: "00000000-0000-4000-8000-0000000000%02X", nn))!)
    }

    static let auth = id(0x01), checkout = id(0x02), billing = id(0x03), drafts = id(0x04), reference = id(0x05)
    static let checkoutToReference = id(0x06), billingToReference = id(0x07)

    /// Each shape by its letter.
    static let letters: [String: ShapeID] = [
        "A": auth, "B": checkout, "C": billing, "D": drafts, "R": reference, "X1": checkoutToReference, "X2": billingToReference,
    ]

    /// Every shape, in file order.
    static let fileOrder = [auth, checkout, billing, drafts, reference, checkoutToReference, billingToReference]

    /// The view the board is shown in, as the skill's boards are.
    static let viewport = CGSize(width: 1440, height: 900)

    static func file(in registry: Registry) -> CanvasFile {
        func note(_ id: ShapeID, _ title: String, at x: CGFloat, _ y: CGFloat, _ text: String, isPublic: Bool = false) -> AnyShapeRecord {
            var note = ShapeRecord(id: id, StickyNote(frame: CGRect(origin: CGPoint(x: x, y: y), size: StickyNote.defaultSize), text: MentionText(plain: text)))
            note[TitleProperty.self] = title
            note[PublicProperty.self] = isPublic ? true : nil
            return AnyShapeRecord(note)
        }
        func bound(_ id: ShapeID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        }
        var pill = Reference(frame: CGRect(x: 1000, y: 240, width: 120, height: 32))
        ReferenceEdits.pick(&pill, ReferenceTarget(id: auth, label: "Auth"))
        let shapes = [
            note(auth, "Auth", at: 1000, 520, "JWT, 15 min expiry", isPublic: true),
            note(checkout, "Checkout", at: 80, 80, "Takes the payment"),
            note(billing, "Billing", at: 80, 440, "Sends the invoice"),
            note(drafts, "Drafts", at: 400, 80, "Not for sharing yet"),
            AnyShapeRecord(ShapeRecord(id: reference, pill)),
            AnyShapeRecord(ShapeRecord(id: checkoutToReference, Arrow(start: bound(checkout), end: bound(reference)))),
            AnyShapeRecord(ShapeRecord(id: billingToReference, Arrow(start: bound(billing), end: bound(reference)))),
        ]
        return CanvasFile(root: CanvasDocument(shapes: shapes))
    }

    /// The story in an editor of the shipped plugins, their clipboard on `pasteboard` (a test's own) and
    /// their model `model`: the board shown, in `viewport`.
    static func harness(pasteboard: NSPasteboard, model: any LanguageModel = ScriptedLanguageModel()) throws -> EditorHarness {
        let registry = try ShippedPlugins.registry(pasteboard: pasteboard, model: model)
        let h = EditorHarness { CanvasEditor(registry: registry, file: file(in: registry), scheduler: $0) }
        h.editor.viewportDidResize(to: viewport)
        return h
    }

    /// The story as the app opens it: a board document read from the file as written, with the boards'
    /// configuration (`configureBoards(pasteboard:)`, first), in its window as the app makes it
    /// (unshown), or with none, in `viewport`; not edited.
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
        return board
    }
}

@MainActor let queryReferenceStoryTests = Suite("Query reference story", [
    test("the story file: 7 shapes in file order, Auth public and referenced, the arrows bound at both ends to Checkout, Billing and the pill") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let h = try QueryReferenceStory.harness(pasteboard: pasteboard)
        expectEqual(h.editor.board, .root)
        expectEqual(h.file.root.shapes.map(\.id), QueryReferenceStory.fileOrder)
        let queries = try require(h.editor.queries)
        let all = try storyAnswer("*", on: queries).get()
        expectEqual(all.rows.map(\.id), QueryReferenceStory.fileOrder)
        expect(h.file.record(QueryReferenceStory.auth)?[PublicProperty.self] == true)
        expectEqual(h.file.record(QueryReferenceStory.drafts)?[PublicProperty.self], nil)
        expectEqual(h.editor.topology?.standIns(for: QueryReferenceStory.auth), [QueryReferenceStory.reference], "the pill stands for Auth")
        expectEqual(h.file.record(QueryReferenceStory.checkoutToReference)?[ChannelProperty.self], nil, "no channel")

        // The same file as the app opens it, and as `canvas`, as built, asks the app for it.
        try configureBoards(pasteboard: pasteboard)
        let board = try QueryReferenceStory.document()
        defer { board.close() }
        expect(!board.isDocumentEdited)
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let asked = try canvas(server, ["query", "*", "--brief", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        let answer = try JSON(text: asked.output)
        expectEqual(answer["count"], 7)
        expectEqual(answer["rows"]?.arrayValue?.map { $0["id"] }, QueryReferenceStory.fileOrder.map { .string($0.description) })
        expect(!board.isDocumentEdited, "a query changes nothing")
    },

    test("an arrow into the pill is a connection to Auth, through the pill: the row's via names it, as reference/references.md shows") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = try QueryReferenceStory.document()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let asked = try canvas(server, ["query", #"arrow:ends-at("Auth")"#, "--brief", "--board", "\(board.number)"])
        expectEqual(asked.status, 0, asked.error)
        let answer = try JSON(text: asked.output)
        let rows = try require(answer["rows"]?.arrayValue)
        expectEqual(rows.map { $0["id"] }, [.string(QueryReferenceStory.checkoutToReference.description), .string(QueryReferenceStory.billingToReference.description)])
        let connection = try require(rows.first?["connection"])
        expectEqual(connection["to"]?["title"], "Auth")
        expectEqual(connection["from"]?["title"], "Checkout")
        expectEqual(connection["via"]?["to"]?["id"], .string(QueryReferenceStory.reference.description), "through the pill")
        expectEqual(connection["more"], nil, "it stands for one shape")
        // What the skill's page shows of it is this row's connection, as the app writes it.
        let guide = try String(contentsOfFile: "\(skillFolder)/reference/references.md", encoding: .utf8)
        let shown = #""via":{"to":{"id":"\#(QueryReferenceStory.reference.description)"}}"#
        expect(guide.contains(shown), "references.md shows the row's via: \(shown)")
        expect(answer["warnings"] == nil, "nothing pending")
    },
])
