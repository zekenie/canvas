import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Connections
import CoreGraphics
import Frames
import LanguageModels
import Selection
import ShippedTesting
import StickyNotes
import Subboards
import TestKit

// Connect (⌘L) and ⇧↩ on the shipped kinds: two selected shapes joined by the arrow a port's drag
// would draw, from the keyboard, and Connect in a right-click on two shapes.

@MainActor private func record(_ shape: some ShapeProps) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(shape)) }

/// The shipped plugins on a board of `shapes`, their clipboard on a pasteboard of the test's own.
@MainActor private func shipped(_ shapes: [AnyShapeRecord]) -> EditorHarness {
    let pasteboard = NSPasteboard.withUniqueName()
    return EditorHarness { ShippedPlugins.makeEditor(document: CanvasDocument(shapes: shapes), scheduler: $0, pasteboard: pasteboard, model: ScriptedLanguageModel()) }
}

/// ⌘L on the canvas: whether a shortcut took it.
@MainActor @discardableResult private func pressConnect(_ h: EditorHarness) -> Bool {
    h.hold(.command)
    defer { h.hold([]) }
    return h.key("l")
}

@MainActor private func arrows(_ h: EditorHarness) -> [AnyShapeRecord] {
    h.editor.document.shapes.filter { $0.kind == Arrow.kind }
}

@MainActor let connectShippedTests = Suite("Connect, shipped", [
    test("⌘L joins two notes with an arrow on the note link, from the one selected first, one step, Connect; a second between them is bent apart") {
        let a = record(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let b = record(StickyNote(frame: CGRect(x: 500, y: 0, width: 200, height: 200)))
        let h = shipped([a, b])
        h.editor.selectedShapeIDs = [b.id, a.id]
        expect(pressConnect(h))
        let arrow = try require(arrows(h).first)
        expectEqual(endsList(h.editor.registry.connectionEnds(of: arrow)), [b.id, a.id])
        expectEqual(arrow[ChannelProperty.self], NoteLink.id)
        expectEqual(h.editor.undoHistory.undoName, "Connect")
        expectEqual(h.editor.selectedShapeIDs, [b.id, a.id])
        expect(pressConnect(h))
        expectEqual(arrows(h).count, 2)
        let bends = arrows(h).compactMap { $0.typed(as: Arrow.self)?.props.bend }
        expect(Set(bends).count == 2, "the second bent apart from the first: \(bends)")
        h.editor.undo()
        h.editor.undo()
        expect(arrows(h).isEmpty)
    },
    test("⌘L from a note to a subboard draws on the note link; to a frame, which takes no note link, nothing, and both shake") {
        let note = record(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let board = record(Subboard(frame: CGRect(x: 500, y: 0, width: 240, height: 160)))
        let frame = record(Frame(frame: CGRect(x: 0, y: 500, width: 300, height: 200)))
        let h = shipped([note, board, frame])
        h.editor.selectedShapeIDs = [note.id, board.id]
        expect(pressConnect(h))
        expectEqual(try require(arrows(h).first)[ChannelProperty.self], NoteLink.id)
        h.editor.selectedShapeIDs = [note.id, frame.id]
        expect(pressConnect(h))
        expectEqual(arrows(h).count, 1, "nothing to the frame")
        expect(h.editor.service(RefusalShake.self)?.isShaking == true)
        expectEqual(h.editor.undoHistory.undoName, "Connect", "no step left by the refusal")
    },
    test("⌘L joins two frames on the frame link, and a subboard to a frame; a frame and the frame it holds, nothing, and both shake") {
        let outer = record(Frame(frame: CGRect(x: 0, y: 0, width: 400, height: 300)))
        let inner = record(Frame(frame: CGRect(x: 40, y: 40, width: 200, height: 150)))
        let other = record(Frame(frame: CGRect(x: 600, y: 0, width: 300, height: 200)))
        let board = record(Subboard(frame: CGRect(x: 600, y: 400, width: 240, height: 160)))
        let h = shipped([outer, inner, other, board])
        h.editor.put([inner.id], in: outer.id)
        h.editor.selectedShapeIDs = [outer.id, other.id]
        expect(pressConnect(h))
        expectEqual(arrows(h).map { $0[ChannelProperty.self] }, [FrameLink.id])
        h.editor.selectedShapeIDs = [board.id, other.id]
        expect(pressConnect(h))
        expectEqual(arrows(h).map { $0[ChannelProperty.self] }, [FrameLink.id, FrameLink.id], "a subboard to a frame, on the frame's link")
        h.editor.selectedShapeIDs = [outer.id, inner.id]
        expect(pressConnect(h))
        expectEqual(arrows(h).count, 2, "nothing between a frame and the frame it holds")
        expect(h.editor.service(RefusalShake.self)?.isShaking == true)
        expectEqual(h.editor.undoHistory.undoName, "Connect", "no step left by the refusal")
    },
    test("a right-click on two notes has Connect with its key; on one it has Connect To…, the picker's, with the same key") {
        let a = record(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200)))
        let b = record(StickyNote(frame: CGRect(x: 500, y: 0, width: 200, height: 200)))
        let h = shipped([a, b])
        h.editor.selectedShapeIDs = [a.id, b.id]
        let menu = try require(h.secondaryClick(at: CGPoint(x: 100, y: 100)))
        let item = try require(menu.item(withTitle: "Connect"))
        expectEqual(KeyboardShortcutSection.key(of: item), "⌘L")
        menu.performActionForItem(at: menu.index(of: item))
        expectEqual(arrows(h).count, 1)
        h.editor.selectedShapeIDs = []
        let one = try require(h.secondaryClick(at: CGPoint(x: 600, y: 100)))
        expect(one.item(withTitle: "Connect") == nil, "\(one.outline)")
        expectEqual(KeyboardShortcutSection.key(of: try require(one.item(withTitle: "Connect To…"), "\(one.outline)")), "⌘L")
    },
])

/// A connection's ends, as a list, so they compare.
private func endsList(_ ends: (from: ShapeID, to: ShapeID)?) -> [ShapeID]? { ends.map { [$0.from, $0.to] } }
