import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// What a shape shows is made once, and again only when a commit names the shape or
// `adornmentsDidChange` does: never by drawing, hovering, panning or zooming in full (zooming out
// to skeletons lets what's kept go, since they show none).

/// How many times each shape's caption label was made.
@MainActor final class Calls {
    var counts: [ShapeID: Int] = [:]
}

/// Every shape's caption, "200 wide", counting how often it's made.
@MainActor func countedCaptions(_ calls: Calls) -> Contributor {
    everyShape(Caption.self, id: "captions") { shape in
        calls.counts[shape.id, default: 0] += 1
        return AdornmentLabel("\(Int(shape.box?.width ?? 0)) wide")
    }
}

/// A service that reads the adornments of the shapes each commit changes as it hears of it: made
/// before Adornments' own (its plugin is earlier in the list), so it hears first.
@MainActor final class EarlyReader {
    var read: [String?] = []
}

extension EarlyReader: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        for id in changes.changed { read.append(editor.adornmentFrames(of: id).first?.label.text) }
    }
}

/// Counts the redraws the editor asks its view for.
final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

@MainActor let cacheTests = Suite("Making labels once", [
    test("two frames, a hover, a pan and a zoom make a shape's labels once in all") {
        let calls = Calls()
        // Pins nowhere, so a hover looks for one.
        let h = try adornedHarness([countedCaptions(calls), everyShape(Pin.self, id: "pins") { _ in nil }])
        let box = h.add(Box(boxFrame))
        _ = render(h)
        _ = render(h)
        h.move(to: CGPoint(x: 150, y: 150))
        h.move(to: flagCenter)
        h.editor.camera = Camera(origin: CGPoint(x: 30, y: 10), zoom: 1)
        _ = render(h)
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        _ = render(h)
        expectEqual(h.editor.adornmentFrames(of: box).first?.label.text, "200 wide")
        expectEqual(calls.counts[box], 1)
    },
    test("a commit that changes a shape makes its labels again, and one that changes another shape doesn't") {
        let calls = Calls()
        let h = try adornedHarness([countedCaptions(calls)])
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 100, y: 250, width: 100, height: 40)))
        _ = render(h)
        expectEqual(calls.counts, [a: 1, b: 1])
        h.editor.transact { $0.update(a) { $0.box = CGRect(x: 100, y: 100, width: 150, height: 120) } }
        _ = render(h)
        expectEqual(calls.counts, [a: 2, b: 1])
        expectEqual(h.editor.adornmentFrames(of: a).first?.label.text, "150 wide")
        h.editor.transact { $0.update(b) { $0.box = CGRect(x: 100, y: 250, width: 120, height: 40) } }
        _ = render(h)
        expectEqual(calls.counts, [a: 2, b: 2])
    },
    test("`adornmentsDidChange` makes a shape's labels again and redraws; a shape that's gone is forgotten") {
        let calls = Calls()
        let h = try adornedHarness([countedCaptions(calls)])
        let display = DisplayCounter()
        h.editor.delegate = display
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 100, y: 250, width: 100, height: 40)))
        _ = render(h)
        let redraws = display.redraws
        h.editor.adornmentsDidChange(for: [a])
        expect(display.redraws > redraws, "redrawn")
        _ = render(h)
        expectEqual(calls.counts, [a: 2, b: 1])
        expectEqual(h.editor.adornmentsKept, 2)
        h.editor.transact { $0.delete([b]) }
        expectEqual(h.editor.adornmentsKept, 1)
    },
    test("a service that hears of a commit before Adornments reads the shape's new labels, and nothing kept is lost by it") {
        let calls = Calls()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                            Contributor(id: "early") { $0.service { _ in EarlyReader() } },
                                            countedCaptions(calls), AdornmentsPlugin()])
        let a = h.add(Box(boxFrame)), b = h.add(Box(CGRect(x: 100, y: 250, width: 100, height: 40)))
        _ = render(h)
        h.editor.transact { $0.update(a) { $0.box = CGRect(x: 100, y: 100, width: 150, height: 120) } }
        expectEqual(try require(h.editor.service(EarlyReader.self)).read, ["150 wide"])
        _ = render(h)
        expectEqual(h.editor.adornmentFrames(of: a).first?.label.text, "150 wide")
        expectEqual(calls.counts, [a: 3, b: 1], "once more for the early read, which isn't kept, and once for the frame")
    },
    test("a frame makes labels only for the shapes whose adornments may be in view") {
        let calls = Calls()
        let h = try adornedHarness([countedCaptions(calls)])
        var frames: [ShapeID: CGRect] = [:]
        h.editor.transact { transaction in
            for row in 0..<25 {
                for column in 0..<40 {
                    let shape = ShapeRecord(Box(CGRect(x: column * 100 - 500, y: row * 100 - 500, width: 80, height: 60)))
                    frames[shape.id] = shape.frame
                    transaction.insert(shape)
                }
            }
        }
        _ = render(h)
        let reach = AdornmentLayout.area(showing: wholeView, scale: 1)
        let expected = Set(frames.filter { $0.value.touches(reach) }.keys)
        expectEqual(Set(calls.counts.keys), expected)
        expect(expected.count < 40, "about 20 of 1,000: \(expected.count)")
    },
])
