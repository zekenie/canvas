import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasUI
import CoreGraphics
import Draw
import Foundation
import Frames
import Mentions
import Publishing
import References
import StickyNotes
import Subboards
import TestKit
import Titles

// `registry.drawConnection`, as shipped: the arrow it makes by id is the arrow `canvas draw` makes for
// an edge between the same two shapes.

@MainActor let drawConnectionShippedTests = Suite("A connection by id, as shipped", [
    test("note to note, note to subboard, and note to a pill with what it stands for: the same arrow as a script's edge, but for its id; nothing written") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let checkout = ShapeID(), ledger = ShapeID(), payments = ShapeID(), auth = ShapeID()
        @MainActor func note(_ id: ShapeID, _ title: String, at point: CGPoint, public isPublic: Bool = false) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title))))
            record[TitleProperty.self] = title
            if !isPublic { record[PrivateProperty.self] = true }
            return record
        }
        var subboard = AnyShapeRecord(ShapeRecord(id: payments, Subboard(frame: CGRect(x: 800, y: 500, width: 240, height: 160))))
        subboard[TitleProperty.self] = "Payments"
        let file = CanvasFile(root: CanvasDocument(shapes: [note(checkout, "Checkout", at: CGPoint(x: 100, y: 100)), note(ledger, "Ledger", at: CGPoint(x: 100, y: 500)), subboard]),
                              children: [payments: CanvasDocument(shapes: [note(auth, "Auth", at: .zero, public: true)])])
        let board = windowedBoard()
        defer { board.close() }
        board.editor.replaceFile(with: file)
        let editor = board.editor
        _ = try drawnInProcess("""
            edge "Checkout" -> "Ledger"
            edge "Checkout" -> "Payments"
            edge "Checkout" -> "Auth"
            """, on: editor)
        let arrows = editor.document.shapes.filter { $0.kind == Arrow.kind }
        expectEqual(arrows.count, 3)
        let pill = try require(editor.document.shapes.first { $0.kind == Reference.kind })
        expect(editor.registry.drawsConnections)
        let before = editor.file
        @MainActor func drawn(to end: ShapeID) throws -> AnyShapeRecord {
            try require(arrows.first { $0.typed(as: Arrow.self)?.props.end.binding?.shapeID == end })
        }
        for (what, end, standing) in [("note to note", ledger, [ShapeKind]()), ("note to subboard", payments, []), ("note to a pill", pill.id, [StickyNote.kind])] {
            let scripted = try drawn(to: end)
            // The first arrow of its pair, as the script's was (told, as a run tells it): a second would be bent apart.
            let made = try require(editor.registry.drawConnection(from: checkout, to: end, in: editor.shapeContext, standingFor: (from: [], to: standing), beside: []), what)
            expect(made.id != scripted.id, "\(what): a new shape")
            expectEqual(made.propertiesJSON, scripted.propertiesJSON, "\(what): the same arrow")
        }
        expectEqual(editor.file, before, "it writes nothing")
        expect(!editor.canUndo || editor.undoHistory.undoName != nil, "no step of its own")
    },
    test("a run's second edge between one pair, either way, is bent apart from the first, and the same script again is unchanged") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        _ = try drawnInProcess("""
            sticky-note "Checkout"
            sticky-note "Ledger" right of "Checkout"
            sticky-note "Audit" below "Checkout"
            """, on: editor)
        let result = try drawnInProcess("""
            edge "Checkout" -> "Ledger"
            edge "Ledger" -> "Checkout"
            edge "Checkout" -> "Audit"
            """, on: editor)
        let changes = result["changes"]?.arrayValue ?? []
        expectEqual(changes.filter { $0["did"]?.stringValue == "connected" }.count, 3)
        let arrows = editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props }
        expectEqual(arrows.count, 3)
        expectEqual(arrows[0].bend, 0, "a pair's first arrow")
        expect(abs(arrows[1].bend) == 34, "the second of the pair: \(arrows[1].bend)")
        expectEqual(arrows[2].bend, 0, "another pair's")
        let revision = editor.revision
        let again = try drawnInProcess("""
            edge "Checkout" -> "Ledger"
            edge "Ledger" -> "Checkout"
            edge "Checkout" -> "Audit"
            """, on: editor)
        expectEqual((again["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(editor.revision, revision)
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props.bend }, [0, arrows[1].bend, 0])
    },
    test("one script that draws two notes and two edges between them, one each way, lays out and commits with the debug check passing: the second is bent, and the same script again is unchanged") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        let script = """
            sticky-note "Checkout"
            sticky-note "Ledger" right of "Checkout"
            edge "Checkout" -> "Ledger"
            edge "Ledger" -> "Checkout"
            """
        // (A debug build holds each arrow drawn to the one `layOut()` laid in, bend and all, and stops the process if they differ.)
        let result = try drawnInProcess(script, on: editor)
        expectEqual((result["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["created", "created", "connected", "connected"])
        let bends = editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props.bend }
        expectEqual(bends.count, 2)
        expectEqual(bends.first, 0, "the pair's first arrow")
        expectEqual(bends.last.map { abs($0) }, 34, "the second: \(bends)")
        let revision = editor.revision
        let again = try drawnInProcess(script, on: editor)
        expectEqual((again["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["unchanged", "unchanged", "unchanged", "unchanged"])
        expectEqual(editor.revision, revision)
    },
    test("a script that draws a shape and adds a second edge to a pair the board already joins lays out and commits the arrow beside the board's, bent into the free slot") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        _ = try drawnInProcess("""
            sticky-note "Checkout"
            sticky-note "Ledger" right of "Checkout"
            edge "Checkout" -> "Ledger"
            """, on: editor)
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props.bend }, [0])
        let script = """
            sticky-note "Audit" below "Checkout"
            edge "Ledger" -> "Checkout"
            edge "Checkout" -> "Audit"
            edge "Audit" -> "Checkout"
            """
        let result = try drawnInProcess(script, on: editor)
        expectEqual((result["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["created", "connected", "connected", "connected"])
        let bends = editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props.bend }
        expectEqual(bends.count, 4)
        expectEqual(bends[0], 0, "the board's arrow stays")
        expectEqual(abs(bends[1]), 34, "the second of the board's pair: \(bends)")
        expectEqual(bends[2], 0, "a new pair's first")
        expectEqual(abs(bends[3]), 34, "a new pair's second")
        let again = try drawnInProcess(script, on: editor)
        expectEqual((again["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["unchanged", "unchanged", "unchanged", "unchanged"])
    },
    test("two relationships written over a pair the board joins with one plain arrow, in a script that draws a shape too: the first takes the arrow, the second is drawn beside it, and the arrow laid out is the arrow drawn") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        _ = try drawnInProcess(#"""
            sticky-note "Friendship" schema: "{\"type\": \"object\"}" relationship: true
            sticky-note "Mentorship" right of "Friendship" schema: "{\"type\": \"object\"}" relationship: true
            sticky-note "Ann" below "Friendship"
            sticky-note "Bo" right of "Ann"
            edge "Ann" -> "Bo"
            """#, on: editor)
        // The shape makes the run lay its arrows out before it draws them (debug builds hold each to the arrow drawn).
        let script = #"""
            sticky-note "Cy" below "Ann"
            edge "Ann" -> "Bo" is: "Friendship"
            edge "Ann" -> "Bo" is: "Mentorship"
            """#
        let result = try drawnInProcess(script, on: editor)
        let changes = result["changes"]?.arrayValue ?? []
        expectEqual(changes.compactMap { $0["did"]?.stringValue }, ["created", "reconnected", "connected"])
        expectEqual(changes.compactMap { $0["is"]?.arrayValue?.compactMap(\.stringValue) }, [["Friendship"], ["Mentorship"]])
        let bends = editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props.bend }
        expectEqual(bends.count, 2, "one arrow each")
        expectEqual(bends.first, 0, "the board's arrow, now a Friendship")
        expectEqual(bends.last.map { abs($0) }, 34, "the Mentorship beside it: \(bends)")
        let revision = editor.revision
        let again = try drawnInProcess(script, on: editor)
        expectEqual((again["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["unchanged", "unchanged", "unchanged"])
        expectEqual(editor.revision, revision)
    },
    test("an edge written again after the pair's first was deleted is drawn apart from the arrow that stayed") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        _ = try drawnInProcess("""
            sticky-note "Checkout"
            sticky-note "Ledger" right of "Checkout"
            edge "Checkout" -> "Ledger"
            edge "Ledger" -> "Checkout"
            """, on: editor)
        _ = try drawnInProcess(#"delete edge "Checkout" -> "Ledger""#, on: editor)
        _ = try drawnInProcess(#"edge "Checkout" -> "Ledger""#, on: editor)
        let arrows = editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }
        expectEqual(arrows.count, 2)
        let sides = arrows.map { arrow -> CGFloat in
            // The side a bend bows to is measured against the arrow's own direction.
            (arrow.props.start.binding?.shapeID == arrows[0].props.start.binding?.shapeID ? 1 : -1) * arrow.props.bend
        }
        expect(sides[0] != sides[1], "the two arrows lie on one arc: bends \(arrows.map { $0.props.bend })")
    },
    test("a dry run of the two edges of a pair says what the real run does, and draws nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        _ = try drawnInProcess("""
            sticky-note "Checkout"
            sticky-note "Ledger" right of "Checkout"
            """, on: editor)
        let edges = """
            edge "Checkout" -> "Ledger"
            edge "Ledger" -> "Checkout"
            """
        let dry = try drawnInProcess(edges, on: editor, dryRun: true)
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.count, 0)
        let real = try drawnInProcess(edges, on: editor)
        func summary(_ result: JSON) -> [String] { (result["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue } }
        expectEqual(summary(dry), ["connected", "connected"])
        expectEqual(summary(dry), summary(real))
    },
    test("a second edge that writes bend: 0 keeps it straight, and the same script again is unchanged") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = windowedBoard()
        defer { board.close() }
        let editor = board.editor
        _ = try drawnInProcess("""
            sticky-note "Checkout"
            sticky-note "Ledger" right of "Checkout"
            """, on: editor)
        let script = """
            edge "Checkout" -> "Ledger"
            edge "Ledger" -> "Checkout" bend: 0
            """
        _ = try drawnInProcess(script, on: editor)
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Arrow.self)?.props.bend }, [0, 0])
        let again = try drawnInProcess(script, on: editor)
        expectEqual((again["changes"]?.arrayValue ?? []).compactMap { $0["did"]?.stringValue }, ["unchanged", "unchanged"])
    },
    test("two notes in a frame with room between them: a 160 by 34 box lands in the gap between them, as it does for the same two notes on a bare board") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let a = ShapeID(), b = ShapeID(), frame = ShapeID()
        @MainActor func note(_ id: ShapeID, _ title: String, at point: CGPoint, in container: ShapeID?) -> AnyShapeRecord {
            var record = AnyShapeRecord(ShapeRecord(id: id, StickyNote(frame: CGRect(origin: point, size: CGSize(width: 200, height: 200)), text: MentionText(plain: title))))
            record[TitleProperty.self] = title
            return record.copy(as: id, container: container)
        }
        let size = CGSize(width: 160, height: 34)
        var answers: [CGRect] = []
        for framed in [false, true] {
            var shapes: [AnyShapeRecord] = []
            if framed { shapes.append(AnyShapeRecord(ShapeRecord(id: frame, Frame(frame: CGRect(x: 0, y: 0, width: 1400, height: 600))))) }
            shapes += [note(a, "Feature", at: CGPoint(x: 100, y: 200), in: framed ? frame : nil), note(b, "Layer", at: CGPoint(x: 900, y: 200), in: framed ? frame : nil)]
            let board = windowedBoard()
            defer { board.close() }
            board.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: shapes)))
            if framed { expectEqual(board.editor.document.container(of: a, containingKinds: board.editor.registry.containingKinds), frame, "the note is in the frame") }
            let landing = try require(Surroundings(on: .root, moving: size, in: board.editor)?.between(a, b))
            answers.append(landing.rect)
        }
        expectEqual(answers[0], CGRect(x: 520, y: 283, width: 160, height: 34), "bare: centered in the gap, on the middle of the two")
        expectEqual(answers[1], answers[0], "in a frame: the same place")
    },
])
