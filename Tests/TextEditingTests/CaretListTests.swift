import AppKit
import CanvasTesting
import TestKit
import TextEditing

// Every caret list's pieces, without an owner of the app's: the model (rows, the highlight, the
// keys), and the window over a text view in an
// unshown window (where it's placed, what follows and closes it, its rows drawn, clicked and said).
// Mentions' `@` picker is built on them (MentionsTests hold it whole).

private let fruitMetrics = CaretListMetrics(width: 240, rowHeight: 20, rowsShown: 5, offset: 3)

/// A list of `count` fruit, each an item with a detail.
@MainActor private func fruitRows(_ count: Int) -> [CaretListRow] {
    let names = ["apple", "apricot", "banana", "cherry", "damson", "elderberry", "fig", "grape", "kiwi", "lemon", "mango", "melon"]
    return (0..<count).map { .item(CaretListItem(names[$0 % names.count], detail: "fruit")) }
}

/// A text view in an unshown window with a caret list of its own, as an owner has one: open at a
/// range of its text, closed by the window's asking (`closes` counts) or by the test.
@MainActor
private final class ListedText {
    let window: NSWindow
    /// The text view's superview, which a test moves as the canvas moves an editing view.
    let holder: NSView
    let textView: EditingTextView
    var list: CaretList?
    var listWindow: CaretListWindow?
    var anchor = NSRange(location: 6, length: 1)
    var closes = 0
    var picks: [Int] = []
    var posted: [NSAccessibility.Notification] = []
    var announced: [String] = []

    init() {
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = content
        holder = NSView(frame: CGRect(x: 100, y: 100, width: 300, height: 200))
        content.addSubview(holder)
        textView = EditingTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        textView.string = "apple banana cherry"
        holder.addSubview(textView)
        window.makeFirstResponder(textView)
    }

    /// Opens a list of `rows` under the anchor.
    func open(_ rows: [CaretListRow]) {
        let list = CaretList(metrics: fruitMetrics)
        self.list = list
        listWindow = CaretListWindow(list, accessibilityLabel: "Fruit", over: textView, anchor: { [weak self] in self?.anchor },
                                     pick: { [weak self] row in self?.picks.append(row) },
                                     close: { [weak self] in self?.close() },
                                     post: { [weak self] _, notification, userInfo in
                                         self?.posted.append(notification)
                                         if let words = userInfo?[.announcement] as? String { self?.announced.append(words) }
                                     })
        list.onChange = { [weak self] in self?.listWindow?.listDidChange() }
        list.setRows(rows)
    }

    /// Opens a list of `rows` under a rect of its own (screen coordinates; `rect` is read as the window
    /// is placed), as a field that isn't the text's caret has one.
    func open(_ rows: [CaretListRow], under rect: @escaping @MainActor () -> CGRect?) {
        let list = CaretList(metrics: fruitMetrics)
        self.list = list
        listWindow = CaretListWindow(list, accessibilityLabel: "Fruit", over: textView, anchorRect: rect,
                                     pick: { [weak self] row in self?.picks.append(row) },
                                     close: { [weak self] in self?.close() })
        list.onChange = { [weak self] in self?.listWindow?.listDidChange() }
        list.setRows(rows)
    }

    func close() {
        closes += 1
        listWindow?.dismiss()
        listWindow = nil
        list = nil
    }

    /// The anchor's rect on screen.
    var anchorRect: CGRect { textView.firstRect(forCharacterRange: anchor, actualRange: nil) }

    var rowsView: NSView? { listWindow?.contentView?.descendants.first { $0.accessibilityRole() == .list } }

