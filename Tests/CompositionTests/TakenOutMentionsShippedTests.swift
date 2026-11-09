import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Engineering
import Geometry
import LineRows
import Mentions
import References
import Selection
import ShippedTesting
import StickyNotes
import TestKit
import Titles

// An endpoint taken out of its API, mentioned, and put back (U10, review U6-E2), through a new board's window: a mention the `@`
// picker writes (typed in a note) and one `canvas draw` writes (`@[createRefund]`) are of its row, and keep that one address and
// one look (the method's chip and the path) as it is put back by its chip, taken out again, undone and redone, on its board and
// another; a mention of the shape as a whole (`@[…](shape:ID)`, as an agent may keep one) is drawn as its row and follows it back
// too; a pill for it, as a whole or at its row, stands for the row it went to; and each pill is measured as wide as it is drawn.

@MainActor private func api(_ editor: CanvasEditor, _ title: String) -> ShapeRecord<API>? {
    editor.document.shapes.first { $0[TitleProperty.self] == title }?.typed(as: API.self)
}

@MainActor private func titled(_ editor: CanvasEditor, _ title: String, on board: BoardID) -> AnyShapeRecord? {
    editor.contents(of: board).shapes.first { $0[TitleProperty.self] == title }
}

/// The mentions a note holds, wherever it is in the file.
@MainActor private func targets(_ editor: CanvasEditor, _ note: ShapeID) -> [PartAddress] {
    let text = (editor.document[note] ?? editor.file.record(note))?.typed(as: StickyNote.self)?.props.text
    return text?.runs.compactMap { run in if case .mention(let target, _) = run { target } else { nil } } ?? []
}

@MainActor private func ownEndpoint(_ editor: CanvasEditor) -> ShapeRecord<StandaloneEndpoint>? {
    editor.document.shapes.lazy.compactMap { $0.typed(as: StandaloneEndpoint.self) }.first
}

