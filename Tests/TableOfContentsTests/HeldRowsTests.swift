import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Selection
import TableOfContents
import TestKit

// Held rows (`ContentsHeldRows`): as the rows nested under an open row scroll up past the list's top, its row is held
// there over them, and so is each open row they're nested under in turn; the last row nested under a held row takes
// it up with it. Which rows and where, against VS Code's sticky scroll as it reads, over outlines of levels alone;
// then the list in a window, scrolled, pressed, pointed at, dragged over and walked by keys.

// MARK: Which rows, and where

/// The row at `level` a row of `levels` is nested under (itself at its own level), found by going up.
private func ancestor(in levels: [Int]) -> (Int, Int) -> Int? {
    { row, level in
        var row = row
        while row >= 0, levels[row] > level { row -= 1 }
        return row >= 0 && levels[row] == level ? row : nil
    }
}

/// The rows the list holds over an outline of `levels` (each row's level, the first 0, none more than one deeper than
/// the row before it), its rows `height` tall from `start`, with its top at `top`.
private func held(_ levels: [Int], top: CGFloat, start: CGFloat = 10, height: CGFloat = 28, capacity: Int = 5) -> [ContentsHeldRows.Row] {
    ContentsHeldRows.holding(top: top, start: start, height: height, count: levels.count, capacity: capacity,
                             level: { levels[$0] }, ancestor: ancestor(in: levels)).rows
}

/// What VS Code's sticky scroll holds over the same outline (`StickyScrollController.findStickyState` in its
/// `abstractTree.ts`, as it reads): from the row at the list's top, the row it's nested under at the top level, then
/// the row under that one nested under it, and so on; the row under them held itself only while it's open with rows
/// and up past its place; each held at its place, the rows held above it a row's height each, unless its last row,
/// going up, takes it up with it; the outermost `capacity` kept. Places nearer than the list's tolerance are one, as
/// the list has them.
private func vsCodeHeld(_ levels: [Int], top: CGFloat, start: CGFloat, height: CGFloat, capacity: Int) -> [ContentsHeldRows.Row] {
    let count = levels.count, tolerance = ContentsHeldRows.tolerance
    func node(atHeight y: CGFloat) -> Int? {
        let y = y - start + tolerance
        guard y >= 0 else { return nil }
        let row = Int((y / height).rounded(.down))
        return row < count ? row : nil
    }
    func parent(_ row: Int) -> Int? { (0..<row).last { levels[$0] < levels[row] } }
    func lastDescendant(_ row: Int) -> Int { (row + 1..<count).first { levels[$0] <= levels[row] }.map { $0 - 1 } ?? count - 1 }
    /// `getAncestorUnderPrevious`.
    func ancestor(of node: Int, under previous: Int?) -> Int? {
        var current = node
        while let up = parent(current) {
            if up == previous { return current }
            current = up
        }
        return previous == nil ? current : nil
    }
    var held: [ContentsHeldRows.Row] = [], stickyHeight: CGFloat = 0, previous: Int?
    var under = node(atHeight: top)
    while held.count < capacity, let first = under, let candidate = ancestor(of: first, under: previous) {
        if candidate == first {
            // `nodeIsUncollapsedParent`, `nodeTopAlignsWithStickyNodesBottom`.
            guard candidate + 1 < count, levels[candidate + 1] > levels[candidate],
                  abs(start + CGFloat(candidate) * height - (top + stickyHeight)) > tolerance else { break }
        }
        // `calculateStickyNodePosition`.
        let bottomOfLast = start + CGFloat(lastDescendant(candidate) + 1) * height - top
        let position = stickyHeight + height > bottomOfLast && stickyHeight <= bottomOfLast ? bottomOfLast - height : stickyHeight
        held.append(ContentsHeldRows.Row(row: candidate, top: position))
        stickyHeight += height
        under = node(atHeight: top + position + height)
        previous = candidate
    }
    return held
}

/// A reproducible stream of choices.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 11 | state << 53
    }
}

