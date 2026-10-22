import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import TestKit

// The key-walk harness held to the real thing: each chord the driver sends reaches a real canvas as
// the stroke `EditorHarness.key` builds of it (so a headless test presses what a user presses), the
// driver says where each key went, and a walk over a toy window checks what it should and fails a
// trap it is shown.

/// The strokes the canvas hands the plugin that claims them.
@MainActor final class StrokeLog {
    var strokes: [KeyStroke] = []
    /// What the plugin says it did with a stroke: true takes it, false passes it to AppKit.
    var takes: (KeyStroke) -> Bool = { _ in true }
}

@MainActor func strokeRecorder(_ log: StrokeLog) -> Contributor {
    Contributor(id: "strokes") {
        $0.keyStrokes { _, stroke in
            log.strokes.append(stroke)
            return log.takes(stroke)
        }
    }
}

/// A canvas filling an unshown window, its editor's strokes logged, with a button beside it whose
/// key is Return when `returnButton`.
@MainActor func strokeCanvas(returnButton: Bool = false) throws -> (window: NSWindow, canvas: CanvasView, log: StrokeLog, button: MenuActionLog) {
    let log = StrokeLog()
    let h = try EditorHarness(plugins: [FixturesPlugin(), strokeRecorder(log)])
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
    let content = NSView(frame: window.contentLayoutRect)
    let canvas = CanvasView(editor: h.editor)
    canvas.frame = content.bounds
    content.addSubview(canvas)
    let pressed = MenuActionLog()
    let button = NSButton(title: "Go", target: pressed, action: #selector(MenuActionLog.fire(_:)))
    if returnButton { button.keyEquivalent = "\r" }
    button.frame = CGRect(x: 500, y: 10, width: 80, height: 30)
    content.addSubview(button)
    window.contentView = content
    window.makeFirstResponder(canvas)
    return (window, canvas, log, pressed)
}

/// A target that counts the actions it's sent.
@MainActor final class MenuActionLog: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

/// A view a walk can stop on, with two drawn parts reached with ⌥Tab: Tab and ⇧Tab go on through
/// the window's key view loop (unless it `traps` them), Escape leaves a part for the view and the
/// view for the window.
@MainActor final class PartsView: NSView {
    let parts = ["a", "b"]
    var part: String?
    var traps = false
    var keys: [String] = []

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Parts" }

    override func keyDown(with event: NSEvent) {
        keys.append(event.charactersIgnoringModifiers ?? "")
        let backward = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 48 where event.modifierFlags.contains(.option):
            let index = part.flatMap(parts.firstIndex(of:)).map { ($0 + (backward ? parts.count - 1 : 1)) % parts.count } ?? (backward ? parts.count - 1 : 0)
            part = parts[index]
        case 48 where traps && !backward:
            break
        case 48:
            if backward { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        case 53:
            if part != nil { part = nil } else { window?.makeFirstResponder(nil) }
        default:
            super.keyDown(with: event)
        }
    }
}

/// Three fields (top to bottom), the parts view, and a button below them, in an unshown window; the
/// first field has the keyboard.
@MainActor final class ToyWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 320), styleMask: [.titled], backing: .buffered, defer: true)
    let fields: [NSTextField]
    let parts = PartsView(frame: CGRect(x: 20, y: 80, width: 200, height: 60))
    let button = NSButton(title: "OK", target: nil, action: nil)

    init(labels: [String?] = ["One", "Two", "Three"]) {
        let content = NSView(frame: window.contentLayoutRect)
        fields = labels.enumerated().map { index, label in
            let field = NSTextField(frame: CGRect(x: 20, y: 270 - CGFloat(index) * 40, width: 200, height: 24))
            field.placeholderString = label
            field.setAccessibilityIdentifier("field\(index + 1)")
            content.addSubview(field)
            return field
        }
        content.addSubview(parts)
        button.frame = CGRect(x: 20, y: 20, width: 80, height: 30)
        content.addSubview(button)
        window.contentView = content
        window.recalculateKeyViewLoop()
        // Where Tab starts with nothing focused: without it, Tab with the window as first responder
        // goes nowhere.
        window.initialFirstResponder = fields[0]
        window.makeFirstResponder(fields[0])
    }

    var reader: CustomFocusReader {
        .custom("parts") { [parts] window in
            guard window.firstResponder === parts else { return nil }
            return .of(window, surface: "toy", element: parts.part.map { "parts/\($0)" } ?? "parts")
        }
    }

    func walk() -> KeyWalk {
        let walk = KeyWalk(window, readers: [reader])
        walk.standardControls = ["window/OK"]
        return walk
    }

    static let stops = ["window/field1", "window/field2", "window/field3", "toy/parts", "window/OK"]
}