/// The orders API, its refunds endpoint named; storefront's board below it.
private let scene = #"""
    api "orders API" server: "api.shop.dev/v1 bearer" endpoints: "GET /orders/{id}\nPOST /orders\nPOST /orders/{id}/refunds"
    subboard "storefront" below "orders API" (gap: 160)
    """#

@MainActor let takenOutMentionsShippedTests = Suite("A taken-out endpoint's mentions, put back, shipped", [
    test("a mention the @ picker writes and one draw writes keep the row's address and look through put-back by the chip, take-out, Undo and Redo, here and on another board; a mention of the shape as a whole follows too, drawn as the row; measured as drawn") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(scene)
        try w.draw(#"api "orders API" endpoints: [{"method": "POST", "path": "/orders/{id}/refunds", "name": "createRefund"}]"#)
        let editor = w.editor
        let mentions = try require(editor.mentions)
        let orders = try require(api(editor, "orders API"))
        let refunds = orders.props.endpoints[2].id
        let storefront = BoardID(owner: try require(titled(editor, "storefront", on: .root)).id)
        // Taken out, as the selection's menu does: an endpoint of its own beside the API.
        expect(editor.moveRows([refunds], of: orders.id, to: .beside([orders.id])) != nil)
        let alone = try require(ownEndpoint(editor)).id
        expectEqual(editor.undoHistory.undoName, "Take Out Endpoint")
        let row = PartAddress(alone, part: refunds)

        // The @ picker in a note on the board: "@createRefund" typed, Return.
        let note = editor.add(StickyNote(frame: CGRect(x: 0, y: 700, width: 260, height: 120), text: "See "))
        editor.selectedShapeIDs = [note]
        expect(editor.beginEditing(note))
        let text = try require(w.window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        text.setSelectedRange(NSRange(location: 4, length: 0))
        w.window.type("@createRefund")
        let picker = try require(text.picker, "the picker is open")
        expectEqual(picker.highlightedCandidate?.address, row, "the endpoint listed as its row, found by its name")
        w.window.pressReturn()
        w.window.pressEscape()
        expectEqual(editor.editingShapeID, nil)
        expectEqual(targets(editor, note), [row], "the pick mentions the row")
        // Draw, on storefront's board: by its name, and the shape as a whole as an agent may keep it from a query's rows.
        _ = try drawnInProcess(#"""
            sticky-note "far" in "storefront" text: "Refunds: @[createRefund]"
            sticky-note "kept" in "storefront" below "far" text: "Whole: @[createRefund](shape:\#(alone.rawValue.uuidString))"
            """#, on: editor)
        let far = try require(titled(editor, "far", on: storefront)).id
        let kept = try require(titled(editor, "kept", on: storefront)).id
        expectEqual(targets(editor, far), [row], "draw's @[createRefund] mentions the row, as the picker does")
        expectEqual(targets(editor, kept), [PartAddress(alone)], "a whole mention is kept as written")
        // A pill for it on storefront's board, as a whole and at its row.
        let pills = editor.transact(on: storefront, "Add Pills") { tx -> (ShapeID, ShapeID) in
            let whole = ShapeRecord(Reference(frame: CGRect(x: 0, y: 400, width: 200, height: 40), target: ReferenceTarget(id: alone, label: "createRefund")))
            let atRow = ShapeRecord(Reference(frame: CGRect(x: 0, y: 500, width: 200, height: 40),
                                              target: ReferenceTarget(id: alone, label: "POST /orders/{id}/refunds", row: refunds)))
            tx.insert(AnyShapeRecord(whole))
            tx.insert(AnyShapeRecord(atRow))
            return (whole.id, atRow.id)
        }
        let (wholePill, rowPill) = try require(pills)
        editor.undoHistory.seal()

        /// Every mention looks as an endpoint's does: live, its method in its chip and its path.
        @MainActor func looksAsTheRow(_ when: String) {
            for target in [note, far, kept].flatMap({ targets(editor, $0) }) {
                let shown = mentions.resolve(target)
                expectEqual(shown.appearance?.label, "POST /orders/{id}/refunds", "\(when): \(target)")
                expect({ if case .chip("POST", _)? = shown.appearance?.lead { true } else { false } }(), "\(when): the method's chip, \(target)")
            }
            expect(editor.mentionPills(of: note).allSatisfy(\.isLive) && !editor.mentionPills(of: note).isEmpty, "\(when): the note's pill live")
        }
        looksAsTheRow("taken out")
        // On the canvas a mention of the shape as a whole draws what one of its row does, pixel for pixel.
        let scratch = editor.add(StickyNote(frame: CGRect(x: 700, y: 700, width: 300, height: 80), text: MentionText([.mention(PartAddress(alone), label: "createRefund")])))
        editor.selectedShapeIDs = []
        let size = CGSize(width: 1600, height: 1100)
        let frame = try require(editor.shapeContext.frame(of: scratch))
        let a = editor.camera.toView(frame.origin), b = editor.camera.toView(CGPoint(x: frame.maxX, y: frame.maxY))
        let inView = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).intersection(CGRect(origin: .zero, size: size))
        expect(!inView.isEmpty, "the scratch note in view: \(frame)")
        let asWhole = renderBitmap(editor, size: size)
        editor.transact { $0.update(scratch, as: StickyNote.self) { $0.props.text = MentionText([.mention(row, label: "createRefund")]) } }
        let asRow = renderBitmap(editor, size: size)
        expectEqual(changedPixels(asWhole, asRow, in: inView), 0, "one look, whichever form")
        editor.transact { $0.delete([scratch]) }
        editor.undoHistory.seal()

        // Put back by its chip, dragged onto the API's rows.
        editor.selectedShapeIDs = []
        let rect = try w.rowRect(0, of: alone)
        let chip = CGPoint(x: rect.minX + 14 + 16, y: rect.midY)
        let into = try w.rowRect(1, of: orders.id)
        w.mouseDrag(from: chip, to: CGPoint(x: into.midX, y: into.maxY - 2))
        expectEqual(editor.undoHistory.undoName, "Move Endpoint")
        expect(ownEndpoint(editor) == nil, "the endpoint is its row again")
        let back = PartAddress(orders.id, part: try require(api(editor, "orders API")?.props.endpoints.first { $0.endpoint?.path == "/orders/{id}/refunds" }?.id))
        expectEqual(targets(editor, note), [back], "the picker's mention follows the row back")
        expectEqual(targets(editor, far), [back], "draw's, on another board, too")
        expectEqual(targets(editor, kept), [back], "and the shape's as a whole: the row it was")
        looksAsTheRow("put back")
        let references = try require(editor.service(ReferenceState.self))
        expect(editor.showBoard(storefront))
        w.window.settle()
        let wholeTarget = editor.document[wholePill]?.typed(as: Reference.self)?.props.target
        expectEqual(wholeTarget.map { PartAddress($0.id, part: $0.row) }, back, "a pill for the endpoint stands for its row in the API")
        expectEqual(wholeTarget?.label, "createRefund", "its stored name kept")
        expectEqual(editor.document[rowPill]?.typed(as: Reference.self)?.props.target.map { PartAddress($0.id, part: $0.row) }, back)
        expectEqual(references.state(of: wholePill)?.standsForNothing, false, "live, not dashed")
        expect(editor.showBoard(.root))

        // Undo and Redo give and take it, one step.
        (w.window as! BoardWindow).undo(nil)
        expectEqual(targets(editor, note), [row])
        expectEqual(targets(editor, far), [row])
        expectEqual(targets(editor, kept), [PartAddress(alone)], "the shape as a whole again")
        expectEqual(editor.file.record(wholePill)?.typed(as: Reference.self)?.props.target, ReferenceTarget(id: alone, label: "createRefund"))
        looksAsTheRow("undone")
        (w.window as! BoardWindow).redo(nil)
        expectEqual(targets(editor, kept), [back])
        expectEqual(targets(editor, far), [back])

        // Taken out again: every mention, the one that was the shape's too, is of its row there.
        expect(editor.moveRows([try require(back.part)], of: orders.id, to: .beside([orders.id])) != nil)
        let again = PartAddress(try require(ownEndpoint(editor)).id, part: back.part)
        for id in [note, far, kept] { expectEqual(targets(editor, id), [again], "one address: the row") }
        looksAsTheRow("taken out again")

        // Measured from its words alone, as a note's height is, each pill as wide as it is drawn.
        let style = MentionTextStyle(font: .systemFont(ofSize: 15), color: .black, lineHeight: 19)
        for id in [note, far] {
            let words = try require((editor.document[id] ?? editor.file.record(id))?.typed(as: StickyNote.self)?.props.text)
            let drawn = style.attributedString(words) { mentions.resolve($0) }.size().width
            expectEqual(style.measuredString(words, width: nil).size().width, drawn, "\(id)")
        }
    },
    test("a taken-out endpoint cut by its row and pasted into its API is a move: a mention of it as a whole, here and on another board, names the row it went to; Undo of the paste, then of the cut") {
        let w = try EmptyBoardWindow()
        defer { w.board.close() }
        try w.turnKitOn()
        try w.draw(scene)
        let editor = w.editor
        let orders = try require(api(editor, "orders API"))
        let refunds = orders.props.endpoints[2].id
        expect(editor.moveRows([refunds], of: orders.id, to: .beside([orders.id])) != nil)
        let alone = try require(ownEndpoint(editor)).id
        _ = try drawnInProcess(#"sticky-note "here" below "orders API" (gap: 300) text: "@[POST /orders/{id}/refunds](shape:\#(alone.rawValue.uuidString))""#, on: editor)
        _ = try drawnInProcess(#"sticky-note "there" in "storefront" text: "@[POST /orders/{id}/refunds](shape:\#(alone.rawValue.uuidString))""#, on: editor)
        let storefront = BoardID(owner: try require(titled(editor, "storefront", on: .root)).id)
        let here = try require(titled(editor, "here", on: .root)).id, there = try require(titled(editor, "there", on: storefront)).id
        editor.undoHistory.seal()
        editor.selectedShapeIDs = [alone]
        editor.selectItems([AnyHashable(refunds)], of: alone)
        expect(editor.cutRows([refunds], of: alone))
        expectEqual(editor.document[alone], nil, "cut, it goes")
        expectEqual(editor.mentions?.resolve(PartAddress(alone)).isLive, false, "its mentions dashed while it's on the pasteboard")
        editor.selectedShapeIDs = [orders.id]
        expect(editor.pasteRows(try require(editor.pasteboardRows), to: .into(orders.id, before: nil)) != nil)
        let back = PartAddress(orders.id, part: refunds)
        expectEqual(targets(editor, here), [back])
        expectEqual(targets(editor, there), [back], "on another board too")
        expectEqual(editor.mentions?.resolve(back).appearance?.label, "POST /orders/{id}/refunds")
        editor.undo()
        expectEqual(targets(editor, here), [PartAddress(alone)], "Undo of the paste: the shape again, still cut")
        editor.undo()
        expect(editor.document[alone] != nil, "Undo of the cut: the endpoint of its own")
        expectEqual(editor.mentions?.resolve(PartAddress(alone)).appearance?.label, "POST /orders/{id}/refunds")
    },
])