    func mouse(_ type: NSEvent.EventType, row: Int, in rows: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: rows.convert(CGPoint(x: 100, y: CGFloat(row) * fruitMetrics.rowHeight + 10), to: nil),
                           modifierFlags: [], timestamp: 1, windowNumber: listWindow?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
}

/// A rect an owner moves, for a closure to read.
@MainActor private final class MovingRect {
    var rect: CGRect?
    init(_ rect: CGRect?) { self.rect = rect }
}

/// The alpha of a view's pixel at a point in its bounds, drawn in the light appearance.
@MainActor private func alphas(of view: NSView) throws -> (Int, Int) -> CGFloat {
    let rep = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    return { x, y in rep.colorAt(x: x * rep.pixelsWide / Int(view.bounds.width), y: y * rep.pixelsHigh / Int(view.bounds.height))?.alphaComponent ?? 0 }
}

/// A text view that keeps a list at its caret, as Mentions' and a code editor's do, saying only what
/// it lists and what a pick does (it closes the list, as theirs do): the keys, and what closes it,
/// are every `EditingTextView`'s. In an unshown window, with the keyboard.
@MainActor
private final class ListingTextView: EditingTextView {
    private(set) var listWindow: CaretListWindow?
    private(set) var picks: [Int] = []
    private(set) var closes = 0

    override var caretListWindow: CaretListWindow? { listWindow }

    static func inWindow() -> (window: NSWindow, view: ListingTextView) {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = ListingTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        view.string = "apple banana cherry"
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        return (window, view)
    }

    func open(_ rows: [CaretListRow]) {
        let list = CaretList(metrics: fruitMetrics)
        let listWindow = CaretListWindow(list, accessibilityLabel: "Fruit", over: self, anchor: { NSRange(location: 0, length: 1) },
                                         pick: { [weak self] row in
                                             self?.picks.append(row)
                                             self?.close()
                                         },
                                         close: { [weak self] in self?.close() })
        self.listWindow = listWindow
        list.onChange = { [weak listWindow] in listWindow?.listDidChange() }
        list.setRows(rows)
    }

