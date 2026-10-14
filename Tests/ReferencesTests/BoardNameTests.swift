import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Publishing
import References
import TestKit
import Titles

// The pill says the board its note is on, in gray after the note's name, when that isn't the pill's
// board: kept with the condition the pill draws, so a frame of a thousand pills looks up no board.

/// A box titled `title` on a board of its own, which a pocket on the root owns; the root shown again.
@MainActor private func boxInPocket(_ h: EditorHarness, titled title: String) throws -> (box: ShapeID, pocket: ShapeID) {
    let pocket = h.add(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
    h.editor.transact { $0.update(pocket) { $0[TitleProperty.self] = "Clients" } }
    expect(h.enter(pocket))
    let box = h.addBox(title)
    expect(h.editor.showBoard(.root))
    return (box, pocket)
}

@MainActor let boardNameTests = Suite("A pill says its note's board", [
    test("a note on another board: its board's name is kept with the pill drawn; a note on the pill's own board: none") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let (far, _) = try boxInPocket(h, titled: "Acme")
        let near = h.addBox("Ledger")
        let farPill = h.addReference(to: far, label: "Acme")
        let nearPill = h.addReference(to: near, label: "Ledger", at: CGPoint(x: 400, y: 400))
        let missing = h.addReference(to: ShapeID(), label: "Gone", at: CGPoint(x: 400, y: 500))
        _ = render(h.editor)
        let state = try require(h.editor.references)
        expectEqual(state.drawnBoard(of: farPill), "Clients")
        expectEqual(state.drawnBoard(of: nearPill), nil, "the same board: as it always looked")
        expectEqual(state.drawnBoard(of: missing), nil, "a note that isn't there has no board")
    },
    test("a board's rename is said at the next draw; a note made private still says its board") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let (far, pocket) = try boxInPocket(h, titled: "Acme")
        let pill = h.addReference(to: far, label: "Acme")
        _ = render(h.editor)
        let state = try require(h.editor.references)
        h.editor.transact { $0.update(pocket) { $0[TitleProperty.self] = "Accounts" } }
        _ = render(h.editor)
        expectEqual(state.drawnBoard(of: pill), "Accounts")
        h.editor.transact(on: BoardID(owner: pocket)) { $0.update(far) { $0[PublicProperty.self] = nil } }
        _ = render(h.editor)
        expectEqual(state.drawnBoard(of: pill), "Accounts", "dashed, and still says where")
    },
    test("it is drawn in the room after the name: ink there for a note elsewhere, none for a note on the pill's board") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let (far, _) = try boxInPocket(h, titled: "Acme")
        let near = h.addBox("Acme")
        // Both as a pick from the list of another board would have left them: as wide as the name and the board.
        @MainActor func pill(_ target: ShapeID, at origin: CGPoint) -> ShapeID {
            var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
            ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: "Acme"), board: "Clients")
            return h.add(props)
        }
        let farPill = pill(far, at: CGPoint(x: 100, y: 300))
        let nearPill = pill(near, at: CGPoint(x: 100, y: 400))
        let drawn = render(h.editor)
        @MainActor func room(_ id: ShapeID) throws -> CGRect {
            let frame = try require(h.editor.document[id]?.box)
            // The end of the board's name: the trailing pad and the glyph room before the edge.
            return CGRect(x: frame.maxX - 14 - 17 - 28, y: frame.midY - 5, width: 26, height: 10)
        }
        @MainActor func ink(_ rect: CGRect) -> Int {
            stride(from: rect.minY, to: rect.maxY, by: 1).reduce(0) { count, y in
                count + stride(from: rect.minX, to: rect.maxX, by: 1).count { x in pixel(drawn, at: CGPoint(x: x, y: y)).contains { $0 < 235 } }
            }
        }
        expect(ink(try room(farPill)) > 0, "the board's name, gray")
        expectEqual(ink(try room(nearPill)), 0, "nothing after the name")
    },
    test("editing a far pill and putting its text back, and setting a prop of it by a script, keep the room for its board") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let pocket = h.add(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
        h.editor.transact { $0.update(pocket) { $0[TitleProperty.self] = "Clients" } }
        expect(h.enter(pocket))
        let note = h.addBox("Acme")
        expect(h.editor.showBoard(.root))
        var props = Reference(frame: CGRect(origin: CGPoint(x: 100, y: 300), size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: note, label: "Acme"), board: "Clients")
        let id = h.add(props)
        let width = try require(h.editor.document[id]?.box).width
        expect(width > ReferenceEdits.width(of: props), "room for the board after the name")
        let field = try h.editReference(id)
        defer { field.close() }
        field.type("x")
        field.press("\u{7f}", code: 51)
        field.type("Acme")
        expectEqual(field.textView.string, "Acme", "the text put back")
        expectEqual(try require(h.editor.document[id]?.box).width, width, "as wide as it was opened")
        expectEqual(h.editor.registry.derived(try require(h.editor.document[id])).box?.width, width, "a prop set by a script keeps it")
    },
    test("what the pill measures: the name alone as it was, and wider by the gap and the board's name when picked from another board") {
        var alone = Reference(frame: CGRect(origin: .zero, size: Reference.defaultSize))
        ReferenceEdits.pick(&alone, ReferenceTarget(id: ShapeID(), label: "Acme"))
        var far = alone
        ReferenceEdits.pick(&far, ReferenceTarget(id: ShapeID(), label: "Acme"), board: "Clients")
        expect(far.frame.width > alone.frame.width, "\(far.frame.width) over \(alone.frame.width)")
        expect(far.frame.width <= 280, "never over the most")
        var capped = alone
        ReferenceEdits.pick(&capped, ReferenceTarget(id: ShapeID(), label: String(repeating: "w", count: 60)), board: String(repeating: "b", count: 40))
        expectEqual(capped.frame.width, 280)
        expectEqual(ReferenceEdits.width(of: alone, board: nil), alone.frame.width)
    },
])
