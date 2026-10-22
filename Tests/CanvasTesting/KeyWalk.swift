import AppKit
@_spi(Host) import Canvas
import TestKit

// The keyboard-navigation principles as checks (.claude/rules/keyboard-navigation.md): a walk
// presses real keys (`KeyDriver`) in a window, reads where the keyboard went after each (`Focus`,
// through the rig's readers, then AppKit's), and holds the surface to P3 (every stop once, in
// order, wrapping, no trap), P4 (the opposite key undoes each step), P5 (Escape one level at a
// time, keeping what was typed), P7 (the stop shows and is in view), P8 (a key with no use there
// changes no document, and Tab and Escape still move) and P9 (a role and a label). Its presses are
// counted (P12). A failure prints the walk so far: "Tab -> note/A/words, Tab -> note/A/price, …".

@MainActor
public final class KeyWalk {
    /// What runs after every key, so what it set off has landed before the focus is read: the run
    /// loop's turns (`NSWindow.settle`, SwiftUI and the views' own next-turn work), a manual
    /// scheduler's due actions (`EditorHarness`'s clock), or both.
    public enum Settling {
        case none
        case runLoop
        case manual(ManualScheduler)
        case both(ManualScheduler)
    }

    /// What the forward key does at the last stop: comes round to the first, stays (a list's last
    /// row), or leaves for a stop outside the cycle.
    public enum Wrap {
        case closed
        case stays
        case leaves(to: String)
    }

    /// The stops a walk went through, in order.
    public struct Cycle {
        public let stops: [Focus]
        public var ids: [String] { stops.map(\.id) }
    }

    public let window: NSWindow
    public let editor: CanvasEditor?
    public let driver: KeyDriver
    public let readers: [any FocusReader]
    public let settling: Settling
    public let sealsOnOwnerChange: Bool
    /// macOS's Keyboard navigation setting (System Settings › Keyboard), as it is for this run: with it
    /// off, AppKit's key view loop skips standard controls (buttons, checkboxes, pop-ups).
    public let keyboardNavigation = NSApplication.shared.isFullKeyboardAccessEnabled
    /// The stops that are standard controls, which a cycle expects only with Keyboard navigation on;
    /// with it off they're left out of what it expects and listed in `skipped`, not failed.
    public var standardControls: Set<String> = []
    /// The standard controls a cycle left out, Keyboard navigation being off.
    public private(set) var skipped: [String] = []
    /// Known P9 gaps, each "surface: reason, violation id": a stop of that surface may lack a role or
    /// a label. An entry fails once every stop of its surface a check sees has both.
    public var pending: [String] = []
    /// Every key pressed (P12 counts them).
    public private(set) var presses: [Chord] = []
    /// "Tab -> canvas/A", one per key pressed.
    public private(set) var trace: [String] = []

    /// `readers` are asked in order, then AppKit's (`AppKitFocusReader`). `sealsOnOwnerChange`: the
    /// editor's undo history is sealed when a key moves the first responder (a field's editor
    /// standing for its field), as a board's window seals it, so steps end where they do in the app
    /// (sealing is idempotent: a board's window sealing it too changes nothing).
    public init(_ window: NSWindow, editor: CanvasEditor? = nil, menu: NSMenu? = nil, readers: [any FocusReader] = [],
                settle: Settling = .runLoop, sealsOnOwnerChange: Bool = true) {
        self.window = window
        self.editor = editor
        self.driver = KeyDriver(window, menu: menu)
        self.readers = readers + [AppKitFocusReader()]
        self.settling = settle
        self.sealsOnOwnerChange = sealsOnOwnerChange
    }

    /// Where the keyboard is now.
    public var focus: Focus {
        for reader in readers { if let focus = reader.read(window) { return focus } }
        return Focus(surface: "window", element: "")
    }

    /// The walk so far, as a failure prints it.
    public var traceText: String { trace.joined(separator: ", ") }

    // MARK: Pressing

    /// Presses `chord` (`times` times, each after the first a repeat, as a held key sends), settling
    /// after each; returns where the keyboard is then.
    @discardableResult
    public func press(_ chord: Chord, times: Int = 1) -> Focus {
        for index in 0..<max(1, times) {
            let owner = keyboardOwner
            driver.send(chord, repeating: index > 0)
            settle()
            if sealsOnOwnerChange, keyboardOwner !== owner { editor?.undoHistory.seal() }
            presses.append(chord)
            trace.append("\(chord) -> \(focus.id)")
        }
        return focus
    }

