import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import CoreGraphics
import Geometry
import Publishing
import References
import TestKit
import Titles

// The pill says the board its note is on, in gray after the note's name, when that isn't the pill's
// board: kept with the condition the pill draws, so a frame of a thousand pills looks up no board.

/// The place of a note on the pocket "Clients"'s board, seen from the root.
private let clients = PlaceStep(name: "Clients", opensBoard: true)
/// A place long enough that a pill's width is its line's, not its name's.
private let clientsAccounts = [clients, PlaceStep(name: "Accounts receivable")]

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
        expectEqual(state.drawnPlace(of: farPill)?.text, "Clients")
        expectEqual(state.drawnPlace(of: nearPill)?.text, nil, "the same board: as it always looked")
        expectEqual(state.drawnPlace(of: missing)?.text, nil, "a note that isn't there has no board")
    },
    test("a board's rename is said at the next draw; a note made private still says its board") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let (far, pocket) = try boxInPocket(h, titled: "Acme")
        let pill = h.addReference(to: far, label: "Acme")
        // Wide enough that the eye, once it trails, leaves the line its room.
        h.editor.transact { $0.update(pill, as: Reference.self) { $0.props.frame.size.width = 220 } }
        _ = render(h.editor)
        let state = try require(h.editor.references)
        h.editor.transact { $0.update(pocket) { $0[TitleProperty.self] = "Accounts" } }
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: pill)?.text, "Accounts")
        h.editor.transact(on: BoardID(owner: pocket)) { $0.update(far) { $0[PublicProperty.self] = nil } }
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: pill)?.text, "Accounts", "dashed, and still says where")
    },
    test("it is drawn over the name: ink in its line for a note elsewhere and the name below it; for a note on the pill's board the name alone, centered") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let (far, _) = try boxInPocket(h, titled: "Acme")
        let near = h.addBox("Acme")
        // Both as a pick from the list of another board would have left them: as wide as the name and the board.
        @MainActor func pill(_ target: ShapeID, at origin: CGPoint, place: [PlaceStep]) -> ShapeID {
            var props = Reference(frame: CGRect(origin: origin, size: Reference.defaultSize))
            ReferenceEdits.pick(&props, ReferenceTarget(id: target, label: "Acme"), place: place)
            return h.add(props)
        }
        let farPill = pill(far, at: CGPoint(x: 100, y: 300), place: clientsAccounts)
        let nearPill = pill(near, at: CGPoint(x: 100, y: 400), place: [])
        let canvas = render(try referenceHarness().editor)
        @MainActor func rows(_ id: ShapeID, _ drawn: NSBitmapImageRep, from top: CGFloat, to bottom: CGFloat) throws -> Int {
            let frame = try require(h.editor.document[id]?.box)
            var count = 0
            for y in Int(frame.minY + top)..<Int(frame.minY + bottom) {
                for x in Int(frame.minX + 32)..<Int(frame.minX + 70) where pixel(drawn, at: CGPoint(x: x, y: y)).contains(where: { $0 < 200 }) { count += 1 }
            }
            return count
        }
        let drawn = render(h.editor)
        _ = canvas
        expect(try rows(farPill, drawn, from: 7, to: 18) > 20, "the place over the name: Clients in its line")
        expect(try rows(farPill, drawn, from: 21, to: 34) > 20, "and the name under it")
        expectEqual(try rows(nearPill, drawn, from: 6, to: 14), 0, "nothing over the name of a note on the pill's board")
        expect(try rows(nearPill, drawn, from: 14, to: 28) > 20, "its name centered")
        // From 60% down to the skeleton: the name alone, centered.
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        let near50 = render(h.editor)
        let farFrame = try require(h.editor.document[farPill]?.box)
        let pillBox = CGRect(x: farFrame.minX * 0.5, y: farFrame.minY * 0.5, width: farFrame.width * 0.5, height: farFrame.height * 0.5)
        expect(changedPixels(canvas, near50, in: pillBox) > 20, "still drawn in full at 50%")
        // At 50% the name sits at the pill's middle, as a pill with no place has it.
        var topInk = 0, middleInk = 0
        for y in Int(pillBox.minY)..<Int(pillBox.maxY) {
            for x in Int(pillBox.minX + 16)..<Int(pillBox.maxX - 8) where pixel(near50, at: CGPoint(x: x, y: y)).contains(where: { $0 < 200 }) {
                if y < Int(pillBox.minY + pillBox.height * 0.25) { topInk += 1 } else { middleInk += 1 }
            }
        }
        expectEqual(topInk, 0, "no line over it at 50%")
        expect(middleInk > 6, "the name")
    },
    test("editing a far pill and putting its text back, and setting a prop of it by a script, keep the room for its board") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let pocket = h.add(Pocket(CGRect(x: 600, y: 100, width: 100, height: 100)))
        h.editor.transact { $0.update(pocket) { $0[TitleProperty.self] = "Clients" } }
        expect(h.enter(pocket))
        let note = h.addBox("Acme")
        expect(h.editor.showBoard(.root))
        var props = Reference(frame: CGRect(origin: CGPoint(x: 100, y: 300), size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: note, label: "Acme"), place: clientsAccounts)
        let id = h.add(props)
        let width = try require(h.editor.document[id]?.box).width
        expect(width > ReferenceEdits.width(of: props), "room for the place, wider than the name")
        let field = try h.editReference(id)
        defer { field.close() }
        field.type("x")
        field.press("\u{7f}", code: 51)
        field.type("Acme")
        expectEqual(field.textView.string, "Acme", "the text put back")
        expectEqual(try require(h.editor.document[id]?.box).width, width, "as wide as it was opened")
        expectEqual(h.editor.registry.derived(try require(h.editor.document[id])).box?.width, width, "a prop set by a script keeps it")
    },
    test("what the pill measures: 46 and the wider of the name (and its glyph's room) and the place's line; never over 280") {
        var alone = Reference(frame: CGRect(origin: .zero, size: Reference.defaultSize))
        ReferenceEdits.pick(&alone, ReferenceTarget(id: ShapeID(), label: "Acme"))
        var near = alone
        ReferenceEdits.pick(&near, ReferenceTarget(id: ShapeID(), label: "Acme"), place: [clients])
        expectEqual(near.frame.width, alone.frame.width, "a place shorter than the name leaves the pill as wide as its name")
        var far = alone
        ReferenceEdits.pick(&far, ReferenceTarget(id: ShapeID(), label: "Acme"), place: clientsAccounts)
        expect(far.frame.width > alone.frame.width, "\(far.frame.width) over \(alone.frame.width)")
        let line = PlaceFold.line(for: clientsAccounts, room: 234) { text, isBoard in
            ceil(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: isBoard ? .semibold : .regular)]).size().width)
        }
        expectEqual(far.frame.width, ceil(46 + line.width), "the line folded at 234, and the 46 round it")
        expect(far.frame.width <= 280, "never over the most")
        var capped = alone
        ReferenceEdits.pick(&capped, ReferenceTarget(id: ShapeID(), label: String(repeating: "w", count: 60)), place: [PlaceStep(name: String(repeating: "b", count: 40))])
        expectEqual(capped.frame.width, 280)
        expectEqual(ReferenceEdits.width(of: alone, place: []), alone.frame.width)
    },
])
