@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TableOfContents
import TestKit
import Validation

/// What a rule reads that is neither the shape nor the shapes it looks up: a flag a service would
/// keep. Flipping it changes no shape, so nothing but `recheck` has the engine ask again.
@MainActor private final class Flag {
    var raised = false
    var asked: [ShapeID] = []
}

@MainActor private func flagRules(_ flag: Flag) -> Rules {
    Rules { r in
        r.validate(Box.self) { box, _ in
            flag.asked.append(box.id)
            return flag.raised ? [.error("raised")] : []
        }
    }
}

/// Counts what the editor tells its view.
private final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

@MainActor private func shown(_ editor: CanvasEditor, _ id: ShapeID) -> [String] {
    editor.validation?.result(for: id)?.issues.map(\.message) ?? []
}

@MainActor let recheckTests = Suite("Checking shapes again without a commit", [
    test("a rule's outside state changing is heard only through recheck, and the redraw is asked for") {
        let flag = Flag()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), flagRules(flag)])
        let display = DisplayCounter()
        h.editor.delegate = display
        let box = h.editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        expectEqual(shown(h.editor, box), [])
        flag.raised = true
        expectEqual(shown(h.editor, box), [], "nothing told the engine")
        let before = display.redraws
        h.editor.validation?.recheck([box])
        expectEqual(shown(h.editor, box), ["raised"])
        expect(display.redraws > before, "the ring is redrawn")
    },
    test("an unrelated shape's rule does not run again") {
        let flag = Flag()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), flagRules(flag)])
        let one = h.editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let other = h.editor.add(Box(CGRect(x: 100, y: 0, width: 40, height: 40)))
        _ = h.editor.validation?.results
        flag.asked = []
        flag.raised = true
        h.editor.validation?.recheck([one])
        _ = h.editor.validation?.results
        expectEqual(flag.asked, [one])
        expectEqual(shown(h.editor, other), [])
    },
    test("recheck of nothing, or of a shape that is gone, asks for nothing") {
        let flag = Flag()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), flagRules(flag)])
        let display = DisplayCounter()
        h.editor.delegate = display
        let box = h.editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        _ = h.editor.validation?.results
        flag.asked = []
        let before = display.redraws
        h.editor.validation?.recheck([])
        h.editor.validation?.recheck([ShapeID()])
        _ = h.editor.validation?.results
        expectEqual(flag.asked, [])
        expectEqual(display.redraws, before)
        expectEqual(shown(h.editor, box), [])
    },
    test("a shape on a board the engine keeps is checked again when that board is taken back") {
        let flag = Flag()
        let pocket = ShapeRecord(Pocket(CGRect(x: 0, y: 0, width: 200, height: 100)))
        let inner = ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]),
                              children: [pocket.id: CanvasDocument(shapes: [AnyShapeRecord(inner)])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), ValidationPlugin(), flagRules(flag)], file: file)
        _ = h.enter(pocket.id)
        expectEqual(shown(h.editor, inner.id), [])
        h.editor.showBoard(.root)
        flag.raised = true
        h.editor.validation?.recheck([inner.id])
        _ = h.enter(pocket.id)
        expectEqual(shown(h.editor, inner.id), ["raised"])
    },
    test("affected(by:) for the same revision includes the shapes rechecked") {
        let flag = Flag()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), flagRules(flag)])
        let box = h.editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        h.editor.validation?.recheck([box])
        expectEqual(h.editor.validation?.affected(by: ChangeSet(elsewhere: [])), [box])
    },
    test("the table of contents makes the row again, and a list without one takes the call") {
        let flag = Flag()
        let h = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), TableOfContentsPlugin(), ValidationContentsPlugin(), flagRules(flag)])
        let box = h.editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        let other = h.editor.add(Box(CGRect(x: 100, y: 0, width: 40, height: 40)))
        let contents = try require(h.editor.tableOfContents)
        _ = contents.entries
        let made = contents.rowsMade
        flag.raised = true
        h.editor.validation?.recheck([box])
        let marks = try require(contents.entries.first { $0.id == box }).marks
        expectEqual(marks.map(\.help), ["raised"], "the row says it")
        expectEqual(try require(contents.entries.first { $0.id == other }).marks, [])
        expectEqual(contents.rowsMade - made, 1, "only that row was made again")
        let bare = try EditorHarness(plugins: [FixturesPlugin(), ValidationPlugin(), flagRules(Flag())])
        let id = bare.editor.add(Box(CGRect(x: 0, y: 0, width: 40, height: 40)))
        bare.editor.validation?.recheck([id])
        expectEqual(shown(bare.editor, id), [])
    },
])