@MainActor let heldLayoutTests = Suite("Held rows: which and where", [
    test("none at the top, nor while the row at the top shows where it would be held") {
        // Research (0) and its three findings (1), then Launch (0) and one of its own.
        let levels = [0, 1, 1, 1, 0, 1]
        expectEqual(held(levels, top: 0), [])
        expectEqual(held(levels, top: 10), [], "Research at the top")
        expectEqual(held(levels, top: 10 + 28 * 4), [], "Launch at the top")
    },
    test("an open row up past the list's top is held there, over its rows") {
        let levels = [0, 1, 1, 1, 0, 1]
        expectEqual(held(levels, top: 10 + 5), [ContentsHeldRows.Row(row: 0, top: 0)], "Research a little past the top")
        expectEqual(held(levels, top: 10 + 28 + 5), [ContentsHeldRows.Row(row: 0, top: 0)], "its first finding past it")
    },
    test("a row in a row: both held, one a level, the outer first") {
        // Research (0): a finding, Interviews (1) and its three (2), a finding.
        let levels = [0, 1, 1, 2, 2, 2, 1]
        expectEqual(held(levels, top: 10 + 28 * 3 + 5), [ContentsHeldRows.Row(row: 0, top: 0), ContentsHeldRows.Row(row: 2, top: 28)])
    },
    test("the last row nested under a held row takes it up with it, under the row held above it, and away") {
        let levels = [0, 1, 1, 2, 2, 2, 1]
        let lastInterview: CGFloat = 10 + 28 * 6       // its bottom
        expectEqual(held(levels, top: lastInterview - 1.5 * 28), [ContentsHeldRows.Row(row: 0, top: 0), ContentsHeldRows.Row(row: 2, top: 14)],
                    "half up under Research's")
        expectEqual(held(levels, top: lastInterview - 28 + 1), [ContentsHeldRows.Row(row: 0, top: 0)], "gone, once its last row is")
        expectEqual(held(levels, top: lastInterview + 7), [ContentsHeldRows.Row(row: 0, top: -7)], "Research going up with its last row")
        expectEqual(held(levels, top: lastInterview + 28), [], "and gone with it")
    },
    test("a closed row, and a row with no rows under it, are never held") {
        expectEqual(held([0, 0, 0, 0], top: 10 + 28 + 5), [], "every row closed")
        expectEqual(held([0, 1, 1, 0], top: 10 + 28 * 2 + 5).map(\.row), [0], "the finding at the top, Research over it")
    },
    test("at most so many, the outermost kept, and none with no room") {
        let levels = Array(0..<8) + Array(repeating: 8, count: 20)
        let top: CGFloat = 10 + 28 * 9 + 5
        expectEqual(held(levels, top: top).map(\.row), [0, 1, 2, 3, 4])
        expectEqual(held(levels, top: top, capacity: 3).map(\.row), [0, 1, 2])
        expectEqual(held(levels, top: top, capacity: 0), [])
    },
    test("over random outlines, scrolled anywhere, what VS Code's sticky scroll holds") {
        var random = Seeded(state: 7)
        var compared = 0
        for _ in 0..<300 {
            var levels = [0]
            for _ in 0..<Int.random(in: 0..<60, using: &random) {
                levels.append(Int.random(in: 0...(levels[levels.count - 1] + 1), using: &random))
            }
            let start: CGFloat = [0, 10].randomElement(using: &random)!
            let height: CGFloat = [28, 32, 24.5].randomElement(using: &random)!
            let capacity = Int.random(in: 0...6, using: &random)
            for _ in 0..<40 {
                let top = Bool.random(using: &random)
                    ? start + CGFloat(Int.random(in: -1...(levels.count + 1), using: &random)) * height     // a row's edge
                    : CGFloat.random(in: -height...(start + CGFloat(levels.count + 1) * height), using: &random)
                let ours = held(levels, top: top, start: start, height: height, capacity: capacity)
                let theirs = vsCodeHeld(levels, top: top, start: start, height: height, capacity: capacity)
                guard ours == theirs else {
                    return expect(false, "levels \(levels), top \(top), start \(start), height \(height), capacity \(capacity): \(ours), VS Code \(theirs)")
                }
                compared += ours.isEmpty ? 0 : 1
            }
        }
        expect(compared > 1_000, "most scrolls hold something: \(compared)")
    },
])

// MARK: In a window

