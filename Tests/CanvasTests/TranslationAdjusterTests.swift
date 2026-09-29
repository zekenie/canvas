import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import TestKit

// The translation adjuster (`registrar.translationAdjuster`): what Snapping claims, here a fixture
// that puts x on a grid of 10 and leaves y alone, unless ⌥ is held. The core has no Selection here,
// so tests start drags themselves.

/// What the fixture adjuster heard.
@MainActor
final class AdjusterLog {
    var begun: [TranslationStart] = []
    var asked: [(delta: CGPoint, modifiers: Modifiers, axis: TranslationAxis?)] = []
    var draws = 0
}

@MainActor
final class GridAdjuster: TranslationAdjuster {
    let log: AdjusterLog
    init(log: AdjusterLog) { self.log = log }

    /// Across the axis a drag keeps to, it says 7, which the drag ignores.
    func adjust(_ delta: CGPoint, along axis: TranslationAxis?, for pointer: Pointer, in editor: CanvasEditor) -> CGPoint {
        log.asked.append((delta, pointer.modifiers, axis))
        let gridded = pointer.modifiers.contains(.option) ? delta : CGPoint(x: (delta.x / 10).rounded() * 10, y: delta.y)
        switch axis {
        case .x?: return CGPoint(x: gridded.x, y: 7)
        case .y?: return CGPoint(x: 7, y: gridded.y)
        case nil: return gridded
        }
    }

    /// A black square at the world's origin.
    func draw(in context: OverlayContext) {
        log.draws += 1
        context.cg.setFillColor(NSColor.black.cgColor)
        context.cg.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    }
}

@MainActor func gridPlugin(_ log: AdjusterLog) -> Contributor {
    Contributor(id: "grid") { r in
        r.translationAdjuster { _, start in
            log.begun.append(start)
            return GridAdjuster(log: log)
        }
    }
}

