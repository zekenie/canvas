@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// A plugin that follows the selection (`registrar.selectionChanged`): told each time it changes, after it has, with the
// shapes it left and the ones it holds now.

@MainActor private final class Heard {
    var calls: [(left: [ShapeID], now: [ShapeID])] = []
}

@MainActor let selectionObserverTests = Suite("Selection observers", [
    test("an observer is told each change of the selection, with what it left and what it holds now, and none when nothing changed") {
        let heard = Heard()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(),
                                            Contributor(id: "observer") { $0.selectionChanged { _, left, now in heard.calls.append((left, now)) } }])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10))), b = h.add(Box(CGRect(x: 20, y: 0, width: 10, height: 10)))
        h.editor.selection = a
        h.editor.selection = a
        h.editor.selectedShapeIDs = [a, b]
        h.editor.selection = nil
        expectEqual(heard.calls.map(\.left), [[], [a], [a, b]])
        expectEqual(heard.calls.map(\.now), [[a], [a, b], []])
    },
    test("it is told when a deletion takes the selected shape away and when showing another board clears the selection") {
        let heard = Heard()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(),
                                            Contributor(id: "observer") { $0.selectionChanged { _, left, now in heard.calls.append((left, now)) } }])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = a
        h.editor.transact("Delete") { $0.delete([a]) }
        expectEqual(heard.calls.last?.now, [], "the commit dropped it")
        let pocket = h.add(Pocket(CGRect(x: 100, y: 100, width: 50, height: 50)))
        let b = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.selection = b
        expect(h.editor.showBoard(BoardID(owner: pocket)))
        expectEqual(heard.calls.last?.left, [b])
        expectEqual(heard.calls.last?.now, [])
    },
])
