import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import Selection
import TestKit
import TextEditing
import Titles

// The mention text view, as a jot's editor, in an unshown window: typing, the picker's keys, pills
// clicked, copied and pasted, read aloud, and kept in step with their targets. Nothing goes on
// screen, and the pasteboards are private.

/// A jot being edited: its editing view (a `MentionTextView`) in an unshown window, where the
/// canvas would put it, the keyboard in its text. The board has two plates ("Groceries", idA, and
/// "Grocery List", idB), one above the other, "Groceries" a little nearer the jot.
@MainActor
final class EditedJot {
    let h: EditorHarness
    let jot: ShapeID
    let window: NSWindow
    let canvas: FlippedCanvas
    let editing: NSView
    let textView: MentionTextView<AnyMentionable>

    init(_ text: MentionText = "", plugins more: [any CanvasPlugin] = [], board: (CanvasEditor) -> Void = { _ in }) throws {
        h = try mentionHarness(more)
        h.editor.add(Plate(CGRect(x: 300, y: 0, width: 120, height: 80)), titled: "Groceries", id: idA)
        h.editor.add(Plate(CGRect(x: 300, y: 140, width: 120, height: 80)), titled: "Grocery List", id: idB)
        board(h.editor)
        jot = h.editor.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: text), titled: nil)
        h.editor.selection = jot
        expect(h.editor.beginEditing(jot))
        let view = try require(h.editor.makeEditingView())
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        canvas = FlippedCanvas(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = canvas
        editing = view.view
        editing.frame = CGRect(x: 100, y: 100, width: 200, height: 200)
        canvas.addSubview(editing)
        textView = try require(view.firstResponder as? MentionTextView<AnyMentionable>)
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
    }

    /// The jot's text on the board: what the editor last committed.
    var committed: MentionText? { h.editor.document[jot]?.typed(as: Jot.self)?.props.text }
    var storage: NSTextStorage { textView.textStorage! }
    var string: String { storage.string }

    /// The pills in the text, with their characters' indexes.
    var pills: [(location: Int, pill: MentionAttachment)] {
        var found: [(Int, MentionAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let pill = value as? MentionAttachment { found.append((range.location, pill)) }
        }
        return found
    }

    func type(_ text: String) { window.type(text) }
    func down() { window.press("\u{F701}", code: 125, modifiers: [.numericPad, .function]) }
    func up() { window.press("\u{F700}", code: 126, modifiers: [.numericPad, .function]) }
    func left() { window.press("\u{F702}", code: 123, modifiers: [.numericPad, .function]) }
    func right() { window.press("\u{F703}", code: 124, modifiers: [.numericPad, .function]) }
    func tab() { window.press("\t", code: 48) }
    func control(_ letter: String, code: UInt16) {
        let scalar = Unicode.Scalar(letter.unicodeScalars.first!.value - 0x60)!
        window.sendEvent(window.keyEvent(String(Character(scalar)), ignoringModifiers: letter, code: code, modifiers: .control))
    }

    /// The middle of the character at `location`, in the text view.
    func point(of location: Int) -> CGPoint {
        let screen = textView.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil)
        let rect = textView.convert(window.convertFromScreen(screen), from: nil)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private var time: TimeInterval = 10

    func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        time += 0.05
        return NSEvent.mouseEvent(with: type, location: textView.convert(point, to: nil), modifierFlags: modifiers, timestamp: time,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func click(at point: CGPoint, clicks: Int = 1) {
        textView.mouseDown(with: mouse(.leftMouseDown, at: point, clicks: clicks))
    }

    /// A press on the text view, dragged a little, and let go, as AppKit sends them.
    func pressAndRelease(at point: CGPoint, clicks: Int = 1) {
        click(at: point, clicks: clicks)
        textView.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: point.x + 1, y: point.y), clicks: clicks))
        textView.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: point.x + 1, y: point.y), clicks: clicks))
    }

    func moveMouse(to point: CGPoint) {
        textView.mouseMoved(with: mouse(.mouseMoved, at: point, clicks: 0))
    }

    /// Picks, from the picker opened by typing `@` and `query`, the row the highlight reaches after
    /// `downs` presses of ↓.
    func pick(_ query: String, downs: Int = 0) {
        type("@" + query)
        for _ in 0..<downs { down() }
        window.pressReturn()
    }

    var pickerTargets: [ShapeID] { textView.picker?.rows.compactMap(\.candidate?.id) ?? [] }
    var highlighted: ShapeID? { textView.picker?.highlightedCandidate?.id }
}

/// The canvas's place for the editing view: flipped, as `CanvasView` is. It counts the mouse
/// events that reach it through the text view, as a canvas would hear them.
final class FlippedCanvas: NSView {
    override var isFlipped: Bool { true }
    var heard: [NSEvent.EventType] = []
    override func mouseDragged(with event: NSEvent) { heard.append(event.type) }
    override func mouseUp(with event: NSEvent) { heard.append(event.type) }
}

/// The host's side of a text view's delegate, as a note's editor has it.
final class RecordingHost: NSObject, NSTextViewDelegate {
    var changes = 0
    var commands: [Selector] = []

    func textDidChange(_ notification: Notification) { changes += 1 }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        commands.append(commandSelector)
        return commandSelector == #selector(NSResponder.cancelOperation(_:))
    }
}

