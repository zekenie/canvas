import AppKit
import Canvas
import CanvasTesting
import Selection
import TableOfContents
import TestKit

extension ContentsWindow {
    /// Row `row` of the list (0 is the header), in the hosting view's points.
    func rect(ofRow row: Int) throws -> CGRect {
        let table = try require(table, "no list")
        return table.convert(table.rect(ofRow: row), to: hosting)
    }
}

/// Where, across the middle of `rect`, `a` differs from `b`: the first and last x (in view points),
/// and likewise down the column at `x`. Nil when nothing does.
@MainActor func differingSpan(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, across rect: CGRect, downAt x: CGFloat) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
    let xs = (Int(rect.minX)..<Int(rect.maxX)).filter { pixel(a, at: CGPoint(x: $0, y: Int(rect.midY))) != pixel(b, at: CGPoint(x: $0, y: Int(rect.midY))) }
    let ys = (Int(rect.minY) - 4..<Int(rect.maxY) + 4).filter { pixel(a, at: CGPoint(x: x, y: CGFloat($0))) != pixel(b, at: CGPoint(x: x, y: CGFloat($0))) }
    guard let left = xs.first, let right = xs.last, let top = ys.first, let bottom = ys.last else { return nil }
    return (left...right, top...bottom)
}

@MainActor let hoverTests = Suite("Hover", [
    test("the pointer on a row hovers its shape; leaving the row lets go of it, and only of it") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        let contents = editor.contents
        contents.hover(a)
        expectEqual(editor.hovered, a)
        expect(contents.isHovered(a))
        expect(!contents.isHovered(b))
        contents.hover(b)                   // onto the next row
        expectEqual(editor.hovered, b)
        contents.endHover(a)                // the last row's exit, arriving late
        expectEqual(editor.hovered, b, "leaving a row leaves another shape's hover")
        contents.endHover(b)
        expectEqual(editor.hovered, nil)
    },
    test("a shape hovered on the canvas shows its row as hovered, unless it's selected") {
        let editor = try contentsEditor()
        let (a, b, _) = threeWidgets(editor)
        editor.hovered = a                  // as the select tool does
        expect(editor.contents.isHovered(a))
        expect(!editor.contents.isHovered(b))
        editor.selectedShapeIDs = [a]
        expect(!editor.contents.isHovered(a), "a selected row shows its selection instead")
    },
    test("a hovered shape's row is tinted where a selected row is highlighted, and nothing else changes") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let (a, b, _) = threeWidgets(editor)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 3 }
        let rowA = try w.rect(ofRow: 1), rowB = try w.rect(ofRow: 2)
        let probe = CGPoint(x: rowA.maxX - 30, y: rowA.midY)       // past the text
        let plain = snapshot(w.hosting)
        editor.hovered = a
        w.window.spin { pixel(snapshot(w.hosting), at: probe) != pixel(plain, at: probe) }
        let hovering = snapshot(w.hosting)
        let everywhere = w.hosting.bounds
        expectEqual(changedPixels(plain, hovering, in: everywhere) - changedPixels(plain, hovering, in: rowA), 0, "only A's row changes")
        let tint = try require(differingSpan(hovering, plain, across: rowA, downAt: probe.x))

        editor.hovered = nil
        editor.contents.select([b])
        w.window.spin { w.table?.selectedRowIndexes.count == 1 }
        w.window.settle()
        let selected = snapshot(w.hosting)
        expectEqual(changedPixels(plain, selected, in: rowA), 0, "A's tint went with the hover")
        let highlight = try require(differingSpan(selected, plain, across: rowB, downAt: probe.x))
        expectEqual(tint.x, highlight.x, "the tint spans the row as the selection's highlight does")
        expectEqual(tint.y.count, highlight.y.count)

        editor.hovered = b
        w.window.settle()
        expect(!editor.contents.isHovered(b))
        expectEqual(changedPixels(selected, snapshot(w.hosting), in: everywhere), 0, "a selected row isn't tinted")
    },
])