    func close() {
        guard let listWindow else { return }
        self.listWindow = nil
        closes += 1
        listWindow.dismiss()
    }
}

@MainActor let caretListTests = Suite("Caret lists", [
    // MARK: The model

    test("rows: the first item is highlighted; headers and empty states never are; each change is heard") {
        let list = CaretList(metrics: fruitMetrics)
        var changes = 0
        list.onChange = { changes += 1 }
        list.setRows([.header("Fresh")] + fruitRows(2))
        expectEqual(list.highlighted, 1)
        expectEqual(list.highlightedItem?.title, "apple")
        expectEqual(changes, 1)
        list.highlight(row: 0)
        expectEqual(list.highlighted, 1, "a header isn't highlighted")
        list.highlight(row: 9)
        expectEqual(list.highlighted, 1)
        expectEqual(changes, 1, "nothing changed")
        list.highlight(row: 2)
        expectEqual(list.highlightedItem?.title, "apricot")
        expectEqual(changes, 2)
        list.setRows([.empty("Nothing ripe")])
        expectEqual(list.highlighted, nil)
        list.moveHighlight(by: 1)
        list.highlight(row: 0)
        expectEqual(list.highlighted, nil)
        expectEqual(list.perform(#selector(NSResponder.insertNewline(_:))).taken, false, "Return does what it would without the list")
        expectEqual(list.perform(#selector(NSResponder.insertTab(_:))).taken, false)
        expectEqual(CaretList(metrics: fruitMetrics, rows: fruitRows(3)).highlighted, 0)
    },

    test("keys: ↑ and ↓ wrap, pages move a page and stop at the ends, Return and Tab pick, Escape, ⌥⎋ and F5 close, others pass") {
        let list = CaretList(metrics: fruitMetrics, rows: fruitRows(12))
        @MainActor func key(_ selector: Selector) -> (Bool, CaretList.Action?) {
            let result = list.perform(selector)
            return (result.taken, result.action)
        }
        expect(key(#selector(NSResponder.moveUp(_:))) == (true, nil))
        expectEqual(list.highlighted, 11)
        _ = key(#selector(NSResponder.moveDown(_:)))
        expectEqual(list.highlighted, 0)
        _ = key(#selector(NSResponder.scrollPageDown(_:)))
        expectEqual(list.highlighted, 5, "a page is the rows shown")
        _ = key(#selector(NSResponder.pageDown(_:)))
        _ = key(#selector(NSResponder.pageDown(_:)))
        expectEqual(list.highlighted, 11)
        _ = key(#selector(NSResponder.scrollPageUp(_:)))
        expectEqual(list.highlighted, 6)
        _ = key(#selector(NSResponder.pageUp(_:)))
        _ = key(#selector(NSResponder.pageUp(_:)))
        expectEqual(list.highlighted, 0)
        expect(key(#selector(NSResponder.insertNewline(_:))) == (true, .pick))
        expect(key(#selector(NSResponder.insertTab(_:))) == (true, .pick))
        expect(key(#selector(NSResponder.cancelOperation(_:))) == (true, .close))
        expect(key(#selector(NSResponder.complete(_:))) == (true, .close))
        expect(key(#selector(NSResponder.moveLeft(_:))) == (false, nil))
        expect(key(#selector(NSResponder.deleteBackward(_:))) == (false, nil))
        expectEqual(CaretList.action(for: #selector(NSResponder.moveDown(_:))), .moveDown)
        expectEqual(CaretList.action(for: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))), nil)
    },

    test("an item says its title and detail unless it says otherwise") {
        expectEqual(CaretListItem("apple", detail: "fruit").spoken, "apple, fruit")
        expectEqual(CaretListItem("apple").spoken, "apple")
        expectEqual(CaretListItem("apple", detail: "fruit", spoken: "apple, 1 of 3").spoken, "apple, 1 of 3")
    },

    // MARK: The window

    test("it's placed under its anchor, its rows' text under the anchor's start, but never shown while the text's window isn't") {
        let text = ListedText()
        text.open(fruitRows(3))
        let window = try require(text.listWindow)
        expect(!window.isVisible)
        expect(text.window.childWindows?.isEmpty ?? true)
        let anchor = text.anchorRect
        expectEqual(window.frame.width, 240)
        expectClose(window.frame.maxY, anchor.minY - 3)
        expectClose(window.frame.minX, anchor.minX - 12, within: 1)
        expectClose(window.frame.height, 3 * 20 + 10, within: 0.001)
        text.list?.setRows(fruitRows(12))
        expectClose(window.frame.height, 5 * 20 + 10, within: 0.001)
        expectClose(window.frame.maxY, anchor.minY - 3)
    },

    test("under a rect of its own it's centered on it at its list's width, offset below it, and follows it; it never asks to close as the text scrolls away") {
        let text = ListedText()
        let moving = MovingRect(CGRect(x: text.window.frame.minX + 100, y: text.window.frame.minY + 300, width: 400, height: 36))
        var rect: CGRect { moving.rect! }
        text.open(fruitRows(3), under: { moving.rect })
        let window = try require(text.listWindow)
        expect(!window.isVisible)
        expectEqual(window.frame.width, 240, "its metrics' width, not the rect's")
        expectClose(window.frame.midX, rect.midX, within: 0.5)
        expectClose(window.frame.maxY, rect.minY - 3)
        expectClose(window.frame.height, 3 * 20 + 10, within: 0.001)
        text.list?.setRows(fruitRows(12))
        expectClose(window.frame.height, 5 * 20 + 10, within: 0.001)
        expectClose(window.frame.maxY, rect.minY - 3)
        // The owner moves the rect; the next change, or a view the text is in moving, puts the list under it.
        moving.rect?.origin.x += 40
        text.holder.frame.origin.x += 1
        expectClose(window.frame.midX, rect.midX, within: 0.5)
        // The text going out of view closes a list at a range of it; one at a rect has no range to lose.
        text.holder.frame.origin = CGPoint(x: 2000, y: 100)
        expectEqual(text.closes, 0)
        expect(text.listWindow != nil)
        text.close()
    },

    test("under a rect with no room below, it goes above it, on the screen; a rect it can't read leaves it put") {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let text = ListedText()
        let low = CGRect(x: screen.midX - 200, y: screen.minY + 40, width: 400, height: 36)
        let moving = MovingRect(low)
        text.open(fruitRows(5), under: { moving.rect })
        var frame = try require(text.listWindow?.frame)
        expect(low.minY - 3 - frame.height < screen.minY, "no room below")
        expectClose(frame.minY, low.maxY + 3, within: 1)
        expect(frame.maxY <= screen.maxY && frame.minX >= screen.minX)
        moving.rect = nil
        text.list?.moveHighlight(by: 1)
        expectEqual(try require(text.listWindow?.frame), frame, "nil: it stays")
        // Past the screen's left edge, the window is kept on it.
        moving.rect = CGRect(x: screen.minX - 100, y: screen.midY, width: 100, height: 36)
        text.list?.moveHighlight(by: 1)
        frame = try require(text.listWindow?.frame)
        expectClose(frame.minX, screen.minX, within: 0.5)
        text.close()
    },

    test("with no room below its anchor, it goes above the line, on the screen") {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let text = ListedText()
        // The anchor 30 points above the screen's bottom.
        text.window.setFrameOrigin(CGPoint(x: screen.minX + 100, y: text.window.frame.minY + screen.minY + 30 - text.anchorRect.minY))
        text.open(fruitRows(5))
        let frame = try require(text.listWindow?.frame)
        let anchor = text.anchorRect
        expect(anchor.minY - 3 - frame.height < screen.minY, "no room below: \(anchor) on \(screen)")
        expectClose(frame.minY, anchor.maxY + 3, within: 1)
        expect(frame.maxY <= screen.maxY && frame.minX >= screen.minX)
    },

    test("it follows its anchor as a view the text is in moves, and asks its owner to close it once the anchor is out of view") {
        let text = ListedText()
        text.open(fruitRows(3))
        let before = try require(text.listWindow?.frame)
        text.holder.frame.origin.x += 50
        let moved = try require(text.listWindow?.frame)
        expectClose(moved.minX - before.minX, 50)
        expectClose(moved.height, before.height)
        expectEqual(text.closes, 0)
        text.holder.frame.origin = CGPoint(x: 2000, y: 100)
        expectEqual(text.closes, 1)
        expect(text.listWindow == nil)
    },

    test("the text's window resigning key asks its owner to close it; once dismissed, it follows nothing") {
        let text = ListedText()
        text.open(fruitRows(3))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: text.window)
        expectEqual(text.closes, 1)
        text.open(fruitRows(3))
        let dismissed = try require(text.listWindow)
        dismissed.dismiss()
        dismissed.dismiss()
        text.holder.frame.origin = CGPoint(x: 2000, y: 100)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: text.window)
        expectEqual(text.closes, 1, "a dismissed window asks nothing")
        expectEqual(text.posted.filter { $0 == .uiElementDestroyed }.count, 2, "each window's list said to go once")
    },

    test("VoiceOver hears the list change, the highlighted row said, and go; through its owner's hook") {
        let text = ListedText()
        text.open(fruitRows(3))
        expectEqual(text.posted, [.selectedChildrenChanged, .announcementRequested])
        expectEqual(text.announced, ["apple, fruit"])
        text.list?.moveHighlight(by: 1)
        expectEqual(text.announced.last, "apricot, fruit")
        text.list?.setRows([.empty("Nothing ripe")])
        expectEqual(text.announced.last, "Nothing ripe", "an empty state is said")
        let rows = try require(text.rowsView)
        expectEqual(rows.accessibilityLabel(), "Fruit")
        expect(rows.accessibilityParent() as AnyObject? === text.textView, "the list is the text view's")
        text.close()
        expectEqual(text.posted.last, .uiElementDestroyed)
    },

    // MARK: Rows

    test("rows: the highlight drawn on the highlighted item; items and empty states said, headers not") {
        let text = ListedText()
        text.open([.header("Fresh")] + fruitRows(2) + [.item(CaretListItem("fig", symbol: "leaf", trailingSymbol: "lock.fill", spoken: "fig, dried"))])
        let rows = try require(text.rowsView)
        expectEqual(rows.frame.height, 4 * 20)
        let alpha = try alphas(of: rows)
        expect(alpha(120, 30) > 0.9, "the highlighted row is filled")
        expectEqual(alpha(120, 50), 0, "the next isn't")
        expectEqual(alpha(120, 10), 0, "nor the header")
        let spoken = (rows.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        expectEqual(spoken, ["apple, fruit", "apricot, fruit", "fig, dried"])
        text.list?.moveHighlight(by: -1)
        let moved = try alphas(of: rows)
        expect(moved(120, 70) > 0.9, "↑ wrapped to the last")
    },

    test("a separated item has a line one point thick across the top of its row, where it isn't highlighted; the rows above and below have none") {
        let text = ListedText()
        text.open(fruitRows(2) + [.item(CaretListItem("kiwi", separated: true))])
        let rows = try require(text.rowsView)
        let alpha = try alphas(of: rows)
        expect(alpha(120, 40) > 0.05, "a line at the top of the third row")
        expectEqual(alpha(120, 41), 0, "one point thick")
        expectEqual(alpha(120, 20), 0, "none above the second row")
        expectEqual(alpha(120, 59), 0, "none below")
        expectEqual(alpha(3, 40), 0, "in from the row's edge")
        text.list?.moveHighlight(by: -1)
        let moved = try alphas(of: rows)
        expect(moved(120, 41) > 0.9, "the highlight is over it once the row is highlighted")
    },

    test("an item's detail takes what its title leaves, and keeps its share of the row where both are long") {
        let text = ListedText()
        let long = "Grows on trees in warm places, dried or fresh"
        // The first item is highlighted, filled; the two after it aren't.
        text.open([.item(CaretListItem("kiwi")), .item(CaretListItem("fig", detail: long)),
                   .item(CaretListItem("elderberry elderberry elderberry elderberry", detail: long))])
        let rows = try require(text.rowsView)
        let alpha = try alphas(of: rows)
        func ink(row: Int, from: Int, to: Int) -> Bool {
            (from..<to).contains { x in (row * 20 + 6..<row * 20 + 14).contains { alpha(x, $0) > 0.3 } }
        }
        // A 230-point row, whose detail keeps at least 40% of it, its last 92 points but its inset.
        expect(ink(row: 1, from: 40, to: 125), "a short title: the detail runs on from just past it")
        expect(ink(row: 2, from: 140, to: 220), "a long title: cut short, so the detail keeps its share")
    },

    test("a detail's matched characters are set in semibold, and the row is said as before") {
        let text = ListedText()
        let detail = "Mmmmmmmm › Mmmmmmmm"
        text.open([.item(CaretListItem("kiwi")), .item(CaretListItem("fig", detail: detail)),
                   .item(CaretListItem("fig", detail: detail, detailMatched: [0..<8, 11..<19]))])
        let rows = try require(text.rowsView)
        let rep = try require(rows.bitmapImageRepForCachingDisplay(in: rows.bounds))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rows.cacheDisplay(in: rows.bounds, to: rep) }
        /// How much ink a row's detail leaves, at the trailing end.
        @MainActor func ink(row: Int) -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / rows.bounds.width
            var total: CGFloat = 0
            for y in Int(CGFloat(row * 20) * scale)..<Int(CGFloat(row * 20 + 20) * scale) {
                for x in Int(70 * scale)..<Int(230 * scale) { total += rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
            }
            return total
        }
        expect(ink(row: 1) > 0)
        expect(ink(row: 2) > ink(row: 1) * 1.05, "semibold: \(ink(row: 2)) against \(ink(row: 1))")
        let spoken = (rows.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        expectEqual(spoken, ["kiwi", "fig, \(detail)", "fig, \(detail)"])
        expectEqual(CaretListItem("fig", detail: "dried", detailMatched: [0..<2], detailDimmed: [3..<5]).spoken, "fig, dried")
        expectEqual(CaretListItem("fig").detailMatched, [])
        expectEqual(CaretListItem("fig").detailDimmed, [])
    },

    test("a detail's dimmed characters are drawn fainter") {
        let text = ListedText()
        let detail = "Mmmmmmmm › Mmmmmmmm"
        text.open([.item(CaretListItem("kiwi")), .item(CaretListItem("fig", detail: detail)),
                   .item(CaretListItem("fig", detail: detail, detailDimmed: [0..<8, 11..<19]))])
        let rows = try require(text.rowsView)
        let rep = try require(rows.bitmapImageRepForCachingDisplay(in: rows.bounds))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rows.cacheDisplay(in: rows.bounds, to: rep) }
        @MainActor func ink(row: Int) -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / rows.bounds.width
            var total: CGFloat = 0
            for y in Int(CGFloat(row * 20) * scale)..<Int(CGFloat(row * 20 + 20) * scale) {
                for x in Int(70 * scale)..<Int(230 * scale) { total += rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
            }
            return total
        }
        expect(ink(row: 1) > 0)
        expect(ink(row: 2) < ink(row: 1) * 0.8, "fainter: \(ink(row: 2)) against \(ink(row: 1))")
    },

    test("the pointer over an item's row highlights it, and a click picks its index; headers and empty states do neither") {
        let text = ListedText()
        text.open([.header("Fresh")] + fruitRows(3))
        let rows = try require(text.rowsView)
        rows.mouseMoved(with: text.mouse(.mouseMoved, row: 3, in: rows))
        expectEqual(text.list?.highlighted, 3)
        rows.mouseMoved(with: text.mouse(.mouseMoved, row: 0, in: rows))
        expectEqual(text.list?.highlighted, 3, "a header isn't highlighted")
        rows.mouseDown(with: text.mouse(.leftMouseDown, row: 0, in: rows))
        expectEqual(text.picks, [])
        rows.mouseDown(with: text.mouse(.leftMouseDown, row: 2, in: rows))
        expectEqual(text.picks, [2])
        expectEqual(text.list?.highlighted, 2, "highlighted as it's picked")
    },

    // MARK: A subclass's list: the keys, and what closes it

    test("a subclass's list has the keys every caret list has: ↓ moves, Return picks, Escape and ⌘. close; once it's closed, they're the text's") {
        let (window, view) = ListingTextView.inWindow()
        view.open(fruitRows(3))
        expect(view.holdsKeys)
        window.press("\u{F701}", code: 125, modifiers: [.numericPad, .function])
        expectEqual(view.listWindow?.list.highlighted, 1)
        window.pressReturn()
        expectEqual(view.picks, [1])
        expect(view.caretListWindow == nil && !view.holdsKeys, "the pick closed it")
        expectEqual(view.string, "apple banana cherry", "Return was the list's")
        view.open(fruitRows(3))
        window.press("\t", code: 48)
        expectEqual(view.picks, [1, 0], "Tab picks too")
        view.open(fruitRows(3))
        window.pressEscape()
        expect(view.caretListWindow == nil)
        view.open(fruitRows(3))
        window.pressCommandPeriod()
        expect(view.caretListWindow == nil, "⌘. closes it, as Escape does")
        expectEqual(view.closes, 4)
        expect(window.firstResponder === view)
        view.open([.header("Fruit")])
        window.pressReturn()
        expectEqual(view.picks, [1, 0], "nothing to pick: Return isn't the list's")
        expectEqual(view.string, "apple\n banana cherry")
        view.close()
        window.pressReturn()
        expectEqual(view.string, "apple\n\n banana cherry", "closed: a new line")
    },

    test("⌘↩, where the text commits, closes any caret list and commits, as a key and as a key equivalent; with no commit, it's the list's") {
        let (window, view) = ListingTextView.inWindow()
        var commits = 0
        view.onCommit = { commits += 1 }
        view.open(fruitRows(3))
        window.press("\r", code: 36, modifiers: .command)
        expect(view.caretListWindow == nil && !view.holdsKeys, "closed")
        expectEqual(commits, 1)
        expectEqual(view.picks, [], "nothing picked")
        view.open(fruitRows(3))
        expect(view.performKeyEquivalent(with: window.keyEvent("\r", code: 36, modifiers: .command)), "taken before the menus")
        expect(view.caretListWindow == nil)
        expectEqual(commits, 2)
        expectEqual(view.string, "apple banana cherry", "no new line")
        view.onCommit = nil
        view.open(fruitRows(3))
        expect(!view.performKeyEquivalent(with: window.keyEvent("\r", code: 36, modifiers: .command)))
        expect(view.caretListWindow != nil, "on the canvas, where nothing commits, the list keeps it")
        view.close()
    },

    test("a subclass's list closes as the keyboard leaves the view, as it's made read-only, and as it leaves its window") {
        let (window, view) = ListingTextView.inWindow()
        view.open(fruitRows(3))
        window.makeFirstResponder(nil)
        expect(view.caretListWindow == nil, "the keyboard left")
        window.makeFirstResponder(view)
        view.open(fruitRows(3))
        view.isEditable = false
        expect(view.caretListWindow == nil, "read-only")
        view.isEditable = true
        view.open(fruitRows(3))
        view.removeFromSuperview()
        expect(view.caretListWindow == nil, "out of its window")
        expectEqual(view.closes, 3)
        expectEqual(window.childWindows ?? [], [])
    },

    test("a title in a font of its own sets its matched characters in that font's semibold") {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = ListedText()
        text.open([.item(CaretListItem("kiwi")), .item(CaretListItem("mmmmmmmm", font: font)),
                   .item(CaretListItem("mmmmmmmm", matched: [0..<8], font: font))])
        let rows = try require(text.rowsView)
        let rep = try require(rows.bitmapImageRepForCachingDisplay(in: rows.bounds))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rows.cacheDisplay(in: rows.bounds, to: rep) }
        /// How much ink a row's title leaves: its pixels' coverage, dark on nothing.
        @MainActor func ink(row: Int) -> CGFloat {
            let scale = CGFloat(rep.pixelsWide) / rows.bounds.width
            var total: CGFloat = 0
            for y in Int(CGFloat(row * 20) * scale)..<Int(CGFloat(row * 20 + 20) * scale) {
                for x in Int(10 * scale)..<Int(90 * scale) { total += rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
            }
            return total
        }
        expect(ink(row: 1) > 0)
        expect(ink(row: 2) > ink(row: 1) * 1.1, "semibold: \(ink(row: 2)) against \(ink(row: 1))")
    },
])

// MARK: Chip rows

/// The color of a rows view's pixel at a point in its bounds, drawn in either appearance, in sRGB.
@MainActor private func colors(of view: NSView, dark: Bool = false) throws -> (Int, Int) -> NSColor? {
    let rep = try require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
    return { x, y in rep.colorAt(x: x * rep.pixelsWide / Int(view.bounds.width), y: y * rep.pixelsHigh / Int(view.bounds.height))?.usingColorSpace(.sRGB) }
}

private let chipBlue = NSColor(srgbRed: 0.172, green: 0.447, blue: 0.860, alpha: 1)

/// A view filled with one color, drawn as the rows' view is: what a chip's color reads as in this window
/// (its bitmap has its own color space), the rows' view drawn in the same capture.
private final class SwatchView: NSView {
    let color: NSColor
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: CGRect(x: 120, y: 0, width: 20, height: 20))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

/// Puts a swatch of `chipBlue` in a rows view, at (130, 10) in its bounds, past the rows' text.
@MainActor private func addSwatch(to rows: NSView) { rows.addSubview(SwatchView(chipBlue)) }
private let swatchSpot = (x: 130, y: 10)

/// How white a color is: its darkest channel, 0 for none.
private func whiteness(_ color: NSColor?) -> CGFloat {
    guard let c = color?.usingColorSpace(.sRGB), c.alphaComponent > 0.95 else { return 0 }
    return min(c.redComponent, c.greenComponent, c.blueComponent)
}

/// Whether a color is `expected`, opaque, to a few levels.
private func isColor(_ color: NSColor?, _ expected: NSColor) -> Bool {
    guard let c = color?.usingColorSpace(.sRGB), let e = expected.usingColorSpace(.sRGB), c.alphaComponent > 0.97 else { return false }
    return abs(c.redComponent - e.redComponent) < 0.02 && abs(c.greenComponent - e.greenComponent) < 0.02 && abs(c.blueComponent - e.blueComponent) < 0.02
}

@MainActor let chipRowTests = Suite("Caret list chip rows", [
    test("a chip row is its title in a capsule of its color, white text, and its symbol inside it; in both appearances") {
        for dark in [false, true] {
            let text = ListedText()
            text.open([.item(CaretListItem("Person", symbol: "curlybraces", chip: chipBlue)), .item(CaretListItem("Company", chip: chipBlue)), .item(CaretListItem("plain"))])
            let rows = try require(text.rowsView)
            addSwatch(to: rows)
            let color = try colors(of: rows, dark: dark)
            // The capsule: its color left of the text, 16 points tall in a 20-point row; the row's far end isn't.
            let blue = try require(color(swatchSpot.x, swatchSpot.y))
            expect(isColor(color(16, 10), blue), "the capsule's color, dark \(dark): \(String(describing: color(16, 10)))")
            expect(isColor(color(16, 22), blue), "and a chip with no symbol")
            let column = (0..<20).filter { isColor(color(16, $0), blue) }
            expectEqual(column.count, 16, "the capsule is the row less two points above and below, dark \(dark)")
            expect(!isColor(color(200, 10), blue), "not the whole row")
            // White text inside it.
            let whites = (24..<80).reduce(0) { total, x in total + (0..<20).filter { y in whiteness(color(x, y)) > 0.95 }.count }
            expect(whites > 15, "white text: \(whites)")
        }
    },

    test("a chip row's symbol is inside the capsule: the capsule is wider by its place, and the symbol is white") {
        let text = ListedText()
        text.open([.item(CaretListItem("Person", symbol: "curlybraces", chip: chipBlue)), .item(CaretListItem("Person", chip: chipBlue))])
        let rows = try require(text.rowsView)
        addSwatch(to: rows)
        let color = try colors(of: rows), blue = try require(try colors(of: rows)(swatchSpot.x, swatchSpot.y))
        func end(row: Int) -> Int { (0..<115).last { isColor(color($0, row * 20 + 3), blue) || isColor(color($0, row * 20 + 10), blue) } ?? 0 }
        expect(end(row: 0) - end(row: 1) >= 10, "wider by the symbol and its gap: \(end(row: 0)), \(end(row: 1))")
        let symbolWhites = (20..<30).reduce(0) { total, x in total + (0..<20).filter { y in whiteness(color(x, y)) > 0.9 }.count }
        expect(symbolWhites > 4, "the symbol is white: \(symbolWhites)")
    },

    test("a highlighted chip row is a pale fill behind its capsule, not the accent with white text; a row without a chip is filled as before") {
        let text = ListedText()
        text.open([.item(CaretListItem("Person", chip: chipBlue)), .item(CaretListItem("Company", chip: chipBlue)), .item(CaretListItem("plain"))])
        let rows = try require(text.rowsView)
        addSwatch(to: rows)
        for dark in [false, true] {
            let color = try colors(of: rows, dark: dark)
            let pale = try require(color(200, 10)), none = color(200, 30)
            expect(pale.alphaComponent > 0.05 && pale.alphaComponent < 0.3, "pale: \(pale.alphaComponent), dark \(dark)")
            expect((none?.alphaComponent ?? 0) == 0, "the next chip row isn't")
            expect(isColor(color(16, 10), try require(color(swatchSpot.x, swatchSpot.y))), "the capsule over it keeps its color")
        }
        text.list?.moveHighlight(by: -1)
        let plain = try require(try colors(of: rows)(200, 50))
        expect(plain.alphaComponent > 0.9, "a row without a chip is filled with the accent: \(plain.alphaComponent)")
        text.list?.moveHighlight(by: 1)
        expect((try colors(of: rows)(200, 50)?.alphaComponent ?? 0) == 0, "and not once it isn't highlighted")
    },

    test("a chip row is said as its title, its detail after; its matched letters are semibold in the capsule") {
        let text = ListedText()
        text.open([.item(CaretListItem("Person", symbol: "curlybraces", detail: "type", chip: chipBlue)), .item(CaretListItem("Person", matched: [0..<3], chip: chipBlue))])
        let rows = try require(text.rowsView)
        addSwatch(to: rows)
        let spoken = (rows.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        expectEqual(spoken, ["Person, type", "Person"])
        text.open([.item(CaretListItem("Mmmmmm", chip: chipBlue)), .item(CaretListItem("Mmmmmm", matched: [0..<6], chip: chipBlue))])
        let again = try require(text.rowsView)
        addSwatch(to: again)
        let color = try colors(of: again), blue = try require(color(swatchSpot.x, swatchSpot.y))
        func end(row: Int) -> Int { (0..<115).last { isColor(color($0, row * 20 + 3), blue) || isColor(color($0, row * 20 + 10), blue) } ?? 0 }
        expect(end(row: 1) > end(row: 0), "semibold is wider: \(end(row: 1)), \(end(row: 0))")
    },
])