/// Counts what's posted under a name while it's alive.
final class NotificationCount: @unchecked Sendable {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(_ name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.count += 1 }
    }

    deinit { token.map(NotificationCenter.default.removeObserver) }
}

@MainActor private let groceries = MentionText([.text("Buy "), .mention(idA, label: "Groceries"), .text(" today")])

@MainActor let textViewTests = Suite("Text view", [
    // MARK: Engine and delegate

    test("both initializers make a TextKit 2 view that keeps the host's delegate, and nothing switches it to TextKit 1") {
        let switches = NotificationCount(NSTextView.willSwitchToNSLayoutManagerNotification)
        let style = MentionTextStyle(font: .systemFont(ofSize: 16), color: .black, lineHeight: 19)
        let made = MentionTextView<AnyMentionable>(frame: CGRect(x: 0, y: 0, width: 200, height: 100), text: groceries, style: style,
                                                   owner: nil, mentions: nil)
        expect(made.textLayoutManager != nil)
        expect(!made.isRichText)
        expectEqual(made.textStorage?.length, 11)
        expectEqual(made.mentionText, groceries)

        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 200, height: 0))
        layout.textContainer = container
        let plain = MentionTextView<AnyMentionable>(frame: CGRect(x: 0, y: 0, width: 200, height: 100), textContainer: container)
        expect(plain.textLayoutManager === layout)
        expect(plain.style == nil)

        for view in [made, plain] {
            let host = RecordingHost()
            view.delegate = host
            expect(view.delegate === host, "the host reads back as the delegate")
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeFirstResponder(view)
            window.type("hi")
            window.pressEscape()
            expectEqual(host.changes, 2)
            expectEqual(host.commands, [#selector(NSResponder.cancelOperation(_:))])
            expect(view.textLayoutManager != nil)
        }

        let session = try EditedJot(groceries)
        session.type("x @gro")
        session.window.pressReturn()
        session.textView.selectPill(at: session.point(of: 4))
        _ = session.textView.accessibilityValue()
        expect(session.textView.textLayoutManager != nil)
        expectEqual(switches.count, 0)
    },

    test("the view's own delegate answers Writing Tools with the pills' ranges, and passes the rest to the host") {
        let session = try EditedJot(groceries)
        let own = try require(Mirror(reflecting: session.textView).children.first { $0.label == "forwarder" }?.value as? NSObject)
        expect(own !== session.textView.delegate as AnyObject?)
        expect(own.responds(to: #selector(NSTextViewDelegate.textDidChange(_:))), "the host's own methods show through it")
        expect(!own.responds(to: #selector(NSTextViewDelegate.textView(_:clickedOnLink:at:))))
        if #available(macOS 15.0, *) {
            let delegate = try require(own as? NSTextViewDelegate)
            let ranges = delegate.textView?(session.textView, writingToolsIgnoredRangesInEnclosingRange: NSRange(location: 0, length: 15))
            expectEqual(ranges?.map(\.rangeValue), [NSRange(location: 4, length: 1)])
        }
    },

    // MARK: Picking

    test("@gro, ↓, Return puts one pill and a space in the query's place, and the host commits the canonical form") {
        let session = try EditedJot("")
        session.type("Buy @gro")
        expectEqual(session.pickerTargets, [idA, idB])
        session.down()
        expectEqual(session.highlighted, idB)
        session.window.pressReturn()
        expect(session.textView.picker == nil)
        expectEqual(session.string, "Buy \u{FFFC} ")
        expectEqual(session.pills.map(\.location), [4])
        expectEqual(session.pills.first?.pill.target, idB)
        expectEqual(session.pills.first?.pill.widthLimit, 168, "no wider than the jot's line")
        expectEqual(session.textView.selectedRange(), NSRange(location: 6, length: 0))
        let expected = MentionText([.text("Buy "), .mention(idB, label: "Grocery List"), .text(" ")])
        expectEqual(session.textView.mentionText, expected)
        expectEqual(session.committed, expected)
        expectEqual(session.committed?.stored, "Buy @[Grocery List](shape:\(idB.rawValue.uuidString)) ")
    },

    test("a pick puts no space before punctuation or whitespace that follows, and the caret goes after the pill") {
        let session = try EditedJot(MentionText(plain: "See ."))
        session.textView.setSelectedRange(NSRange(location: 4, length: 0))
        session.pick("groceries")
        expectEqual(session.string, "See \u{FFFC}.")
        expectEqual(session.textView.selectedRange(), NSRange(location: 5, length: 0))
        let spaced = try EditedJot(MentionText(plain: "See  it"))
        spaced.textView.setSelectedRange(NSRange(location: 4, length: 0))
        spaced.pick("groc")
        expectEqual(spaced.string, "See \u{FFFC} it")
    },

    test("Tab picks too, and a pick is recent: first under Recent the next time") {
        let session = try EditedJot("")
        session.type("@grocery l")
        expectEqual(session.highlighted, idB)
        session.tab()
        expectEqual(session.pills.first?.pill.target, idB)
        session.type("@")
        let picker = try require(session.textView.picker)
        expectEqual(picker.rows.first, .header("Recent"))
        expectEqual(picker.rows[1].candidate?.id, idB)
    },

    test("Backspace deletes a pill whole, and text typed after a pill is plain text") {
        let session = try EditedJot(groceries)
        session.textView.setSelectedRange(NSRange(location: 5, length: 0))
        session.type("x")
        expectEqual(session.string, "Buy \u{FFFC}x today")
        expect(session.storage.attribute(.attachment, at: 5, effectiveRange: nil) == nil)
        expectEqual(session.committed, MentionText([.text("Buy "), .mention(idA, label: "Groceries"), .text("x today")]))
        session.window.pressDelete()
        session.window.pressDelete()
        expectEqual(session.string, "Buy  today")
        expectEqual(session.committed, MentionText(plain: "Buy  today"))
    },

    test("a selected pill is deleted by Delete and replaced by what's typed") {
        let session = try EditedJot(groceries)
        session.textView.setSelectedRange(NSRange(location: 4, length: 1))
        session.window.pressDelete()
        expectEqual(session.string, "Buy  today")
        let typed = try EditedJot(groceries)
        typed.textView.setSelectedRange(NSRange(location: 4, length: 1))
        typed.type("milk")
        expectEqual(typed.string, "Buy milk today")
        expect(typed.pills.isEmpty)
    },

    // MARK: When the picker opens and closes

    test("@ opens the picker where a word starts, and only when typed") {
        for (before, opens) in [("", true), ("see ", true), ("line\n", true), ("(", true), ("[", true), ("{", true), ("\"", true),
                                ("'", true), ("“", true), ("‘", true), ("name", false), ("a.", false), ("3", false)] {
            let session = try EditedJot(MentionText(plain: before))
            session.type("@")
            expectEqual(session.textView.picker != nil, opens, "after \(before.debugDescription)")
            expectEqual(session.textView.picker?.location, opens ? (before as NSString).length : nil)
        }

        // Pasted: never.
        let pasted = try EditedJot("")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("@", forType: .string)
        expect(pasted.textView.readSelection(from: board))
        expectEqual(pasted.string, "@")
        expect(pasted.textView.picker == nil)

        // Undone: never.
        let undone = try EditedJot("")
        undone.type("@")
        undone.window.pressEscape()
        undone.window.settle()
        undone.textView.breakUndoCoalescing()
        undone.window.pressDelete()
        undone.window.settle()
        expectEqual(undone.string, "")
        undone.textView.undoManager?.undo()
        expectEqual(undone.string, "@")
        expect(undone.textView.picker == nil)

        // While an input method composes: never.
        let composing = try EditedJot("")
        composing.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composing.textView.insertText("@", replacementRange: NSRange(location: NSNotFound, length: 0))
        expect(composing.textView.picker == nil)
    },

    test("the query is what's typed after the @, spaces and all; ← within it keeps the picker, past the @ closes it") {
        let session = try EditedJot("")
        session.type("@grocery li")
        let picker = try require(session.textView.picker)
        expectEqual(picker.query, "grocery li")
        expectEqual(session.pickerTargets, [idB])
        session.left()
        expectEqual(session.textView.picker?.query, "grocery l")
        session.right()
        expectEqual(session.textView.picker?.query, "grocery li")
        session.right()
        expect(session.textView.picker != nil, "at the end of the text, → goes nowhere")
        for _ in 0..<11 { session.left() }
        expect(session.textView.picker == nil, "the caret left the query")
        session.type("x")
        expect(session.textView.picker == nil)
    },

    test("the picker closes when the caret moves past the query, a selection is made, or the text is clicked elsewhere") {
        let past = try EditedJot(MentionText(plain: " after"))
        past.textView.setSelectedRange(NSRange(location: 0, length: 0))
        past.type("@gro")
        expect(past.textView.picker != nil)
        past.right()
        expect(past.textView.picker == nil)

        let selected = try EditedJot("")
        selected.type("@gro")
        selected.textView.setSelectedRange(NSRange(location: 1, length: 2))
        expect(selected.textView.picker == nil)
    },

    test("deleting the @, a line break, more than 80 characters, and a space after nothing matching each close the picker") {
        let deleted = try EditedJot("")
        deleted.type("@g")
        deleted.window.pressDelete()
        expect(deleted.textView.picker != nil)
        deleted.window.pressDelete()
        expect(deleted.textView.picker == nil)

        let newline = try EditedJot("")
        newline.type("@zzz")
        expectEqual(newline.textView.picker?.rows, [.empty("No matches")])
        newline.window.pressReturn()
        expectEqual(newline.string, "@zzz\n", "with nothing to pick, Return makes its line")
        expect(newline.textView.picker == nil)

        let long = try EditedJot("")
        long.type("@" + String(repeating: "q", count: TitleProperty.maxLength))
        expect(long.textView.picker != nil, "80 characters, a whole title")
        long.type("q")
        expect(long.textView.picker == nil, "81 characters")

        let space = try EditedJot("")
        space.type("@grocery ")
        expect(space.textView.picker != nil, "a space that still matches keeps it")
        let writing = try EditedJot("")
        writing.type("@me ")
        expect(writing.textView.picker == nil, "a space after nothing matching: the person was writing")
        expectEqual(writing.string, "@me ")
    },

    test("losing the keyboard, the window resigning key, and ⌥⎋ close the picker") {
        let keyboard = try EditedJot("")
        keyboard.type("@")
        keyboard.window.makeFirstResponder(nil)
        expect(keyboard.textView.picker == nil)

        let key = try EditedJot("")
        key.type("@")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: key.window)
        expect(key.textView.picker == nil)

        let complete = try EditedJot("")
        complete.type("@")
        complete.textView.doCommand(by: #selector(NSResponder.complete(_:)))
        expect(complete.textView.picker == nil)
        expectEqual(complete.string, "@")
    },

    test("the picker is its view's list at the caret, as every caret list is: its window while it's open, closed as the view is made read-only") {
        let session = try EditedJot("")
        session.type("@")
        let view: EditingTextView = session.textView
        let list = try require(view.caretListWindow, "the list open at its caret")
        expectEqual(list.frame, session.textView.pickerFrame)
        expectEqual(list.list.rows.count, session.textView.picker?.rows.count, "the picker's rows")
        expect(view.holdsKeys)
        view.isEditable = false
        expect(session.textView.picker == nil && view.caretListWindow == nil && !view.holdsKeys)
        view.isEditable = true
        session.type(" @")
        expect(view.caretListWindow != nil)
        session.window.pressEscape()
        expect(session.textView.picker == nil && view.caretListWindow == nil)
        expectEqual(session.string, "@ @")
    },

    test("Escape closes only the picker, and that @ stays closed; a second Escape reaches the host, which ends editing") {
        let session = try EditedJot("")
        session.type("@gro")
        session.window.pressEscape()
        expect(session.textView.picker == nil)
        expectEqual(session.h.editor.editingShapeID, session.jot)
        expectEqual(session.string, "@gro")
        session.type("c")
        expect(session.textView.picker == nil, "only a new @ opens it")
        session.window.pressEscape()
        expectEqual(session.h.editor.editingShapeID, nil)
    },

    test("spelling correction, text replacement and smart quotes and dashes are off while the picker is open, and put back") {
        let session = try EditedJot("")
        let view = session.textView
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = false
        session.type("@")
        expect(!view.isAutomaticSpellingCorrectionEnabled && !view.isAutomaticTextReplacementEnabled)
        expect(!view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled)
        session.window.pressEscape()
        expect(view.isAutomaticSpellingCorrectionEnabled && view.isAutomaticTextReplacementEnabled && view.isAutomaticQuoteSubstitutionEnabled)
        expect(!view.isAutomaticDashSubstitutionEnabled)
    },

    // MARK: Keys

    test("↑ and ↓ (⌃P and ⌃N) move the highlight and wrap; pages move eight and stop at the ends; ← and → are the text's") {
        let session = try EditedJot("") { editor in
            for i in 1...12 {
                editor.add(Plate(CGRect(x: 600, y: CGFloat(i) * 100, width: 100, height: 60)), titled: String(format: "Shelf %02d", i))
            }
        }
        session.type("@shelf")
        let picker = try require(session.textView.picker)
        let shelves = session.pickerTargets
        expectEqual(shelves.count, 12)
        expectEqual(session.highlighted, shelves[0])
        session.up()
        expectEqual(session.highlighted, shelves[11], "wraps to the last")
        session.down()
        expectEqual(session.highlighted, shelves[0], "and back to the first")
        session.control("n", code: 45)
        expectEqual(session.highlighted, shelves[1])
        session.control("p", code: 35)
        expectEqual(session.highlighted, shelves[0])
        session.textView.doCommand(by: #selector(NSResponder.scrollPageDown(_:)))
        expectEqual(session.highlighted, shelves[8])
        session.textView.doCommand(by: #selector(NSResponder.pageDown(_:)))
        expectEqual(session.highlighted, shelves[11], "a page stops at the end")
        session.textView.doCommand(by: #selector(NSResponder.pageUp(_:)))
        expectEqual(session.highlighted, shelves[3])
        session.textView.doCommand(by: #selector(NSResponder.scrollPageUp(_:)))
        expectEqual(session.highlighted, shelves[0])
        expect(session.textView.picker === picker)
        expectEqual(session.string, "@shelf", "the keys moved only the highlight")
    },

    test("the first row is highlighted whenever the matches change, and the highlighted shape is hovered on the canvas") {
        let session = try EditedJot("")
        session.type("@gro")
        session.down()
        expectEqual(session.highlighted, idB)
        expectEqual(session.h.editor.hovered, idB)
        session.type("c")
        expectEqual(session.highlighted, idA)
        expectEqual(session.h.editor.hovered, idA)
        session.window.pressEscape()
        expectEqual(session.h.editor.hovered, nil)
    },

    // MARK: The window

    test("the picker's window is placed under the @ but never ordered in while the text's window isn't visible") {
        let session = try EditedJot("")
        session.type("@")
        expect(session.textView.picker != nil)
        expect(!session.textView.isPickerShown)
        expect(session.window.childWindows?.isEmpty ?? true)
        let frame = try require(session.textView.pickerFrame)
        let at = session.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        expectEqual(frame.width, 280)
        expectClose(frame.maxY, at.minY - 4)
        expect(frame.minX < at.minX && at.minX - frame.minX < 20, "its rows start under the @")
        session.window.pressEscape()
        expect(session.textView.pickerFrame == nil)
    },

    test("with no room below its @, the picker goes above the line, on the screen") {
        let session = try EditedJot("")
        guard let screen = NSScreen.main?.visibleFrame else { return }
        // The @ is some 115 points below the window's top: put it 30 points above the screen's bottom.
        session.window.setFrameTopLeftPoint(CGPoint(x: screen.minX + 100, y: screen.minY + 145 + session.window.frame.height - 500))
        session.type("@")
        let at = session.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        let frame = try require(session.textView.pickerFrame)
        expect(at.minY - 4 - frame.height < screen.minY, "no room below: \(at) on \(screen)")
        expectClose(frame.minY, at.maxY + 4)
        expect(frame.maxY <= screen.maxY && frame.minX >= screen.minX)
    },

    test("the picker's rows draw the highlight on the highlighted shape, and read as a list of shapes") {
        let session = try EditedJot("")
        session.type("@")
        let window = try require(Mirror(reflecting: session.textView).children.first { $0.label == "pickerWindow" }?.value as? NSWindow)
        let rows = try require(window.contentView?.descendants.first { $0.accessibilityRole() == .list })
        expectEqual(rows.frame.height, 3 * 24, "Nearby, and two plates")
        expectEqual(session.textView.picker?.highlighted, 1)
        let rep = try require(rows.bitmapImageRepForCachingDisplay(in: rows.bounds))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rows.cacheDisplay(in: rows.bounds, to: rep) }
        @MainActor func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x * rep.pixelsWide / Int(rows.bounds.width), y: y * rep.pixelsHigh / Int(rows.bounds.height))?.alphaComponent ?? 0 }
        expect(alpha(150, 36) > 0.9, "the highlighted row is filled")
        expectEqual(alpha(150, 60), 0, "the next isn't")
        expectEqual(alpha(150, 12), 0, "nor the header")
        let spoken = (rows.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        expectEqual(spoken, ["Groceries, Plate, 1 of 2", "Grocery List, Plate, 2 of 2"])
        session.down()
        let moved = try require(rows.bitmapImageRepForCachingDisplay(in: rows.bounds))
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { rows.cacheDisplay(in: rows.bounds, to: moved) }
        expect((moved.colorAt(x: 150 * moved.pixelsWide / Int(rows.bounds.width), y: 60 * moved.pixelsHigh / Int(rows.bounds.height))?.alphaComponent ?? 0) > 0.9)
        expect(rows.accessibilityParent() as AnyObject? === session.textView, "the list is the text view's")
    },

    test("the pointer over a row highlights it, and a click on it picks") {
        let session = try EditedJot("")
        session.type("@")
        let window = try require(Mirror(reflecting: session.textView).children.first { $0.label == "pickerWindow" }?.value as? NSWindow)
        let rows = try require(window.contentView?.descendants.first { $0.accessibilityRole() == .list })
        @MainActor func event(_ type: NSEvent.EventType, row: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: rows.convert(CGPoint(x: 100, y: CGFloat(row) * 24 + 12), to: nil), modifierFlags: [],
                               timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        rows.mouseMoved(with: event(.mouseMoved, row: 2))
        expectEqual(session.highlighted, idB)
        expectEqual(session.h.editor.hovered, idB)
        rows.mouseMoved(with: event(.mouseMoved, row: 0))
        expectEqual(session.highlighted, idB, "a header isn't highlighted")
        rows.mouseDown(with: event(.leftMouseDown, row: 1))
        expect(session.textView.picker == nil)
        expectEqual(session.pills.map(\.pill.target), [idA])
        expectEqual(session.committed?.mentioned, [idA])
        expectEqual(session.h.editor.hovered, nil)
    },

    test("the picker follows its @ as the view it's in moves or zooms, and closes once the @ is out of view") {
        let session = try EditedJot("")
        session.type("@")
        let before = try require(session.textView.pickerFrame)
        session.editing.frame.origin.x += 50
        let moved = try require(session.textView.pickerFrame)
        expectClose(moved.minX - before.minX, 50)
        expectClose(moved.height, before.height)
        session.editing.frame.size = CGSize(width: 400, height: 400)
        session.editing.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let zoomed = try require(session.textView.pickerFrame)
        let at = session.textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        expectClose(zoomed.maxY, at.minY - 4)
        expectEqual(zoomed.width, 280, "the same size at any zoom")
        session.editing.frame.origin = CGPoint(x: 2000, y: 100)
        expect(session.textView.picker == nil)
    },

    // MARK: Clicks

    test("a press on a pill keeps its drags and its release from the canvas behind; a press elsewhere is the text's") {
        let session = try EditedJot(groceries)
        let pill = session.point(of: 4)
        session.pressAndRelease(at: pill)
        expectEqual(session.textView.selectedRange(), NSRange(location: 4, length: 1))
        session.pressAndRelease(at: pill, clicks: 2)
        expectEqual(session.canvas.heard, [], "nothing reached the canvas")
    },

    test("a click on a pill selects its whole character; a double-click on a live one goes to its target on the next turn, and Back returns") {
        let session = try EditedJot(groceries)
        let pill = session.point(of: 4)
        session.click(at: pill)
        expectEqual(session.textView.selectedRange(), NSRange(location: 4, length: 1))
        expect(session.pills[0].pill.isSelected, "drawn selected")
        let pending = session.h.scheduler.pendingCount
        session.click(at: pill)
        expectEqual(session.h.scheduler.pendingCount, pending, "a click goes nowhere")
        session.click(at: pill, clicks: 2)
        expectEqual(session.h.editor.editingShapeID, session.jot, "still editing until the next turn")
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, nil)
        expectEqual(session.h.editor.selectedShapeIDs, [idA])
        session.h.editor.goBack()
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot])
    },

    test("a double-click on a missing pill keeps it selected and goes nowhere") {
        let session = try EditedJot(groceries)
        session.h.editor.delete(idA)
        let pill = session.point(of: 4)
        session.click(at: pill)
        session.click(at: pill, clicks: 2)
        expectEqual(session.textView.selectedRange(), NSRange(location: 4, length: 1))
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, session.jot)
    },

    test("selectPill(at:) selects the pill at a point, and nothing elsewhere; the selected look follows the selection") {
        let session = try EditedJot(groceries)
        expectEqual(session.pills[0].pill.widthLimit, 168, "made again for the jot's line once its editor set the insets")
        expect(!session.textView.selectPill(at: session.point(of: 1)))
        expect(session.textView.selectPill(at: session.point(of: 4)))
        expectEqual(session.textView.selectedRange(), NSRange(location: 4, length: 1))
        expect(session.pills[0].pill.isSelected)
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        expect(!session.pills[0].pill.isSelected)
        session.textView.selectAll(nil)
        expect(session.pills[0].pill.isSelected)
    },

    test("the pointer over a live pill hovers its target; off it, or out of the view, the hover ends") {
        let session = try EditedJot(groceries)
        session.moveMouse(to: session.point(of: 4))
        expectEqual(session.h.editor.hovered, idA)
        session.moveMouse(to: session.point(of: 1))
        expectEqual(session.h.editor.hovered, nil)
        session.moveMouse(to: session.point(of: 4))
        session.textView.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 50,
                                                                  windowNumber: session.window.windowNumber, context: nil, eventNumber: 0,
                                                                  trackingNumber: 0, userData: nil)!)
        expectEqual(session.h.editor.hovered, nil)
        session.h.editor.hovered = idB
        session.moveMouse(to: session.point(of: 1))
        expectEqual(session.h.editor.hovered, idB, "another's hover is left alone")
    },

    test("a pill that isn't live says why in its tooltip, and hovers nothing") {
        let session = try EditedJot(MentionText([.mention(idA, label: "Groceries"), .text(" "), .mention(idC, label: "Brief")])) { editor in
            editor.transact { $0.insert(ShapeRecord(id: idC, Brief(CGRect(x: 0, y: 300, width: 50, height: 50)))) }
        }
        expectEqual(session.textView.toolTip(at: session.point(of: 0)), nil)
        expectEqual(session.textView.toolTip(at: session.point(of: 2)), "Not available")
        session.h.editor.delete(idA)
        expectEqual(session.textView.toolTip(at: session.point(of: 0)), "Deleted")
        session.moveMouse(to: session.point(of: 0))
        expectEqual(session.h.editor.hovered, nil)
    },

    test("a pill's menu goes to its target, or turns it into its name as text, which the host commits") {
        let session = try EditedJot(groceries)
        let point = session.point(of: 4)
        let menu = try require(session.textView.menu(for: session.mouse(.rightMouseDown, at: point)))
        expectEqual(Array(menu.outline.prefix(4)), ["Go to “Groceries”", "Show What Mentions “Groceries”", "Remove Mention", "—"])
        expectEqual(session.textView.selectedRange(), NSRange(location: 4, length: 1))
        try menu.choose("Remove Mention")
        expectEqual(session.string, "Buy Groceries today")
        expect(session.pills.isEmpty)
        expectEqual(session.committed, MentionText(plain: "Buy Groceries today"))

        let going = try EditedJot(groceries)
        try require(going.textView.menu(for: going.mouse(.rightMouseDown, at: going.point(of: 4)))).choose("Go to “Groceries”")
        going.h.scheduler.advance(by: .zero)
        expectEqual(going.h.editor.selectedShapeIDs, [idA])

        let missing = try EditedJot(groceries)
        missing.h.editor.delete(idA)
        let outline = try require(missing.textView.menu(for: missing.mouse(.rightMouseDown, at: missing.point(of: 4)))).outline
        expectEqual(Array(outline.prefix(2)), ["Remove Mention", "—"], "a missing pill can't be gone to")
    },

    test("a live pill's menu shows what mentions its target, once the editing it ends is over: this jot, and any other shape that mentions it, on any board") {
        var other: ShapeID?
        let session = try EditedJot(groceries) { editor in
            other = editor.add(Jot(CGRect(x: 0, y: 300, width: 200, height: 200), text: MentionText([.mention(idA, label: "Groceries")])), titled: "Other")
        }
        try require(session.textView.menu(for: session.mouse(.rightMouseDown, at: session.point(of: 4)))).choose("Show What Mentions “Groceries”")
        expectEqual(session.h.editor.editingShapeID, session.jot, "not yet")
        session.h.scheduler.advance(by: .zero)
        expectEqual(session.h.editor.editingShapeID, nil)
        expectEqual(session.h.editor.selectedShapeIDs, [try require(other), session.jot])
        session.h.editor.goBack()
        expectEqual(session.h.editor.selectedShapeIDs, [session.jot])

        // A pill whose target is on another board too (the user chose file-wide backlinks when
        // Topology took over the index): this jot mentions it, and is on the board shown, so it
        // stays here.
        let pocket = ShapeID(), inside = ShapeID()
        let elsewhere = try EditedJot(MentionText([.text("See "), .mention(inside, label: "Inside")]), plugins: [PocketsPlugin()]) { editor in
            var plate = ShapeRecord(id: inside, Plate(CGRect(x: 0, y: 0, width: 120, height: 80)))
            plate[TitleProperty.self] = "Inside"
            editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 600, y: 0, width: 100, height: 100)))),
                                        contents: [pocket: CanvasDocument(shapes: [AnyShapeRecord(plate)])]) }
        }
        let menu = try require(elsewhere.textView.menu(for: elsewhere.mouse(.rightMouseDown, at: elsewhere.point(of: 4))))
        expectEqual(Array(menu.outline.prefix(4)), ["Go to “Inside”", "Show What Mentions “Inside”", "Remove Mention", "—"])
        try menu.choose("Show What Mentions “Inside”")
        elsewhere.h.scheduler.advance(by: .zero)
        expectEqual(elsewhere.h.editor.board, .root)
        expectEqual(elsewhere.h.editor.selectedShapeIDs, [elsewhere.jot])
    },

    // MARK: Copy and paste

    test("copy writes the stored form and \"@Label\" under both of the string's names; paste makes another mention of the same shape") {
        let session = try EditedJot(groceries)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        session.textView.setSelectedRange(NSRange(location: 0, length: 5))
        expect(session.textView.writeSelection(to: board, types: session.textView.writablePasteboardTypes))
        expectEqual(board.string(forType: .mentionText), MentionText([.text("Buy "), .mention(idA, label: "Groceries")]).stored)
        expectEqual(board.string(forType: .string), "Buy @Groceries")
        expectEqual(board.string(forType: NSPasteboard.PasteboardType("NSStringPboardType")), "Buy @Groceries")
        expect(session.textView.writeSelection(to: board, type: NSPasteboard.PasteboardType("NSStringPboardType")))
        expectEqual(board.string(forType: .string)?.contains("\u{FFFC}"), false)

        session.textView.setSelectedRange(NSRange(location: session.storage.length, length: 0))
        expect(session.textView.readSelection(from: board))
        expectEqual(session.pills.map(\.pill.target), [idA, idA])
        expectEqual(session.committed?.mentioned, [idA, idA])
        expectEqual(session.string, "Buy \u{FFFC} todayBuy \u{FFFC}")
    },

    test("pasted plain text makes pills of whole mentions, and is text otherwise") {
        let session = try EditedJot("")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("See @[Grocery List](shape:\(idB.rawValue.uuidString.lowercased())) and @[half", forType: .string)
        expect(session.textView.readSelection(from: board))
        expectEqual(session.pills.map(\.pill.target), [idB])
        expectEqual(session.string, "See \u{FFFC} and @[half")
        expectEqual(session.committed, MentionText([.text("See "), .mention(idB, label: "Grocery List"), .text(" and @[half")]))
        expect(session.textView.picker == nil)

        board.declareTypes([.string], owner: nil)
        board.setString(" plain", forType: .string)
        expect(session.textView.readSelection(from: board))
        expectEqual(session.string, "See \u{FFFC} and @[half plain")
    },

    test("a rename of a pill's target changes the pill, with no transaction and no change the host hears") {
        let session = try EditedJot(groceries)
        let pill = session.pills[0].pill
        let width = pill.bounds.width
        let revision = session.h.editor.revision
        session.h.editor.rename(idA, "Groceries for the whole week")
        expectEqual(session.h.editor.revision, revision + 1, "only the rename")
        expectEqual(pill.shownLabel, "Groceries for the whole week")
        expect(pill.bounds.width > width)
        expectEqual(session.committed, groceries, "the board's text isn't written")
        expectEqual(session.textView.mentionText, MentionText([.text("Buy "), .mention(idA, label: "Groceries for the whole week"), .text(" today")]))

        session.h.editor.rename(idA, "Food")
        session.h.editor.delete(idA)
        let missing = session.pills[0].pill
        expect(!missing.resolution.isLive)
        expectEqual(missing.shownLabel, "Groceries", "the name the board holds, as the canvas shows it, never the last one shown")
        expectEqual(session.textView.mentionText, groceries)
        expectEqual(session.committed, groceries, "what the canvas draws, dashed")

        // Written after a rename, the board holds the name the pill had then, and so does the pill.
        let written = try EditedJot(groceries)
        written.h.editor.rename(idA, "Food")
        written.textView.setSelectedRange(NSRange(location: written.storage.length, length: 0))
        written.type("!")
        expectEqual(written.committed, MentionText([.text("Buy "), .mention(idA, label: "Food"), .text(" today!")]))
        written.h.editor.rename(idA, "Supplies")
        written.h.editor.delete(idA)
        expectEqual(written.pills[0].pill.shownLabel, "Food", "what the board holds, not the pill's first name or its last")
        expectEqual(written.textView.mentionText, written.committed)
    },

    // MARK: Undo

    test("outside a board's window, an undo in the text reaches the host once, as the view writes it back: typing, and a pick, which gives back the query") {
        let session = try EditedJot("")
        session.type("Buy @gro")
        session.window.settle()
        session.window.pressReturn()
        session.window.settle()
        expectEqual(session.committed?.mentioned, [idA])
        var revision = session.h.editor.revision
        session.textView.undoManager?.undo()
        expectEqual(session.string, "Buy @gro")
        expectEqual(session.committed, MentionText(plain: "Buy @gro"))
        expectEqual(session.h.editor.revision, revision + 1, "one write")
        expect(session.textView.picker == nil, "an undone @ opens nothing")
        revision = session.h.editor.revision
        session.textView.undoManager?.redo()
        expectEqual(session.committed?.mentioned, [idA])
        expectEqual(session.h.editor.revision, revision + 1, "one write")
        // Told again that the text changed (as a board's window tells it after an undo), the host
        // writes nothing more.
        session.textView.didChangeText()
        expectEqual(session.h.editor.revision, revision + 1, "a second report of one change writes nothing")
        session.window.settle()
        session.textView.undoManager?.undo()
        session.window.settle()
        session.textView.undoManager?.undo()
        expectEqual(session.string, "")
        expectEqual(session.committed, MentionText(plain: ""))
    },

    test("an undo that puts a pill back shows its target as it is now: deleted while the pill was out of the text, missing") {
        let session = try EditedJot(groceries)
        try require(session.textView.menu(for: session.mouse(.rightMouseDown, at: session.point(of: 4)))).choose("Remove Mention")
        session.window.settle()
        expect(session.pills.isEmpty)
        session.h.editor.rename(idA, "Food")
        session.textView.undoManager?.undo()
        expectEqual(session.pills.first?.pill.resolution.appearance?.label, "Food", "renamed while it was out")
        expectEqual(session.committed, MentionText([.text("Buy "), .mention(idA, label: "Food"), .text(" today")]), "written back as it shows")
        session.window.settle()
        session.textView.undoManager?.redo()
        session.h.editor.delete(idA)
        session.window.settle()
        session.textView.undoManager?.undo()
        expectEqual(session.pills.first?.pill.resolution, .missing, "deleted while it was out")
        expectEqual(session.committed?.mentioned, [idA])
        expectEqual(session.committed, session.textView.mentionText)
    },

    test("leaving its window, the view takes its own steps of undo from the window's undo manager, and only those") {
        let session = try EditedJot("")
        let manager = try require(session.window.undoManager)
        let other = Flag()
        manager.registerUndo(withTarget: other) { $0.fired = true }
        session.window.settle()
        session.type("abc")
        session.window.settle()
        expect(manager.canUndo)
        session.editing.removeFromSuperview()
        expect(manager.canUndo, "another's step stays")
        manager.undo()
        expect(other.fired, "the other step is the one undone")
        expectEqual(session.string, "abc", "the view's went with it")
        expect(!manager.canUndo)
    },

    // MARK: Accessibility

    test("VoiceOver counts a pill as one character, as the text does, and reads it as its name and kind, or why it isn't live") {
        let session = try EditedJot(groceries)
        let view = session.textView
        let value = try require(view.accessibilityValue())
        expectEqual((value as NSString).length, view.accessibilityNumberOfCharacters(), "the value and the count agree")
        expectEqual((value as NSString).length, session.storage.length)
        let whole = NSRange(location: 0, length: session.storage.length)
        expectEqual(view.accessibilityAttributedString(for: whole)?.string, "Buy Groceries, Plate today")
        expectEqual(view.accessibilityString(for: whole), "Buy Groceries, Plate today")
        expectEqual(view.accessibilityString(for: NSRange(location: 4, length: 1)), "Groceries, Plate")
        view.setSelectedRange(NSRange(location: 4, length: 1))
        expectEqual(view.accessibilitySelectedTextRange(), NSRange(location: 4, length: 1))
        expectEqual(view.accessibilitySelectedText(), "Groceries, Plate")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        expectEqual(view.accessibilitySelectedText(), "Buy")
        session.h.editor.delete(idA)
        expectEqual(view.accessibilityAttributedString(for: whole)?.string, "Buy Groceries, deleted today")
        expectEqual(view.accessibilityString(for: whole), "Buy Groceries, deleted today")
    },

    test("VoiceOver hears the picker's list change as it opens and moves, and go as it closes") {
        #if DEBUG
        let session = try EditedJot("")
        let before = MentionAccessibility.posted.count
        session.type("@gro")
        expect(MentionAccessibility.posted[before...].contains(.announcementRequested), "the highlighted row is said")
        let opened = MentionAccessibility.posted.count
        session.window.pressEscape()
        expect(session.textView.picker == nil)
        expectEqual(Array(MentionAccessibility.posted[opened...]), [.uiElementDestroyed])
        let closed = MentionAccessibility.posted.count
        session.type(" @zz ")
        expect(session.textView.picker == nil, "a space after nothing matching")
        expectEqual(MentionAccessibility.posted.last, .uiElementDestroyed)
        expect(MentionAccessibility.posted.count > closed)
        #endif
    },
])