    /// Presses `forward` until the keyboard is at `id`, at most 200 times; fails if it never gets there.
    public func go(_ id: String, by forward: Chord = .tab, file: StaticString = #fileID, line: UInt = #line) {
        var left = 200
        while focus.id != id {
            guard left > 0 else { return fail("\(forward) never reaches \(id)", file: file, line: line) }
            press(forward)
            left -= 1
        }
    }

    // MARK: P3 and P4

    /// From the first of `ids`, `forward` visits each in order and then does what `wraps` says; at
    /// every stop `back` returns to the one before and `forward` comes back (P4). A press that stays
    /// put is a trap. Gives up at the first wrong step, with the trace.
    @discardableResult
    public func expectCycle(_ ids: [String], wraps: Wrap = .closed, forward: Chord = .tab, back: Chord = .backTab,
                            file: StaticString = #fileID, line: UInt = #line) -> Cycle {
        let expected = expecting(ids)
        guard let first = expected.first else { return Cycle(stops: []) }
        guard expected.count <= 200 else {
            fail("a cycle of \(expected.count) stops: a walk gives up after 200", file: file, line: line)
            return Cycle(stops: [])
        }
        var stops = [focus]
        guard stops[0].id == first else {
            fail("the walk starts at \(stops[0].id), not \(first)", file: file, line: line)
            return Cycle(stops: stops)
        }
        for next in expected.dropFirst() {
            let before = focus
            guard step(forward, from: before, to: next, file: file, line: line), inverse(back, forward, of: before, file: file, line: line) else {
                return Cycle(stops: stops)
            }
            stops.append(focus)
        }
        let last = focus
        switch wraps {
        case .closed:
            if step(forward, from: last, to: first, what: "come round to", file: file, line: line) {
                _ = inverse(back, forward, of: last, file: file, line: line)
            }
        case .stays:
            let after = press(forward)
            if after.id != last.id { fail("\(forward) at the last stop, \(last.id), goes on to \(after.id)", file: file, line: line) }
        case .leaves(let outside):
            if step(forward, from: last, to: outside, what: "leave for", file: file, line: line) {
                _ = inverse(back, forward, of: last, file: file, line: line)
            }
        }
        return Cycle(stops: stops)
    }

    /// From where the keyboard is, `forward` until it comes round (or stays, or leaves, as `wraps`
    /// says), at most 200 presses: no stop twice, `ids` among the stops in that order, and `back`
    /// undoing each step. For a surface with more stops than a test names (a long panel).
    @discardableResult
    public func expectCycle(inOrder ids: [String], wraps: Wrap = .closed, forward: Chord = .tab, back: Chord = .backTab,
                            file: StaticString = #fileID, line: UInt = #line) -> Cycle {
        let start = focus
        var stops = [start], ended = false
        for _ in 0..<200 {
            let before = focus
            let now = press(forward)
            if case .stays = wraps, now.id == before.id {
                ended = true
                break
            }
            guard now.id != before.id else {
                fail("trap: \(forward) at \(before.id) stays there", file: file, line: line)
                return Cycle(stops: stops)
            }
            guard inverse(back, forward, of: before, file: file, line: line) else { return Cycle(stops: stops) }
            if case .leaves(let outside) = wraps, now.id == outside {
                ended = true
                break
            }
            if now.id == start.id, case .closed = wraps {
                ended = true
                break
            }
            if let seen = stops.firstIndex(where: { $0.id == now.id }) {
                fail("\(now.id) comes round again after \(stops.count - seen) stops, before \(start.id)", file: file, line: line)
                return Cycle(stops: stops)
            }
            stops.append(now)
        }
        if !ended { fail("\(forward) doesn't come round to \(start.id) within 200 presses", file: file, line: line) }
        let visited = stops.map(\.id)
        var rest = visited[...]
        for id in expecting(ids) {
            guard let found = rest.firstIndex(of: id) else {
                fail("\(id) isn't among the stops after the ones before it: \(visited)", file: file, line: line)
                break
            }
            rest = rest[(found + 1)...]
        }
        return Cycle(stops: stops)
    }