/// Kickoff, a widget alone; Research, a widget with thirty pins on it, Interviews among them after the fifteenth, a pin
/// with twelve of its own; and Launch, a widget with thirty, so the list scrolls past Research: listed open, front to
/// back, Kickoff, Research (finding 1 to finding 15, Interviews (with 1 to with 12), finding 16 to finding 30), Launch
/// (launch 1 to launch 30), 76 rows. Each shape's id by its name.
@MainActor private func heldBoard() -> (file: CanvasFile, ids: [String: ShapeID]) {
    var shapes: [AnyShapeRecord] = [], ids: [String: ShapeID] = [:]
    // Bottom to top: what's put last is listed first.
    func put<P: ShapeProps>(_ name: String, _ props: P) {
        let id = ShapeID()
        ids[name] = id
        shapes.append(AnyShapeRecord(ShapeRecord(id: id, props)))
    }
    put("Launch", Widget(name: "Launch"))
    for n in (1...30).reversed() { put("launch \(n)", Pin("launch \(n)", on: ids["Launch"])) }
    put("Research", Widget(name: "Research"))
    for n in (16...30).reversed() { put("finding \(n)", Pin("finding \(n)", on: ids["Research"])) }
    put("Interviews", Pin("Interviews", on: ids["Research"]))
    for n in (1...12).reversed() { put("with \(n)", Pin("with \(n)", on: ids["Interviews"])) }
    for n in (1...15).reversed() { put("finding \(n)", Pin("finding \(n)", on: ids["Research"])) }
    put("Kickoff", Widget(name: "Kickoff"))
    return (CanvasFile(root: CanvasDocument(shapes: shapes)), ids)
}

/// `heldBoard()`'s list in a window, Research, Interviews and Launch open, at its top.
@MainActor private func heldWindow() throws -> (ContentsWindow, [String: ShapeID]) {
    let (file, ids) = heldBoard()
    let editor = try contentsEditor(file: file, scheduler: TaskScheduler())
    let state = editor.contents
    for name in ["Research", "Interviews", "Launch"] {
        state.setExpanded(try require(state.entry(try require(ids[name]))), true)
    }
    let w = ContentsWindow(editor)
    w.window.spin { w.rows == 76 }
    w.window.settle()
    return (w, ids)
}

private extension ContentsWindow {
    /// The view the held rows are drawn in.
    var heldView: NSView? { hosting.descendants(NSView.self).first { $0.identifier?.rawValue == "ContentsHeldRows" } }

    /// The rows held over the list's top, outermost first: each one's name and its rect as drawn (an outer one
    /// going up partly above the list's top), in the outline's points.
    var held: [(name: String, rect: CGRect)] {
        guard let outline, let view = heldView, !view.isHidden else { return [] }
        return view.subviews.compactMap { $0 as? NSTableRowView }.reversed().map { (String(describing: $0), outline.convert($0.frame, from: view)) }
    }

    var heldNames: [String] { held.map(\.name) }

    /// How far down the held rows reach, in the outline's points: the list's top with none.
    var heldBottom: CGFloat { held.map(\.rect.maxY).max() ?? listTop }

    var rowHeight: CGFloat { outline?.rect(ofRow: 0).height ?? 0 }

    /// Where the list's top is, in the outline's points.
    var listTop: CGFloat { outline?.enclosingScrollView?.contentView.bounds.minY ?? 0 }

    func rect(named name: String) throws -> CGRect {
        let row = row(name)
        return try require(outline).rect(ofRow: try require(row >= 0 ? row : nil, "no row \(name)"))
    }

    func name(ofRow row: Int) -> String? { outline?.item(atRow: row).map { String(describing: $0) } }

    /// Scrolls the list so `top` (the outline's points) is at its top, as a scroll does.
    func scroll(toTop top: CGFloat) throws {
        try require(outline).scroll(CGPoint(x: 0, y: top))
        window.settle()
    }

