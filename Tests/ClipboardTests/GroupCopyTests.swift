import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Grouping
import Keyboard
import Selection
import TestKit

// Copies of shapes in a group (Grouping's) are a group of their own: a paste, a duplicate and a drag
// with ⌥ give the copies that shared a group a new one, and a group only one copy was in is none of
// theirs. A cut and its paste move the shapes, which keep their groups.

@MainActor let groupCopyTests = Suite("Copying groups", [
    test("a copy of a group is a group of its own: a click selects the copies together, never with the originals") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [GroupingPlugin()])
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1)))
        h.editor.group([a, b])
        h.editor.selectedShapeIDs = [a, b]
        h.editor.copySelection()
        let before = h.editor.document
        h.editor.paste(centeredAt: CGPoint(x: 150, y: 600))
        let copies = h.editor.shapes(since: before).map(\.id)
        expectEqual(copies.count, 2)
        let originals = try require(h.editor.document[a]?[GroupsProperty.self])
        let copied = try require(h.editor.document[copies[0]]?[GroupsProperty.self])
        expectEqual(h.editor.document[copies[1]]?[GroupsProperty.self], copied)
        expect(copied != originals, "a new group")
        expectEqual(h.editor.selectionUnit(of: copies[0]), copies)
        expectEqual(h.editor.selectionUnit(of: a), [a, b])
    },
    test("⌘D of a group in a group: the copies keep both, each under a new id") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [GroupingPlugin()])
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1))), c = h.add(Box(slot(2)))
        h.editor.group([a, b])
        h.editor.group([a, b, c])
        h.editor.selectedShapeIDs = [a, b, c]
        let before = h.editor.document
        expect(h.command("d"))
        let copies = h.editor.shapes(since: before).map(\.id)
        expectEqual(copies.count, 3)
        let paths = copies.map { h.editor.boardGroups.path(of: $0) }
        expectEqual(paths.map(\.count), [2, 2, 1])
        expectEqual(paths[0], paths[1])
        expectEqual(paths[2], Array(paths[0].prefix(1)))
        expect(Set(paths[0]).isDisjoint(with: h.editor.boardGroups.path(of: a)), "none of the originals' ids")
    },
    test("a copy of one shape of a group is in none of it; two of three copied are a group of two") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [GroupingPlugin()])
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1))), c = h.add(Box(slot(2)))
        h.editor.group([a, b, c])
        let one = h.editor.duplicate([a], offsetBy: CGPoint(x: 0, y: 300))
        expectEqual(h.editor.document[one[0]]?[GroupsProperty.self], nil)
        let two = h.editor.duplicate([a, b], offsetBy: CGPoint(x: 0, y: 600))
        expectEqual(h.editor.selectionUnit(of: two[0]), two)
        expectEqual(h.editor.selectionUnit(of: a), [a, b, c], "the original as it was")
    },
    test("a cut and its paste move the shapes, which keep their group") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [GroupingPlugin()])
        let a = h.add(Box(slot(0))), b = h.add(Box(slot(1)))
        h.editor.group([a, b])
        let group = h.editor.boardGroups.path(of: a)
        h.editor.cut([a, b])
        h.editor.paste()
        expectEqual(h.editor.boardGroups.path(of: a), group)
        expectEqual(h.editor.selectionUnit(of: b), [a, b])
    },
])