    /// `down` steps through `over` from its first, and `up` undoes each step: a list or a column.
    /// At the end it stays, unless `wraps` says.
    @discardableResult
    public func expectAxis(down: Chord, up: Chord, over ids: [String], wraps: Wrap = .stays,
                           file: StaticString = #fileID, line: UInt = #line) -> Cycle {
        expectCycle(ids, wraps: wraps, forward: down, back: up, file: file, line: line)
    }

    // MARK: P5

    /// Escape once for each of `ids`, landing on each in turn: the container of the last, one level
    /// at a time. `keepsTyped`: text that must still be there after (in the board, or a view's text).
    public func expectEscapeLadder(_ ids: [String], keepsTyped typed: String? = nil, file: StaticString = #fileID, line: UInt = #line) {
        for id in ids {
            let before = focus
            let after = press(.escape)
            guard after.id == id else { return fail("Escape at \(before.id) goes to \(after.id), not \(id)", file: file, line: line) }
        }
        if let typed, !holds(typed) { fail("what was typed, \(typed.debugDescription), is gone", file: file, line: line) }
    }

    // MARK: P8

    /// At each stop: each of `keys` changes nothing on the board (its revision, the tool, what is
    /// being edited), and then Tab and, when `escapes`, Escape still move the keyboard. The walk gets back
    /// to each stop with `forward` (⌥Tab for a shape's parts, which Tab steps out of).
    public func expectInert(_ keys: [Chord] = Chord.inert, at stops: [Focus], escapes: Bool = true, by forward: Chord = .tab,
                            editorless: Bool = false, file: StaticString = #fileID, line: UInt = #line) {
        // A walk with no editor compares nil to nil: it checks nothing, unless the test says that is all it has.
        if editor == nil, !editorless { return fail("expectInert needs the walk's editor to see a change in the board", file: file, line: line) }
        for stop in stops {
            go(stop.id, by: forward, file: file, line: line)
            guard focus.id == stop.id else { continue }
            for key in keys {
                let revision = editor?.revision, tool = editor?.currentToolID, editing = editor?.editingShapeID
                press(key)
                if editor?.revision != revision { fail("\(key) at \(stop.id) changed the board", file: file, line: line) }
                if editor?.currentToolID != tool { fail("\(key) at \(stop.id) changed the tool", file: file, line: line) }
                if editor?.editingShapeID != editing { fail("\(key) at \(stop.id) changed what is being edited", file: file, line: line) }
                if focus.id != stop.id { go(stop.id, by: forward, file: file, line: line) }
            }
            if press(.tab).id == stop.id { fail("trap: Tab at \(stop.id) stays there", file: file, line: line) }
            if focus.id != stop.id { press(.backTab) }
            if focus.id != stop.id { go(stop.id, by: forward, file: file, line: line) }
            if escapes {
                if press(.escape).id == stop.id { fail("trap: Escape at \(stop.id) stays there", file: file, line: line) }
                go(stop.id, by: forward, file: file, line: line)
            }
        }
    }

    // MARK: P7 and P9

    /// At each stop: it is drawn with its mark and is in the window's view (P7), and it has an
    /// accessibility role and label (P9), unless `pending` names its surface. The walk gets to each stop
    /// with `forward`.
    public func expectShows(_ stops: [Focus], by forward: Chord = .tab, file: StaticString = #fileID, line: UInt = #line) {
        var unnamed: Set<String> = [], seen: Set<String> = []
        let content = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
        for stop in stops {
            go(stop.id, by: forward, file: file, line: line)
            let now = focus
            guard now.id == stop.id else { continue }
            if !now.isMarked { fail("\(now.id) shows no mark", file: file, line: line) }
            if let frame = now.frame, frame.isEmpty || !frame.intersects(content) {
                fail("\(now.id) isn't in view (\(frame), the window's view is \(content))", file: file, line: line)
            }
            seen.insert(now.surface)
            let named = !(now.role ?? "").isEmpty && !(now.label ?? "").isEmpty
            if !named {
                if pendingEntry(for: now.surface) != nil { unnamed.insert(now.surface) } else {
                    fail("\(now.id) has no accessibility \((now.role ?? "").isEmpty ? "role" : "label")", file: file, line: line)
                }
            }
        }
        for surface in seen.subtracting(unnamed) {
            if let entry = pendingEntry(for: surface) {
                fail("pending \"\(entry)\" passes now: take it off the list", file: file, line: line)
            }
        }
    }

