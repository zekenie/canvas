import AppKit
import Canvas
import CanvasTesting
import Observation
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
    test("a row that goes away lets go of a hover the pointer on it set, never one the canvas set") {
        let editor = try contentsEditor()
        let (a, _, _) = threeWidgets(editor)
        editor.hovered = a                  // the pointer on it on the canvas, as the select tool does
        editor.contents.endHover(a)         // its row replaced, under the pointer
        expectEqual(editor.hovered, a)
        editor.contents.hover(a)
        editor.contents.endHover(a)
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
    test("a row's tint is observed as its own: its shape's hover, and the selection only while it's hovered") {
        let editor = try contentsEditor()
        let (a, b, c) = threeWidgets(editor)
        let contents = editor.contents
        /// Whether `change` reaches whoever observes `id`'s tint, as its row's view does.
        @MainActor func reaches(_ id: ShapeID, _ change: () -> Void) -> Bool {
            let changed = Flag()
            withObservationTracking { _ = contents.isHovered(id) } onChange: { changed.set() }
            change()
            return changed.isSet
        }
        expect(reaches(a) { contents.hover(a) })
        expect(!reaches(c) { contents.hover(b) }, "the hover moving between two other rows")
        expect(reaches(b) { editor.hovered = c }, "the hover leaving, set as the canvas sets it")
        expect(!reaches(a) { editor.selectedShapeIDs = [a] }, "the selection, while the shape isn't hovered")
        expect(reaches(c) { editor.selectedShapeIDs = [c] }, "the selection, which takes a hovered row's tint")
        expect(reaches(c) { editor.hovered = nil })
    },
    test("a hover redraws the rows it leaves and reaches, not every row") {
        let editor = try contentsEditor(scheduler: TaskScheduler())
        let ids = widgets(150, in: editor)          // under 200: AppKit logs a reentrant update first showing more
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == ids.count }
        w.window.settle()
        let contents = editor.contents
        /// How many rows the list redraws for `change`: once one has, and a few more turns of the run
        /// loop have passed.
        @MainActor func redrawn(_ change: () -> Void) -> Int {
            let before = contents.rowsRedrawn
            change()
            w.window.spin { contents.rowsRedrawn > before }
            w.window.settle()
            return contents.rowsRedrawn - before
        }
        let changes: [(String, Int, @MainActor () -> Void)] = [
            ("the pointer onto a row", 1, { contents.hover(ids[3]) }),
            ("onto the next row", 2, { contents.hover(ids[4]) }),
            ("onto a shape on the canvas", 2, { editor.hovered = ids[5] }),
            ("onto a shape whose row is far down the list", 2, { editor.hovered = ids[140] }),
            ("selecting the hovered shape, which takes its row's tint", 1, { contents.select([ids[140]]) }),
            ("the pointer from the selected shape's row onto another", 2, { contents.hover(ids[6]) }),
            ("the pointer off the list", 1, { contents.endHover(ids[6]) }),
        ]
        for (what, most, change) in changes {
            let rows = redrawn(change)
            expect(rows <= most, "\(what): \(rows) of \(ids.count) rows redrawn, not \(most) or fewer")
        }
    },
])

/// `count` widgets, named in order, added in one transaction.
@MainActor func widgets(_ count: Int, in editor: CanvasEditor) -> [ShapeID] {
    let records = (0..<count).map { ShapeRecord(Widget(name: "Widget \($0)")) }
    editor.transact { transaction in
        for record in records { transaction.insert(record) }
    }
    return records.map(\.id)
}