@MainActor let translationAdjusterTests = Suite("Translation adjuster", [
    test("on an axis it changes, each box moves by exactly what it says from where it began; on one it leaves alone, as the pointer says") {
        let log = AdjusterLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), gridPlugin(log)])
        let a = h.add(Box(CGRect(x: 0.3, y: 0.7, width: 10, height: 10)))
        let b = h.add(Box(CGRect(x: 100.1, y: 50.9, width: 10, height: 10)))
        h.move(to: CGPoint(x: 5.1, y: 5.3))
        h.editor.session = TranslatingSession(ids: [a, b], from: CGPoint(x: 5.1, y: 5.3), in: h.editor)
        h.drag(to: CGPoint(x: 17.3, y: 9.9))
        expectEqual(log.asked.map(\.delta), [CGPoint(x: 17.3, y: 9.9) - CGPoint(x: 5.1, y: 5.3)])
        // x by 10, from where each began; y as without an adjuster: the pointer less where it grabbed.
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 0.3 + 10, y: 9.9 - (5.3 - 0.7)))
        expectEqual(h.editor.document[b]?.box?.origin, CGPoint(x: 100.1 + 10, y: 9.9 - (5.3 - 50.9)))
        h.escape()
        expectEqual(h.editor.document[a]?.box?.origin, CGPoint(x: 0.3, y: 0.7))
    },
    test("held keys changing mid-drag ask it again where the pointer is, with them") {
        let log = AdjusterLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), gridPlugin(log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.move(to: CGPoint(x: 5, y: 5))
        h.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 5, y: 5), in: h.editor)
        h.drag(to: CGPoint(x: 18, y: 9))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 10, y: 4))
        h.hold(.option)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 13, y: 4))
        expectEqual(log.asked.last?.delta, CGPoint(x: 13, y: 4))
        expectEqual(log.asked.last?.modifiers, .option)
        h.editor.session = nil
        let asked = log.asked.count
        h.hold([])
        expectEqual(log.asked.count, asked, "not once the drag is over")
    },
    test("⇧ keeps a drag to the axis the pointer has come further along: the adjuster is told which, and what it says across it is ignored") {
        let log = AdjusterLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), gridPlugin(log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.move(to: CGPoint(x: 5, y: 5))
        h.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 5, y: 5), in: h.editor)
        h.hold(.shift)
        h.drag(to: CGPoint(x: 18, y: 30))
        expectEqual(log.asked.last?.delta, CGPoint(x: 0, y: 25))
        expectEqual(log.asked.last?.axis, .y)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 0, y: 25), "up and down only, where it began across")
        h.drag(to: CGPoint(x: 40, y: 30))
        expectEqual(log.asked.last?.axis, .x)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 40, y: 0), "side to side, on the grid, not the 7 it said across")
        h.hold([])
        h.wait(150)
        expectEqual(log.asked.last?.axis, nil)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 40, y: 25), "⇧ let go: both ways again, where the pointer is")
    },
    test("⇧ keeps a drag with no adjuster to one axis too, pressed or let go mid-drag at once") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let box = h.add(Box(CGRect(x: 1, y: 2, width: 10, height: 10)))
        h.move(to: CGPoint(x: 5, y: 5))
        h.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 5, y: 5), in: h.editor)
        h.drag(to: CGPoint(x: 18, y: 9))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 14, y: 6))
        h.hold(.shift)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 14, y: 2), "at once, without a move")
        h.hold([])
        h.wait(150)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 14, y: 6))
        h.escape()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 1, y: 2))
    },
    test("it's made as the drag begins, given what moves, read-only shapes left out, and where the press was; a drag that moves nothing makes none") {
        let log = AdjusterLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), FreezingPlugin(), gridPlugin(log)])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let frozen = h.add(Box(CGRect(x: 50, y: 0, width: 10, height: 10)))
        h.editor.freeze([frozen])
        h.editor.session = TranslatingSession(ids: [frozen, box], from: CGPoint(x: 5, y: 5), in: h.editor)
        expectEqual(log.begun.map(\.ids), [[box]])
        expectEqual(log.begun.map(\.origin), [CGPoint(x: 5, y: 5)])
        h.editor.session = TranslatingSession(ids: [frozen], from: CGPoint(x: 55, y: 5), in: h.editor)
        expectEqual(log.begun.count, 1)
        h.drag(to: CGPoint(x: 80, y: 5))
        expectEqual(log.asked.count, 0)
    },
    test("what it draws is drawn with the session, over the shapes, and not once the session is over") {
        let log = AdjusterLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), gridPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 10, height: 10)))
        h.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 105, y: 105), in: h.editor)
        let size = CGSize(width: 200, height: 200)
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 10, y: 10)), [0, 0, 0, 255])
        expectEqual(log.draws, 1)
        h.editor.session = nil
        expect(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 10, y: 10)) != [0, 0, 0, 255])
        expectEqual(log.draws, 1)
    },
    test("an adjuster that declines leaves the drag following the pointer; two plugins can't both claim it") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "none") { $0.translationAdjuster { _, _ in nil } }])
        let box = h.add(Box(CGRect(x: 0.3, y: 0.7, width: 10, height: 10)))
        h.move(to: CGPoint(x: 5.1, y: 5.3))
        h.editor.session = TranslatingSession(ids: [box], from: CGPoint(x: 5.1, y: 5.3), in: h.editor)
        h.drag(to: CGPoint(x: 17.3, y: 9.9))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 17.3, y: 9.9) - (CGPoint(x: 5.1, y: 5.3) - CGPoint(x: 0.3, y: 0.7)))
        expectThrows(RegistryError.conflict(point: "TranslationAdjusters", key: "the translation adjuster", plugins: ["x", "y"])) {
            _ = try Registry(plugins: [Contributor(id: "x") { $0.translationAdjuster { _, _ in nil } },
                                       Contributor(id: "y") { $0.translationAdjuster { _, _ in nil } }])
        }
        let report = try Registry(plugins: [FixturesPlugin(), gridPlugin(AdjusterLog())]).report
        expect(report.contains("grid          translation adjuster"), report)
    },
])