    /// A mouse event at a point of the outline (its points).
    func mouse(_ type: NSEvent.EventType, at point: CGPoint, time: TimeInterval) throws -> NSEvent {
        let outline = try require(outline)
        return try require(NSEvent.mouseEvent(with: type, location: outline.convert(point, to: nil), modifierFlags: [], timestamp: time,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// The view the window hands a press at a point of the outline to.
    func hit(outline point: CGPoint) throws -> NSView {
        let outline = try require(outline)
        return try require(window.contentView?.superview?.hitTest(outline.convert(point, to: nil)), "nothing at \(point)")
    }

    /// A click at a point of the outline, as the window delivers one: the view its hit test finds takes the
    /// keyboard if it takes any, then the press; the release waits in the queue for whoever tracks the press, and
    /// one no one took goes to the view pressed. The view pressed.
    @discardableResult
    func click(outline point: CGPoint) throws -> NSView {
        let target = try hit(outline: point)
        if target.acceptsFirstResponder { window.makeFirstResponder(target) }
        let time = ProcessInfo.processInfo.systemUptime
        NSApplication.shared.postEvent(try mouse(.leftMouseUp, at: point, time: time + 0.05), atStart: true)
        target.mouseDown(with: try mouse(.leftMouseDown, at: point, time: time))
        if let up = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
            target.mouseUp(with: up)
        }
        window.settle()
        return target
    }

    /// The pointer moved to a point of the outline, as the outline's tracking area tells it (which doesn't in an
    /// unshown window).
    func move(outline point: CGPoint) throws {
        try require(outline).mouseMoved(with: try mouse(.mouseMoved, at: point, time: ProcessInfo.processInfo.systemUptime))
    }

    /// `rect` (the outline's points) of what the list draws now, drawn over the sheet's surface as the window's
    /// sidebar draws the list.
    func drawnOnSurface(_ rect: CGRect) throws -> NSBitmapImageRep {
        let outline = try require(outline)
        let rep = snapshot(hosting)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let inHosting = hosting.convert(rect, from: outline)
        let top = hosting.isFlipped ? inHosting.minY : hosting.bounds.height - inHosting.maxY
        let part = try require(rep.cgImage?.cropping(to: CGRect(x: inHosting.minX * scale, y: top * scale,
                                                                width: inHosting.width * scale, height: inHosting.height * scale)))
        let out = try require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: part.width, pixelsHigh: part.height, bitsPerSample: 8,
                                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
        let context = try require(NSGraphicsContext(bitmapImageRep: out)).cgContext      // a point a pixel, while it draws
        var surface: CGColor?
        (window.appearance ?? hosting.effectiveAppearance).performAsCurrentDrawingAppearance { surface = ChromeStyle.surface.cgColor }
        let all = CGRect(x: 0, y: 0, width: part.width, height: part.height)
        context.setFillColor(try require(surface))
        context.fill(all)
        context.draw(part, in: all)
        out.size = rect.size
        return out
    }
}

/// The views and cells a tree of accessibility elements holds, from `element` down.
@MainActor private func accessibilityViews(under element: NSAccessibilityProtocol, depth: Int = 12) -> [NSView] {
    let own: [NSView] = [element as? NSView, (element as? NSCell)?.controlView].compactMap { $0 }
    guard depth > 0 else { return own }
    let children = (element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
    return own + children.flatMap { accessibilityViews(under: $0, depth: depth - 1) }
}

@MainActor let heldRowsWindowTests = Suite("Held rows in a window", [
    test("nothing's held at the top; scrolled into an open row's rows, its row is held at the list's top, over them") {
        let (w, _) = try heldWindow()
        let h = w.rowHeight
        expectEqual(w.heldNames, [])
        try w.scroll(toTop: try w.rect(named: "finding 20").minY + 0.4 * h)
        expectEqual(w.heldNames, ["Research"])
        expectEqual(w.held.first?.rect, CGRect(x: 0, y: w.listTop, width: try require(w.outline).bounds.width, height: h))
        expect(try w.rect(named: "Research").maxY <= w.listTop, "its own row out of view above")
        try w.scroll(toTop: try w.rect(named: "Launch").minY)
        expectEqual(w.heldNames, [], "Launch at the top, as itself")
    },
    test("a row in a row: both held, one a level, the outer first") {
        let (w, _) = try heldWindow()
        let h = w.rowHeight
        try w.scroll(toTop: try w.rect(named: "with 6").minY + 0.4 * h)
        expectEqual(w.heldNames, ["Research", "Interviews"])
        expectEqual(w.held.map(\.rect.minY), [w.listTop, w.listTop + h])
    },
    test("the last row nested under a held row takes it up with it, under the row held above it, and away") {
        let (w, _) = try heldWindow()
        let h = w.rowHeight
        let lastInterview = try w.rect(named: "with 12")
        try w.scroll(toTop: lastInterview.maxY - 1.5 * h)
        expectEqual(w.heldNames, ["Research", "Interviews"])
        expectEqual(w.held.map(\.rect.minY), [w.listTop, w.listTop + 0.5 * h], "Interviews half up under Research")
        expectEqual(w.heldBottom, w.listTop + 1.5 * h, "its lower half showing under Research's")
        try w.scroll(toTop: lastInterview.maxY - h + 1)
        expectEqual(w.heldNames, ["Research"], "past its last row, Interviews is held no more")
        let lastFinding = try w.rect(named: "finding 30")
        try w.scroll(toTop: lastFinding.minY + 0.25 * h)
        expectEqual(w.held.map(\.name), ["Research"])
        expectEqual(w.held.first?.rect.minY, w.listTop - 0.25 * h, "Research going up with its last row")
        expectEqual(w.heldBottom, lastFinding.maxY)
    },
    test("a held row is drawn as its row is, on the sheet's surface over the rows under it, with a hairline under the held rows") {
        let (w, _) = try heldWindow()
        w.window.appearance = NSAppearance(named: .aqua)
        w.window.settle()
        let h = w.rowHeight
        let row = try w.drawnOnSurface(try w.rect(named: "Research"))
        try w.scroll(toTop: try w.rect(named: "finding 20").minY + 0.4 * h)
        let held = try require(w.held.first?.rect)
        let drawn = try w.drawnOnSurface(held)
        // The symbol's column apart: a source list's symbol blends with what's under it, which in the window's
        // sidebar is the sheet's surface under both, and in this window nothing under the list's own rows.
        let cell = try require(w.outline).frameOfCell(atColumn: 0, row: w.row("Research"))
        let symbol = CGRect(x: cell.minX, y: 0, width: 24, height: held.height)
        let whole = CGRect(origin: .zero, size: held.size)
        let difference = largestDifference(drawn, row, in: whole, excluding: [symbol])
        expect(difference <= 3, "the held row drawn as Research's row: \(difference) apart")
        expect(largestDifference(drawn, row, in: symbol) <= 32, "its symbol too, blended alike")
        // Under the held row, the hairline, over the row under it; a point on, that row.
        let under = try w.drawnOnSurface(CGRect(x: held.minX, y: held.maxY, width: held.width, height: 4))
        let x = held.width - 6       // past every row's text
        let line = pixel(under, at: CGPoint(x: x, y: 0.5)), beyond = pixel(under, at: CGPoint(x: x, y: 2.5))
        expect(line[0] < beyond[0] - 10, "the hairline \(line) darker than the row under it \(beyond)")
    },
    test("a press on a held row is its row's: the row scrolled into its place under the rows held above it, under the press, which the outline takes with the keyboard") {
        // A synthesized press doesn't reach a table's own tracking in an unshown window, so what the outline does with
        // it (a selection, a drag) isn't seen here: that the row is under it, and the outline has it, is.
        let (w, _) = try heldWindow()
        let h = w.rowHeight
        let outline = try require(w.outline)
        try w.scroll(toTop: try w.rect(named: "with 6").minY + 0.4 * h)
        let interviews = try require(w.held.last)
        let location = outline.convert(CGPoint(x: interviews.rect.midX, y: interviews.rect.midY), to: nil)
        let target = try w.click(outline: outline.convert(location, from: nil))
        expect(target === w.heldView, "the press is the held rows': \(target)")
        expectEqual(try w.rect(named: "Interviews").minY, w.listTop + h, "its row where it was held, under Research's")
        expectEqual(w.heldNames, ["Research"])
        expectEqual(outline.row(at: outline.convert(location, from: nil)), w.row("Interviews"), "under the press")
        expect(try w.hit(outline: outline.convert(location, from: nil)).isDescendant(of: outline), "where a press now lands on the row itself")
        expect(w.window.firstResponder === outline, "the outline has the keyboard, as a press on a row gives it")
    },
    test("a press on a held row's triangle lands on its row's own triangle") {
        let (w, _) = try heldWindow()
        let h = w.rowHeight
        let outline = try require(w.outline)
        try w.scroll(toTop: try w.rect(named: "with 6").minY + 0.4 * h)
        let interviews = try require(w.held.last)
        let triangle = outline.frameOfOutlineCell(atRow: w.row("Interviews"))
        let location = outline.convert(CGPoint(x: triangle.midX, y: interviews.rect.midY), to: nil)
        try w.click(outline: outline.convert(location, from: nil))
        expectEqual(try w.rect(named: "Interviews").minY, w.listTop + h)
        let landed = try w.hit(outline: outline.convert(location, from: nil))
        expect(landed.identifier == NSOutlineView.disclosureButtonIdentifier && landed.isDescendant(of: outline),
               "the row's own triangle under the press: \(landed)")
        expect(w.window.firstResponder !== outline, "a triangle's press leaves the keyboard where it was")
    },
    test("the pointer on a held row is on its row, and hovers its shape; the rows under the held rows are under them") {
        let (w, ids) = try heldWindow()
        let h = w.rowHeight
        let outline = try require(w.outline)
        try w.scroll(toTop: try w.rect(named: "finding 20").minY + 0.4 * h)
        let research = try require(w.held.first)
        try w.move(outline: CGPoint(x: research.rect.midX, y: research.rect.midY))
        expectEqual(w.editor.hovered, ids["Research"])
        let below = CGPoint(x: research.rect.midX, y: w.heldBottom + 0.5 * h)
        try w.move(outline: below)
        expectEqual(w.editor.hovered, try require(w.name(ofRow: outline.row(at: below)).flatMap { ids[$0] }), "the row shown there")
        let hairline = CGPoint(x: research.rect.midX, y: research.rect.maxY + 0.5)
        try w.move(outline: hairline)
        expectEqual(w.editor.hovered, try require(w.name(ofRow: outline.row(at: hairline)).flatMap { ids[$0] }),
                    "the hairline under the held rows is over the row under it")
        expect(try w.hit(outline: hairline).isDescendant(of: outline), "which a press there reaches")
        let view = try require(w.heldView), tips = try require(view as? NSViewToolTipOwner)
        let tip = tips.view(view, stringForToolTip: 0, point: view.convert(CGPoint(x: research.rect.midX, y: research.rect.midY), from: outline), userData: nil)
        expectEqual(tip, "Research", "its tooltip its row's")
    },
    test("a section's row is held as any row is, over the rows gathered under it") {
        let editor = try aliasEditor(scheduler: TaskScheduler())
        for n in (0..<20).reversed() { editor.add(Widget(CGRect(x: 5000 + n * 200, y: 0, width: 100, height: 60), name: "after \(n)")) }
        let corral = editor.add(Corral(CGRect(x: 0, y: 0, width: 4000, height: 400)))
        let aliases = (0..<40).map { editor.add(Alias("alias \($0)", frame: CGRect(x: 10 + $0 * 50, y: 10, width: 40, height: 30))) }
        editor.put(aliases, in: corral)
        editor.contents.setExpanded(ContentsSectionKey(aliasesSection, at: .under(corral)), true)
        let w = ContentsWindow(editor)
        w.window.spin { w.rows == 62 }
        w.window.settle()
        expectEqual(Array(w.shown.prefix(3)), ["corral", "  Aliases · 40", "    alias 39"])
        let h = w.rowHeight
        try w.scroll(toTop: try w.rect(named: "alias 20").minY + 0.4 * h)
        expectEqual(w.heldNames, ["corral", "Aliases"])
        expectEqual(w.held.map(\.rect.minY), [w.listTop, w.listTop + h])
    },
    test("a drag over a held row is over its row: it points there, and a drop there restacks beside its shape") {
        let (w, ids) = try heldWindow()
        let h = w.rowHeight
        let outline = try require(w.outline), state = w.editor.contents
        try w.scroll(toTop: try w.rect(named: "finding 20").minY + 0.4 * h)
        let research = try require(w.held.first)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([try require(w.writer(ofRow: w.row("Launch")))])
        let point = CGPoint(x: research.rect.midX, y: research.rect.minY + 0.2 * h)
        let target = try w.hit(outline: point)
        expect(target === w.heldView && target.registeredDraggedTypes == outline.registeredDraggedTypes, "the held rows take what a row carries")
        let drag = RowDrag(pasteboard: pasteboard, source: outline, location: outline.convert(point, to: nil), window: w.window)
        expectEqual(target.draggingEntered(drag), .move)
        expectEqual(target.draggingUpdated(drag), .move)
        expectEqual(state.dropZone(for: try require(ids["Research"])), .above)
        expect(target.prepareForDragOperation(drag))
        expect(target.performDragOperation(drag))
        target.concludeDragOperation(drag)
        expectEqual(state.entries.map { $0.label?.text }, ["Research", "Launch", "Kickoff"], "back to front: Launch in front of Research")
        expectEqual(w.editor.undoHistory.undoName, "Reorder")
    },
    test("a row the keys reach is never under the held rows: each ↑ lands on a row in view, under those it's nested under") {
        let (w, _) = try heldWindow()
        let outline = try require(w.outline)
        try w.scroll(toTop: try w.rect(named: "with 6").minY)
        expectEqual(w.heldNames, ["Research", "Interviews"])
        try w.click(row: w.row("with 8"))
        try w.focusList()
        let keys = KeyDriver(w.window)
        for expected in ["with 7", "with 6", "with 5", "with 1", "Interviews", "finding 15", "finding 14"] {
            while w.name(ofRow: outline.selectedRow) != expected, outline.selectedRow > 0 {
                _ = keys.send(.up)
                w.window.settle()
                let rect = outline.rect(ofRow: outline.selectedRow)
                expect(rect.minY >= w.heldBottom - ContentsHeldRows.tolerance && rect.maxY <= w.listTop + outline.visibleRect.height,
                       "\(w.name(ofRow: outline.selectedRow) ?? "?") at \(rect.minY), the held rows \(w.heldNames) to \(w.heldBottom)")
            }
        }
        expectEqual(w.heldNames, ["Research"], "finding 14 under Research's")
        expect(w.window.firstResponder === outline, "the list keeps the keyboard")
    },
    test("a selection made elsewhere is scrolled to clear of the held rows, under those it's nested under") {
        let (w, ids) = try heldWindow()
        try w.scroll(toTop: try w.rect(named: "Launch").minY)
        w.editor.selectedShapeIDs = [try require(ids["with 9"])]
        w.window.spin { w.outline?.selectedRow == w.row("with 9") }
        expectEqual(w.heldNames, ["Research", "Interviews"])
        expectEqual(try w.rect(named: "with 9").minY, w.heldBottom, "just under them")
    },
    test("a held row shows its row's selection") {
        let (w, ids) = try heldWindow()
        let h = w.rowHeight
        w.editor.selectedShapeIDs = [try require(ids["Research"])]
        w.window.spin { w.outline?.selectedRow == w.row("Research") }
        try w.scroll(toTop: try w.rect(named: "finding 20").minY + 0.4 * h)
        let rows = try require(w.heldView).subviews.compactMap { $0 as? NSTableRowView }
        expectEqual(rows.map(\.isSelected), [true])
        w.editor.selectedShapeIDs = [try require(ids["Kickoff"])]
        w.window.spin { rows.first?.isSelected == false }
    },
    test("a scroll under a held row shows it once; its shape changing shows it again, as it is now") {
        let (w, ids) = try heldWindow()
        let h = w.rowHeight, state = w.editor.contents, research = try require(ids["Research"])
        let before = state.heldRowsShown
        let start = try w.rect(named: "finding 17").minY
        for step in 0..<20 { try w.scroll(toTop: start + CGFloat(step) * 0.37 * h) }
        expectEqual(w.heldNames, ["Research"])
        expectEqual(state.heldRowsShown - before, 1, "shown as it came to be held, and not again")
        w.editor.transact { $0.update(research, as: Widget.self) { $0.props.name = "Research notes" } }
        w.window.spin { w.heldNames == ["Research notes"] }
        expectEqual(state.heldRowsShown - before, 2)
    },
    test("assistive apps don't see the held rows: what they draw is the outline's own rows") {
        let (w, _) = try heldWindow()
        let h = w.rowHeight
        try w.scroll(toTop: try w.rect(named: "with 6").minY + 0.4 * h)
        let view = try require(w.heldView)
        expectEqual(w.heldNames, ["Research", "Interviews"])
        expect(!view.isAccessibilityElement())
        let scroll = try require(w.outline?.enclosingScrollView)
        let seen = accessibilityViews(under: scroll)
        expect(!seen.isEmpty && !seen.contains { $0 === view || $0.isDescendant(of: view) }, "the list's elements hold none of the held rows'")
    },
])