@MainActor let keyDriverTests = Suite("Key driver and walks", [
    test("every chord the driver sends reaches a real canvas as the stroke EditorHarness.key builds of it") {
        let chords: [Chord] = [
            .tab, .backTab, .optionTab, .optionBackTab, .up, .down, .left, .right, .return, .enter, .escape, .space, .delete,
            .forwardDelete, Chord(Key.home), Chord(Key.end), Chord(Key.pageUp), Chord(Key.pageDown), Chord(Key.f6), Chord(Key.f6, .shift),
            Chord(Key.menu), Chord("v"), Chord("V"), Chord("1"), Chord("!"), Chord("2", .shift), Chord("1", .command), Chord("z", .command),
            Chord("z", [.command, .shift]), Chord("q", .control), Chord("q", .option), Chord("]"), Chord("?"), Chord(Key.down, .option),
            Chord(Key.right, [.option, .shift]), Chord(Key.down, .command), Chord(Key.up, [.command, .option]), Chord(Key.return, .control),
            .commandReturn, .commandPeriod, Chord(Key.space, .control),
        ]
        let (window, canvas, log, _) = try strokeCanvas()
        let driver = KeyDriver(window)
        let headless = StrokeLog()
        let h = try EditorHarness(plugins: [FixturesPlugin(), strokeRecorder(headless)])
        for chord in chords {
            log.strokes = []
            headless.strokes = []
            let delivery = driver.send(chord)
            h.key(chord)
            expectEqual(log.strokes, headless.strokes, "\(chord)")
            expectEqual(log.strokes.count, 1, "\(chord) reaches the canvas once")
            if chord.modifiers.contains(.command) {
                expect(delivery.isKeyEquivalent, "\(chord), with ⌘, is the canvas's key equivalent: \(delivery)")
            } else {
                expect(delivery.responder === canvas, "\(chord) is the canvas's: \(delivery)")
            }
            if chord.numberRowKey == nil {
                headless.strokes = []
                h.hold(chord.strokeModifiers)
                h.key(chord.strokeCharacters)
                h.hold([])
                expectEqual(headless.strokes, log.strokes, "\(chord), pressed as characters with its modifiers held")
            }
        }
        let held = driver.hold(.down, repeats: 2)
        expectEqual(held.count, 3)
        expectEqual(log.strokes.suffix(3).map(\.isRepeat), [false, true, true], "a held key repeats after its first press")
    },
    test("the driver says where a key went: a view's key equivalent, the menu bar's item, the first responder, or nowhere") {
        let (window, canvas, log, button) = try strokeCanvas(returnButton: true)
        log.takes = { _ in false }
        let target = MenuActionLog()
        let item = NSMenuItem(title: "Bring Forward", action: #selector(MenuActionLog.fire(_:)), keyEquivalent: "]")
        item.keyEquivalentModifierMask = []
        item.target = target
        let arrange = NSMenu(title: "Arrange")
        arrange.addItem(item)
        let bar = NSMenu()
        bar.addItem(withTitle: "Arrange", action: nil, keyEquivalent: "").submenu = arrange
        let driver = KeyDriver(window, menu: bar)

        expect(driver.send(.return).isKeyEquivalent, "the button's Return comes first")
        expectEqual(button.fired, 1)
        expect(driver.send(Chord("]")).menuItem === item, "a plain-key item takes its key before the canvas does")
        expectEqual(target.fired, 1)
        expect(log.strokes.isEmpty)
        expect(driver.send(Chord("x")).responder === canvas, "the canvas passes x to AppKit, and swallows the text it types")
        expectEqual(log.strokes.map(\.characters), ["x"])
        let plain = KeyDriver(window)
        expect(plain.send(Chord("]")).responder === canvas, "with no menu bar, ] is the canvas's")
        window.makeFirstResponder(nil)
        expect(plain.send(Chord("x")).isUnhandled, "with the window as first responder, x goes down the whole chain")
        expect(window.firstResponder === window)
        expect(window.nextResponder == nil, "the end of the chain is let go after each key")
    },
    test("the press helpers send the key the US layout types each character with") {
        let (window, _, log, _) = try strokeCanvas()
        window.press("1")
        window.press("n")
        window.pressDelete()
        expectEqual(log.strokes.map(\.numberRowKey), ["1", nil, nil], "1's key is the number row's")
        expectEqual(window.keyEvent("n").keyCode, 45)
        expectEqual(window.keyEvent("\u{8}", ignoringModifiers: "h", modifiers: .control).keyCode, 4)
        expectEqual(window.keyEvent("a").keyCode, 0, "a's key is 0")
    },
    test("Tab moves AppKit's key view loop in an unshown window, its focused field answers for accessibility, and Keyboard navigation is read") {
        let toy = ToyWindow()
        let walk = toy.walk()
        expectEqual(walk.focus.id, "window/field1")
        walk.press(.tab)
        expectEqual(walk.focus.id, "window/field2", "a field's editor sends Tab on through the loop")
        expectEqual(AccessibilityProbe.focused(in: toy.window).flatMap { $0.accessibilityRole() }, .textField)
        expectEqual(walk.focus.role, NSAccessibility.Role.textField.rawValue)
        expectEqual(walk.focus.label, "Two")
        expect(walk.focus.acceptsText && walk.focus.isMarked, "a caret")
        expectEqual(walk.keyboardNavigation, NSApplication.shared.isFullKeyboardAccessEnabled)
        expectEqual(toy.button.canBecomeKeyView, walk.keyboardNavigation, "a button is a key view only with Keyboard navigation on")
        let tree = AccessibilityProbe.tree(of: toy.window.contentView!)
        expect(tree.outline.contains { $0.contains("“Parts”") }, "\(tree.outline)")
    },
    test("a walk over a toy window: Tab round its stops and ⇧Tab back at each, ⌥Tab through a view's parts, Escape out a level at a time, inert keys, every stop marked and named") {
        let toy = ToyWindow()
        let walk = toy.walk()
        let cycle = walk.expectCycle(ToyWindow.stops)
        expectEqual(cycle.ids, ToyWindow.stops.filter { walk.keyboardNavigation || $0 != "window/OK" })
        expectEqual(walk.skipped, walk.keyboardNavigation ? [] : ["window/OK"], "the button is left out, not failed, with Keyboard navigation off")
        walk.expectShows(cycle.stops)
        walk.go("toy/parts")
        walk.press(.optionTab)
        walk.expectCycle(["toy/parts/a", "toy/parts/b"], forward: .optionTab, back: .optionBackTab)
        walk.go("toy/parts/b", by: .optionTab)
        walk.expectEscapeLadder(["toy/parts", "window"])
        walk.go("toy/parts")
        let before = toy.parts.keys.count
        walk.expectInert(at: [walk.focus], editorless: true)
        expect(toy.parts.keys.count > before, "the inert keys reached the view")
        walk.go("window/field1")
        walk.press(.tab)
        walk.expectCycle(inOrder: ["window/field2", "toy/parts"])
        expect(walk.presses.count > 30)
        expect(walk.trace.first?.hasPrefix("Tab -> window/field2") == true, "\(walk.trace.prefix(2))")
    },
    test("a walk fails a trap, a wrong order, a broken way back, an Escape that skips a level and an unnamed stop, with the walk so far") {
        let toy = ToyWindow(labels: ["One", nil, "Three"])
        toy.parts.traps = true
        let walk = toy.walk()
        let trapped = runAsTest { walk.expectCycle(ToyWindow.stops) }
        expectEqual(trapped.count, 1)
        expect(trapped.first?.contains("trap: Tab at toy/parts stays there") == true, "\(trapped)")
        expect(trapped.first?.contains("walk: Tab -> window/field2, ⇧Tab -> window/field1") == true, "\(trapped)")
        toy.parts.traps = false
        walk.go("window/field1")
        let wrong = runAsTest { walk.expectCycle(["window/field1", "window/field3"]) }
        expect(wrong.first?.contains("goes to window/field2; it should go to window/field3") == true, "\(wrong)")
        walk.go("toy/parts")
        let ladder = runAsTest { walk.expectEscapeLadder(["toy/parts"]) }
        expect(ladder.first?.contains("Escape at toy/parts goes to window, not toy/parts") == true, "\(ladder)")
        walk.go("window/field1")
        let unnamed = runAsTest { walk.expectShows([Focus(surface: "window", element: "field2")]) }
        expect(unnamed.first?.contains("window/field2 has no accessibility label") == true, "\(unnamed)")
        walk.pending = ["window: the second field has no label, test-6"]
        expectEqual(runAsTest { walk.expectShows([Focus(surface: "window", element: "field2")]) }, [], "a pending gap is let through")
        walk.pending = ["toy: no label yet, test-6"]
        let passing = runAsTest { walk.expectShows([Focus(surface: "toy", element: "parts")]) }
        expect(passing.first?.contains("pending \"toy: no label yet, test-6\" passes now") == true, "\(passing)")
    },
])
