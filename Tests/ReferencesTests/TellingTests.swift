import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Observation
import Publishing
import References
import Titles
import TestKit

// What an answer arriving tells: the canvas to draw again, and whoever observes the reference's
// status (the panel, the table of contents' rows).

/// Counts what the editor tells its view.
@MainActor private final class Redraws: CanvasEditorDelegate {
    var count = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { count += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
    func editorPopoverDidChange(_ editor: CanvasEditor) {}
    func editorBoardDidChange(_ editor: CanvasEditor) {}
}

@MainActor private final class Told { var fired = 0 }

@MainActor let tellingTests = Suite("What an answer arriving tells", [
    test("a landing draws the canvas again and tells what observes the reference's status, and not another's") {
        let h = try referenceHarness()
        h.addBox("Alpha", at: CGRect(x: 100, y: 100, width: 100, height: 60))
        let id = h.addReference(query: "box")
        let other = h.addReference(query: "tile", at: CGPoint(x: 400, y: 500))
        let state = try require(h.editor.references)
        h.answer()
        let redraws = Redraws()
        h.editor.delegate = redraws
        let told = Told()
        withObservationTracking { _ = state.status(of: id) } onChange: { MainActor.assumeIsolated { told.fired += 1 } }
        let untouched = Told()
        withObservationTracking { _ = state.status(of: other) } onChange: { MainActor.assumeIsolated { untouched.fired += 1 } }
        h.addBox("Beta", at: CGRect(x: 250, y: 100, width: 100, height: 60))
        let before = redraws.count
        h.answer(after: 250)
        expect(redraws.count > before, "the pill draws again once the answer lands")
        expectEqual(told.fired, 1, "the observer of the reference that changed")
        expectEqual(untouched.fired, 0, "not of another")
        h.editor.delegate = nil
    },
    test("a dynamic reference on a board that goes with its owner is let go of, and asked again with its board") {
        let h = try referenceHarness([PocketsPlugin(), pocketTitles])
        let alpha = h.addBox("Alpha", at: CGRect(x: 100, y: 100, width: 100, height: 60))
        var pocket = ShapeRecord(Pocket(CGRect(x: 800, y: 600, width: 100, height: 100)))
        pocket[TitleProperty.self] = "P"
        h.editor.transact { $0.insert(pocket) }
        expect(h.enter(pocket.id))
        let inside = h.addReference(query: "box", all: true)
        expect(h.editor.showBoard(.root))
        h.answer(after: 250)
        let state = try require(h.editor.references)
        expectEqual(h.standsFor(inside), [alpha])
        h.editor.transact("Delete") { $0.delete([pocket.id]) }
        h.answer(after: 250)
        expectEqual(state.dynamicReferences, [], "a reference on a board that's gone is none of the file's")
        h.editor.undo()
        h.answer(after: 250)
        expectEqual(state.dynamicReferences, [inside])
        expectEqual(h.standsFor(inside), [alpha], "healed with its board")
    },
])
