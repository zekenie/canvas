import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Geometry
import Publishing
import References
import TestKit
import Titles

// The two-line pill: the place over the name, small and gray (a board's name semibold), the word "Deleted" or "Not available"
// in its stead for an original that is gone, the name alone centered when there is nothing to say or the zoom is under 60%;
// the whole place and the name on the pointer resting on a line that is folded or cut; and the whole place for VoiceOver.

/// A pocket (a card that owns a board) titled `title` on the board shown, entered; the board it owns.
@MainActor private func pocket(_ h: EditorHarness, titled title: String, at frame: CGRect = CGRect(x: 600, y: 100, width: 100, height: 100)) -> ShapeID {
    let id = h.add(Pocket(frame))
    h.editor.transact { $0.update(id) { $0[TitleProperty.self] = title } }
    return id
}

/// A box titled `title` three boards down, "Shop › Policies › Refunds", seen from the root: Policies is a pocket on Shop's board.
@MainActor private func deepBox(_ h: EditorHarness, titled title: String, boards: [String] = ["Shop", "Policies"]) throws -> ShapeID {
    for name in boards {
        let owner = pocket(h, titled: name)
        expect(h.enter(owner))
    }
    let box = h.addBox(title)
    expect(h.editor.showBoard(.root))
    return box
}

@MainActor private func harness() throws -> EditorHarness { try referenceHarness([PocketsPlugin(), pocketTitles]) }

/// Pixels in the pill's top band (its place line), and its lower band (its name), whose ink differs from the canvas.
@MainActor private func ink(of id: ShapeID, in h: EditorHarness, _ drawn: NSBitmapImageRep, rows: Range<Int>, columns: Range<Int> = 32..<110) throws -> Int {
    let frame = try require(h.editor.document[id]?.box)
    var count = 0
    for y in rows {
        for x in columns where x < Int(frame.width) - 14 {
            if pixel(drawn, at: CGPoint(x: frame.minX + CGFloat(x), y: frame.minY + CGFloat(y))).contains(where: { $0 < 200 }) { count += 1 }
        }
    }
    return count
}