    // MARK: P1, P2 and P10: a census's gaps

    /// What a census found pointer-only ("TypeChip “+2” button on Budget (Note): no part or command"): each fails
    /// unless an entry of `pending` starts with it ("<gap>, <slice id>": the slice that closes it), and an entry
    /// no gap starts fails too, so it goes once its gap is closed. A census's walk holds only its own entries.
    public func expectGaps(_ gaps: [String], file: StaticString = #fileID, line: UInt = #line) {
        for gap in gaps where !pending.contains(where: { $0.hasPrefix(gap) }) {
            expect(false, "\(gap)", file: file, line: line)
        }
        for entry in pending where !gaps.contains(where: { entry.hasPrefix($0) }) {
            expect(false, "pending \"\(entry)\" passes now: take it off the list", file: file, line: line)
        }
    }

    // MARK: Helpers

    private func pendingEntry(for surface: String) -> String? {
        pending.first { $0.split(separator: ":", maxSplits: 1).first.map(String.init) == surface }
    }

    /// `ids` less the standard controls, when Keyboard navigation is off (those go to `skipped`).
    private func expecting(_ ids: [String]) -> [String] {
        guard !keyboardNavigation else { return ids }
        let left = ids.filter { !standardControls.contains($0) }
        skipped += ids.filter { standardControls.contains($0) && !skipped.contains($0) }
        return left
    }

    /// `chord` from `before` lands on `id`; else fails ("goes to X, not Y", or a trap).
    private func step(_ chord: Chord, from before: Focus, to id: String, what: String = "go to", file: StaticString, line: UInt) -> Bool {
        let now = press(chord)
        if now.id == before.id, id != before.id {
            fail("trap: \(chord) at \(before.id) stays there", file: file, line: line)
            return false
        }
        guard now.id == id else {
            fail("\(chord) from \(before.id) goes to \(now.id); it should \(what) \(id)", file: file, line: line)
            return false
        }
        return true
    }

    /// `back` returns to `before`, and `forward` again to where the keyboard is (P4).
    private func inverse(_ back: Chord, _ forward: Chord, of before: Focus, file: StaticString, line: UInt) -> Bool {
        let here = focus
        let returned = press(back)
        guard returned.id == before.id else {
            fail("\(back) from \(here.id) goes to \(returned.id), not back to \(before.id)", file: file, line: line)
            return false
        }
        let again = press(forward)
        guard again.id == here.id else {
            fail("\(forward) from \(before.id) goes to \(again.id) the second time, not \(here.id)", file: file, line: line)
            return false
        }
        return true
    }

    private func fail(_ message: String, file: StaticString, line: UInt) {
        expect(false, "\(message)\n       walk: \(traceText)", file: file, line: line)
    }

    /// Settles once, then again while where the keyboard is keeps changing (up to 20 more times): work
    /// that lands a turn later (a panel's hand-off of focus, retried every 20 ms) is waited for by what
    /// it did, not by a fixed number of turns, so a loaded machine reads the same focus.
    private func settle() {
        settleOnce()
        guard case .none = settling else {
            var seen = focus.id
            for _ in 0..<20 {
                settleOnce()
                let now = focus.id
                if now == seen { return }
                seen = now
            }
            return
        }
    }

    private func settleOnce() {
        switch settling {
        case .none: break
        case .runLoop: window.settle()
        case .manual(let scheduler): scheduler.advance(by: .zero)
        case .both(let scheduler):
            scheduler.advance(by: .zero)
            window.settle()
            scheduler.advance(by: .zero)
        }
    }

    /// What has the keyboard as someone sees it: a field, for its editor.
    private var keyboardOwner: AnyObject? {
        let responder = window.firstResponder
        if let text = responder as? NSTextView, text.isFieldEditor, let field = text.delegate { return field }
        return responder
    }

    /// Whether `text` is on the board or in a text view of the window.
    private func holds(_ text: String) -> Bool {
        if let editor, String(describing: editor.document).contains(text) { return true }
        let views = window.contentView.map { [$0] + $0.descendants } ?? []
        if views.contains(where: { ($0 as? NSText)?.string.contains(text) == true || ($0 as? NSTextField)?.stringValue.contains(text) == true }) {
            return true
        }
        return (window.fieldEditor(false, for: nil) as? NSTextView)?.string.contains(text) == true || focus.value?.contains(text) == true
    }
}
