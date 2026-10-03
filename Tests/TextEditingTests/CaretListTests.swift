import AppKit
import CanvasTesting
import TestKit
import TextEditing

// Every caret list's pieces, without an owner of the app's: the model (rows, the highlight, the
// keys), the matcher both lists rank typed text with, and the window over a text view in an
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

    // MARK: The matcher

    test("the matcher's tiers, with the characters matched, case and diacritics ignored") {
        expectEqual(CaretListMatcher.match("grocery list", in: "Grocery List"), CaretListMatch(score: CaretListRanking.exact, matched: [0..<12]))
        expectEqual(CaretListMatcher.match("groc", in: "Grocery List"), CaretListMatch(score: CaretListRanking.prefix, matched: [0..<4]))
        expectEqual(CaretListMatcher.match("gro li", in: "Grocery List"), CaretListMatch(score: CaretListRanking.wordPrefixes, matched: [0..<3, 8..<10]))
        expectEqual(CaretListMatcher.match("cery", in: "Grocery List"), CaretListMatch(score: CaretListRanking.substring, matched: [3..<7]))
        let subsequence = try require(CaretListMatcher.match("grcy", in: "Grocery List"))
        expect(subsequence.score > CaretListRanking.typo && subsequence.score <= CaretListRanking.subsequence)
        expectEqual(CaretListMatcher.match("gorcery", in: "Grocery List"), CaretListMatch(score: CaretListRanking.typo, matched: [0..<7]))
        expectEqual(CaretListMatcher.match("CAFÉ", in: "cafe")?.score, CaretListRanking.exact)
        expectEqual(CaretListMatcher.match("zebra", in: "Grocery List"), nil)
        expectEqual(CaretListMatcher.match(" ", in: "Grocery List"), nil)
    },

    test("a list's matches: each label's best tier, the typo's only when the others found fewer than 8") {
        let found = CaretListMatcher.matches("app", in: ["apple", "pineapple", "banana", "Apricot pie"])
        expectEqual(found.prefix(3).map { $0?.score }, [CaretListRanking.prefix, CaretListRanking.substring, nil])
        expectEqual(found[0]?.matched, [0..<3])
        let subsequence = try require(found[3])
        expect(subsequence.score > CaretListRanking.typo && subsequence.score <= CaretListRanking.subsequence, "\(subsequence.score)")
        expectEqual(CaretListMatcher.matches("", in: ["apple", "fig"]).map { $0 == nil }, [true, true], "an empty query matches nothing")
        // "mnago" is "mango" with two letters swapped: a typo, found while few others match.
        expectEqual(CaretListMatcher.matches("mnago", in: ["mango", "melon"]).map { $0?.score }, [CaretListRanking.typo, nil])
        let many = Array(repeating: "mn a g o", count: 8) + ["mango"]
        let crowded = CaretListMatcher.matches("mnago", in: many)
        expectEqual(crowded.prefix(8).compactMap { $0 }.count, 8, "subsequences")
        expectEqual(crowded[8]?.score, nil, "eight found above it: the typo's tier isn't tried")
    },

    test("rank: the tiers over every label a list gives, then the typo's over those left, for a query of four or more") {
        let labels = ["mango", "melon", "mnago pie", "mango", "kiwi"]
        var keys: [UInt32] = [], starts = [0]
        for label in labels {
            _ = CaretListMatcher.appendKeys(of: label, to: &keys)
            starts.append(keys.count)
        }
        @MainActor func ranked(_ query: String, passingOver skipped: Set<Int> = []) -> [(index: Int, score: Int)] {
            var found: [(index: Int, score: Int)] = []
            CaretListMatcher.Query(query).withView { q in
                keys.withUnsafeBufferPointer { keys in
                    CaretListMatcher.rank(q, count: labels.count, wantSpans: false, label: { i in
                        skipped.contains(i) ? nil : UnsafeBufferPointer(rebasing: keys[starts[i]..<starts[i + 1]])
                    }) { index, score, spans in
                        expect(spans.isEmpty, "no spans unless asked")
                        found.append((index, score))
                    }
                }
            }
            return found
        }
        let mnago = ranked("mnago")
        expectEqual(mnago.map(\.index), [2, 0, 3], "the prefix in the first pass, then the typos in the second")
        expectEqual(mnago.map(\.score), [CaretListRanking.prefix, CaretListRanking.typo, CaretListRanking.typo])
        expectEqual(ranked("mnago", passingOver: [0, 2]).map(\.index), [3], "a label the list leaves out is never matched")
        expectEqual(ranked("mna").map(\.index), [2], "under four characters, no typo's pass (mango would be one)")
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