@MainActor let placeLineTests = Suite("The place over the name", [
    test("a pill for a shape elsewhere has its place in a small line and its name under it; one in its own place has the name alone, centered") {
        let h = try harness()
        let far = try deepBox(h, titled: "Acme")
        let near = h.addBox("Acme")
        let farPill = h.addReference(to: far, label: "Acme"), nearPill = h.addReference(to: near, label: "Acme", at: CGPoint(x: 400, y: 400))
        h.editor.transact { editor in
            editor.update(farPill, as: Reference.self) { $0.props.frame.size.width = 200 }
        }
        let drawn = render(h.editor)
        expect(try ink(of: farPill, in: h, drawn, rows: 7..<18) > 25, "the place: Shop › Policies, over the name")
        expect(try ink(of: farPill, in: h, drawn, rows: 21..<35) > 20, "its name under it")
        expectEqual(try ink(of: nearPill, in: h, drawn, rows: 5..<13), 0, "no place: nothing over the name")
        expect(try ink(of: nearPill, in: h, drawn, rows: 13..<30) > 20, "the name centered")
        let state = try require(h.editor.references)
        expectEqual(state.drawnPlace(of: farPill)?.text, "Shop › Policies")
        expect(try ink(of: farPill, in: h, drawn, rows: 7..<18, columns: 32..<60) > 0, "a board's name semibold: Shop")
    },
    test("the zoom: both lines from 60% up; under it the name alone, centered; under the skeleton's, the block") {
        let h = try harness()
        let far = try deepBox(h, titled: "Acme")
        let pill = h.addReference(to: far, label: "Acme")
        h.editor.transact { $0.update(pill, as: Reference.self) { $0.props.frame.size.width = 200 } }
        let frame = try require(h.editor.document[pill]?.box)
        let canvas = render(try harness().editor)
        for (zoom, twoLines) in [(1.0, true), (0.6, true), (0.59, false), (0.4, false)] as [(CGFloat, Bool)] {
            h.editor.camera = Camera(origin: .zero, zoom: zoom)
            let drawn = render(h.editor)
            let scaled = CGRect(x: frame.minX * zoom, y: frame.minY * zoom, width: frame.width * zoom, height: frame.height * zoom)
            expect(changedPixels(canvas, drawn, in: scaled) > 10, "the pill is drawn in full at \(zoom)")
            // The top quarter of the pill, where the place line sits and the centered name does not.
            var top = 0
            for y in Int(scaled.minY + scaled.height * 0.15)..<Int(scaled.minY + scaled.height * 0.4) {
                for x in Int(scaled.minX + 34 * zoom)..<Int(scaled.maxX - 14 * zoom) where pixel(drawn, at: CGPoint(x: x, y: y)).contains(where: { $0 < 200 }) { top += 1 }
            }
            expectEqual(top > 0, twoLines, "zoom \(zoom): the place line over the name \(twoLines ? "is" : "isn't") drawn (\(top) pixels)")
        }
    },
    test("an original that is gone says so in the place line: Deleted, or Not available, over the name, in gray") {
        let h = try harness()
        let gone = h.addReference(to: ShapeID(), label: "Old roadmap")
        let hidden = ShapeRecord(Box(boxFrame))
        let elsewhere = ShapeID()
        let other = try referenceHarness(file: CanvasFile(root: CanvasDocument(), children: [elsewhere: CanvasDocument(shapes: [AnyShapeRecord(hidden)])]))
        let unavailable = other.addReference(to: hidden.id, label: "Out of sight")
        let words = h.addReference(words: "blocked work", at: CGPoint(x: 400, y: 400))
        for (harness, id, says) in [(h, gone, true), (other, unavailable, true), (h, words, false)] {
            let drawn = render(harness.editor)
            if says {
                expect(try ink(of: id, in: harness, drawn, rows: 7..<18) > 10, "the word over the name")
            } else {
                expectEqual(try ink(of: id, in: harness, drawn, rows: 5..<12), 0, "nothing over the name of words")
            }
        }
    },
    test("a pill that isn't public keeps its place line, dashed, italic, with the eye; a dynamic one says its first match's place, an All one's none") {
        let h = try harness()
        let far = try deepBox(h, titled: "Acme")
        let pill = h.addReference(to: far, label: "Acme")
        h.editor.transact { $0.update(pill, as: Reference.self) { $0.props.frame.size.width = 220 } }
        h.editor.transact(on: BoardID(owner: try require(h.editor.document.shapes.first { $0.kind == "pocket" }?.id))) { _ in }
        var drawn = render(h.editor)
        expect(try ink(of: pill, in: h, drawn, rows: 7..<18) > 25, "live: its place")
        let first = h.addReference(words: "acme", query: "\"Acme\"", at: CGPoint(x: 400, y: 400))
        let every = h.addReference(words: "acme", query: "\"Acme\"", all: true, at: CGPoint(x: 400, y: 500))
        h.editor.transact { editor in
            editor.update(first, as: Reference.self) { $0.props.frame.size.width = 260 }
            editor.update(every, as: Reference.self) { $0.props.frame.size.width = 260 }
        }
        let state = try require(h.editor.references)
        expectEqual(try ink(of: first, in: h, render(h.editor), rows: 5..<12), 0, "finding: no line")
        h.answer()
        drawn = render(h.editor)
        expect(try ink(of: first, in: h, drawn, rows: 7..<18, columns: 32..<130) > 25, "a first match: its place")
        expectEqual(try ink(of: every, in: h, drawn, rows: 5..<12), 0, "every match: no line")
        expectEqual(state.drawnPlace(of: first)?.text, "Shop › Policies")
        _ = far
    },
    test("what trails a direct pill sits on its name's line: a pill fitted to its place keeps it whole when it goes private") {
        let h = try harness()
        let far = try deepBox(h, titled: "Q", boards: ["Board", "Team"])
        var props = Reference(frame: CGRect(origin: CGPoint(x: 400, y: 400), size: Reference.defaultSize))
        ReferenceEdits.pick(&props, ReferenceTarget(id: far, label: "Q"), place: [PlaceStep(name: "Board", opensBoard: true), PlaceStep(name: "Team", opensBoard: true)])
        let pill = h.add(props)
        let state = try require(h.editor.references)
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: pill)?.text, "Board › Team", "live")
        h.editor.transact(on: try require(h.editor.file.board(containing: far))) { $0.update(far) { $0[PrivateProperty.self] = true } }
        _ = render(h.editor)
        expectEqual(state.drawnPlace(of: pill)?.text, "Board › Team", "not public: the eye beside the name, the place still whole")
    },
    test("the pointer resting on a line that is folded or cut says the whole place, then the name; a line that fits says nothing") {
        let h = try harness()
        let far = try deepBox(h, titled: "Acme", boards: ["Customer accounts and billing", "Refund policies for the European Union"])
        let pill = h.addReference(to: far, label: "Acme")
        let wide = h.addReference(to: try deepBox(h, titled: "Short", boards: ["Shop"]), label: "Short", at: CGPoint(x: 400, y: 500))
        h.editor.transact { $0.update(wide, as: Reference.self) { $0.props.frame.size.width = 220 } }
        _ = render(h.editor)
        let frame = try require(h.editor.document[pill]?.box)
        h.move(to: h.view(CGPoint(x: frame.minX + 60, y: frame.midY)))
        h.wait(600)
        let text = try require(h.editor.popover?.text)
        expectEqual(text.string, "Customer accounts and billing › Refund policies for the European Union\nAcme")
        let boards = NSFontManager.shared.traits(of: try require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont))
        expect(boards.contains(.boldFontMask), "a board's name is semibold")
        let fitting = try require(h.editor.document[wide]?.box)
        h.move(to: h.view(CGPoint(x: fitting.minX + 60, y: fitting.midY)))
        h.wait(600)
        expectEqual(h.editor.popover?.text.string, nil, "a place that fits is on the pill already")
        // Zoomed out the line isn't drawn, so the place is told whole.
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        h.move(to: h.view(CGPoint(x: fitting.minX + 60, y: fitting.midY)))
        h.wait(600)
        expectEqual(h.editor.popover?.text.string, "Shop\nShort")
    },
    test("VoiceOver hears the name, the kind and the whole place, never folded; a gone one Deleted; a query its words and what it found") {
        let h = try harness()
        let far = try deepBox(h, titled: "Acme", boards: ["Customer accounts and billing", "Refund policies for the European Union"])
        let pill = h.addReference(to: far, label: "Acme")
        expectEqual(h.editor.accessibleDescription(of: pill)?.label,
                    "Acme, Reference, in Customer accounts and billing › Refund policies for the European Union")
        let gone = h.addReference(to: ShapeID(), label: "Old roadmap", at: CGPoint(x: 400, y: 400))
        expectEqual(h.editor.accessibleDescription(of: gone)?.label, "Old roadmap, Reference, Deleted")
        let query = h.addReference(words: "the boxes", query: "box", all: true, at: CGPoint(x: 400, y: 500))
        h.answer()
        expectEqual(h.editor.accessibleDescription(of: query)?.label, "the boxes, Reference, 1 match")
    },
])
