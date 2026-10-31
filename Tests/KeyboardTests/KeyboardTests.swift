@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import TestKit

@MainActor final class KeyLog {
    var events: [String] = []
    var armed = false
}

/// C for the fixtures' card tool, which has no key of its own (CanvasTesting can't import Keyboard).
@MainActor let cardKey = Contributor(id: "card-key") { $0.shortcut("c", forTool: ToolID(placing: Card.kind)) }

@MainActor let shortcutTests = Suite("Keyboard shortcuts", [
    test("a tool's key switches to it, whatever the letter's case; a key no shortcut has goes on") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey])
        expect(h.key("C"))
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expect(h.key("h"))
        expectEqual(h.editor.currentToolID, .hand)
        expect(!h.key("j"))
        expect(!h.key("ch"), "two characters aren't a key")
        expect(!h.key(""), "a dead key types nothing yet")
    },
    test("Keyboard gives the core's actions their keys: H the Hand, and Escape and ⌘. cancel") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey])
        h.key("c")
        expect(h.key("\u{1b}"))
        expectEqual(h.editor.currentToolID, .hand, "Escape leaves a tool that isn't the default one")
        h.key("c")
        h.hold(.command)
        expect(h.key("."))
        h.hold([])
        expectEqual(h.editor.currentToolID, .hand)
    },
    test("⌘Z undoes and ⇧⌘Z redoes, again and again while held; with nothing to undo or redo, they pass") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let b = h.add(Box(CGRect(x: 20, y: 0, width: 10, height: 10)))
        h.hold(.command)
        expect(h.key("z"))
        expectEqual(h.editor.document.shapes.map(\.id), [a])
        expect(h.key("z", isRepeat: true), "a held ⌘Z undoes again")
        expectEqual(h.editor.document.shapes, [])
        expect(!h.key("z", isRepeat: true), "nothing left to undo: the key goes on, and the Mac beeps")
        h.hold([.shift, .command])
        expect(h.key("Z"))
        expect(h.key("Z", isRepeat: true))
        expectEqual(h.editor.document.shapes.map(\.id), [a, b])
        expect(!h.key("Z"), "⇧⌘Z with nothing to redo passes, and isn't ⌘Z")
        expectEqual(h.editor.document.shapes.map(\.id), [a, b])
        h.hold([])
        expect(!h.key("z"), "Z alone isn't undo")
    },
    test("a command's keys run it, as the menu item that sends it does") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "stamps") { r in
            r.command("stamp", title: "Stamp", shortcuts: [KeyChord("s", .command), .deleteForward]) { _ in log.events.append("stamp") }
        }])
        h.hold(.command)
        expect(h.key("s"))
        h.hold([])
        expect(!h.key("s"), "⌘S, not S")
        expect(h.key("\u{F728}"))
        expect(h.editor.perform("stamp"))
        expectEqual(log.events, ["stamp", "stamp", "stamp"])
    },
    test("a command with keys can be named for the step it would take, and is listed by its own title") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "stamps") { r in
            r.command("stamp", title: "Stamp", shortcuts: ["s"], menuTitle: { _ in log.armed ? "Stamp Twice" : "Stamp Once" }) { _ in log.events.append("stamp") }
        }])
        expectEqual(h.editor.menuTitle(of: "stamp"), "Stamp Once")
        log.armed = true
        expectEqual(h.editor.menuTitle(of: "stamp"), "Stamp Twice")
        expectEqual(h.editor.registry.title(of: "stamp"), "Stamp")
        expect(h.key("s"))
        expectEqual(h.editor.registry.keyboardHelpRows.first { $0.place == .command("stamp") }?.title, "Stamp", "the Keyboard Shortcuts window lists the command")
    },
    test("a command's keys pass while it can't run, as its menu item is dimmed then") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "stamps") { r in
            r.command("stamp", title: "Stamp", shortcuts: ["s"], isEnabled: { _ in log.armed }) { _ in log.events.append("stamp") }
        }])
        expect(!h.key("s"))
        expect(!h.editor.canPerform("stamp"))
        log.armed = true
        expect(h.key("s"))
        expectEqual(log.events, ["stamp"])
    },
    test("⇧ counts when a chord asks for it; a key held with ⇧ alone answers the key alone too, and a letter doesn't with ⌘, ⌥ or ⌃") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "keys") { r in
            r.shortcut("d", "D") { _ in log.events.append("d") }
            r.shortcut(KeyChord("d", .shift), "Shift D") { _ in log.events.append("⇧d") }
            r.shortcut("e", "E") { _ in log.events.append("e") }
            r.shortcut("?", "Help") { _ in log.events.append("?") }
            r.shortcut(KeyChord("j", .command), "Jump") { _ in log.events.append("⌘j") }
        }])
        h.key("d")
        h.hold(.shift)
        h.key("D")
        h.key("E")
        h.key("?")                              // ⇧/, on a US keyboard
        h.hold([.shift, .command])
        expect(!h.key("J"), "⇧⌘J isn't ⌘J")
        h.hold(.command)
        h.key("j")
        h.hold(.option)
        expect(!h.key("e"), "⌥E isn't E")
        h.hold([])
        expectEqual(log.events, ["d", "⇧d", "e", "?", "⌘j"])
    },
    test("⇧ that types punctuation, a symbol or a digit is implied with ⌘ (⌘? is ⇧⌘/); with a key that types no character, it counts") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey, Contributor(id: "keys") { r in
            r.shortcut(KeyChord("?", .command), "Help") { _ in log.events.append("⌘?") }
            r.shortcut(KeyChord("1", .command), "One") { _ in log.events.append("⌘1") }
            r.shortcut(KeyChord("\u{F703}", .command), "End") { _ in log.events.append("⌘→") }
        }])
        h.hold([.shift, .command])
        expect(h.key("?"))                              // ⇧⌘/ on a US keyboard
        expect(h.key("1"))                              // ⇧⌘& on a French one
        expect(!h.key("\u{F703}"), "⇧⌘→ isn't ⌘→")
        h.hold([])
        expectEqual(log.events, ["⌘?", "⌘1"])
        h.key("c")
        h.hold([.shift, .command])
        expect(h.key("."), "⌘. is ⇧⌘; on a French keyboard")
        expectEqual(h.editor.currentToolID, .hand)
    },
    test("a digit's chord is its key on the number row, whatever the layout types with it: ⇧1 is the key that types \"!\" on a US keyboard") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "keys") { r in
            r.shortcut(KeyChord("2", .shift), "Two") { _ in log.events.append("⇧2") }
            r.shortcut("!", "Bang") { _ in log.events.append("!") }
        }])
        h.hold(.shift)
        expect(h.editor.keyDown(KeyStroke("@", modifiers: .shift, numberRowKey: "2")), "US: ⇧2 types @")
        expect(h.editor.keyDown(KeyStroke("2", modifiers: .shift, numberRowKey: "2")), "French: ⇧ and the key types 2")
        expect(h.editor.keyDown(KeyStroke("!", modifiers: .shift, numberRowKey: "1")), "a chord of what it types comes first")
        expect(!h.editor.keyDown(KeyStroke("@", modifiers: .shift)), "@ from another key isn't ⇧2")
        h.hold([])
        expect(!h.editor.keyDown(KeyStroke("é", numberRowKey: "2")), "the key alone isn't ⇧2")
        expectEqual(log.events, ["⇧2", "⇧2", "!"])
    },
    test("Keyboard gives the core's zoom commands their keys: ⌘= and ⌘- (held, again and again), ⌘0, and ⇧1 for Zoom to Fit") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.hold(.command)
        expect(h.key("="))
        expectEqual(h.editor.zoomPercentage, 200)
        expect(h.key("=", isRepeat: true))
        expectEqual(h.editor.zoomPercentage, 400)
        expect(h.key("-"))
        expectEqual(h.editor.zoomPercentage, 200)
        expect(h.key("0"))
        expectEqual(h.editor.zoomPercentage, 100)
        expect(!h.key("0"), "at 100%, ⌘0 passes")
        h.hold(.shift)
        expect(!h.editor.keyDown(KeyStroke("!", modifiers: .shift, numberRowKey: "1")), "nothing to fit: ⇧1 passes")
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(h.editor.keyDown(KeyStroke("!", modifiers: .shift, numberRowKey: "1")))
        expectEqual(h.editor.zoomPercentage, 536, "600 − 64 points for 100")
    },
    test("= and - alone zoom as ⌘= and ⌘- do, held, again and again, and ⇧0 is Actual Size, the number row's 0 whatever the layout types with it") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        expect(h.key("="))
        expectEqual(h.editor.zoomPercentage, 200)
        expect(h.key("=", isRepeat: true))
        expectEqual(h.editor.zoomPercentage, 400)
        expect(h.key("-"))
        expect(h.key("-", isRepeat: true))
        expectEqual(h.editor.zoomPercentage, 100)
        expect(h.key("-"))
        expectEqual(h.editor.zoomPercentage, 50)
        h.hold(.shift)
        expect(h.editor.keyDown(KeyStroke(")", modifiers: .shift, numberRowKey: "0")), "US: ⇧0 types )")
        expectEqual(h.editor.zoomPercentage, 100)
        expect(!h.editor.keyDown(KeyStroke(")", modifiers: .shift, numberRowKey: "0")), "at 100%, ⇧0 passes")
        h.hold([])
        expect(!h.editor.keyDown(KeyStroke("0", numberRowKey: "0")), "0 alone isn't a zoom key")
        h.hold(.option)
        expect(!h.key("="), "⌥= isn't =")
        h.hold([])
        expectEqual(h.editor.zoomPercentage, 100)
    },
    test("Page Up and Page Down move the view a page, eased, again and again while held; Home and End go to the start and the end of the board's shapes; with no view, or Home and End with no shapes, they pass") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin()])
        let pageUp = "\u{F72C}", pageDown = "\u{F72D}", home = "\u{F729}", end = "\u{F72B}"
        expect(!h.key(pageDown), "no view yet")
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 700))
        expect(h.key(pageDown))
        expectEqual(h.editor.camera.origin, .zero, "eased, not jumped")
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 560), "0.8 of the view")
        expect(h.key(pageDown, isRepeat: true), "held, again")
        h.wait(200)
        expectEqual(h.editor.camera.origin, CGPoint(x: 0, y: 1120))
        expect(h.key(pageUp))
        expect(h.key(pageUp))
        h.wait(200)
        expectEqual(h.editor.camera.origin, .zero, "the second goes on from where the first was headed")
        expect(!h.key(home), "an empty board: nowhere to go")
        expect(!h.key(end))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        expect(h.key(home))
        h.wait(400)
        expectEqual(h.editor.camera.origin, CGPoint(x: -450, y: -300), "a board that fits is centered")
        h.add(Box(CGRect(x: 2000, y: 1500, width: 100, height: 100)))
        expect(h.key(home))
        h.wait(400)
        expectEqual(h.editor.camera.origin, CGPoint(x: -32, y: -32), "its top left, half a fit's margin in")
        expect(h.key(end))
        h.wait(400)
        expectEqual(h.editor.camera.origin, CGPoint(x: 1132, y: 932), "its bottom right")
        expectEqual(h.editor.camera.zoom, 1, "at the zoom it has")
    },
    test("Q turns the tool lock on and off, whatever the tool; Escape leaves the tool and the lock stays") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey])
        expect(!h.editor.isToolLocked)
        expect(h.key("q"))
        expect(h.editor.isToolLocked)
        h.key("c")
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind))
        expect(h.key("\u{1b}"))
        expectEqual(h.editor.currentToolID, .hand, "Escape leaves the tool")
        expect(h.editor.isToolLocked, "and the lock stays on, for the next one")
        h.hold(.shift)
        expect(h.key("Q"))
        h.hold([])
        expect(!h.editor.isToolLocked, "a capital Q too: the key, not the case")
    },
    test("Zoom to Fit's key again goes back to where the camera was before the fit, while it's still there") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let before = h.editor.camera
        let bang = KeyStroke("!", modifiers: .shift, numberRowKey: "1")
        h.hold(.shift)
        expect(h.editor.keyDown(bang))
        h.wait(400)
        expectEqual(h.editor.zoomPercentage, 536)
        expect(h.editor.keyDown(bang))
        h.wait(400)
        expectEqual(h.editor.camera, before)
        h.hold([])
    },
    test("Space held holds the hand, whatever the tool: its repeats are taken and do nothing; its release, or every key's, lets go") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey])
        h.key("c")
        expect(h.key(" "))
        expect(h.editor.isHandHeld)
        expectEqual(h.editor.currentToolID, ToolID(placing: Card.kind), "the tool stays")
        expect(h.key(" ", isRepeat: true), "kept, so AppKit doesn't beep")
        h.press(at: CGPoint(x: 100, y: 100)); h.drag(to: CGPoint(x: 130, y: 100)); h.release(after: 100)
        expectEqual(h.editor.document.shapes, [], "it panned")
        h.editor.keyUp(KeyStroke(" "))
        expect(!h.editor.isHandHeld)
        h.hold(.shift)
        expect(h.key(" "), "with ⇧ too")
        h.hold([])
        expect(h.editor.isHandHeld)
        h.editor.keysReleased()
        expect(!h.editor.isHandHeld, "the canvas lost the keyboard")
        h.editor.keyUp(KeyStroke(" "))
        expect(!h.editor.isHandHeld)
        h.key(" ")
        h.editor.keyUp(KeyStroke("c"))
        expect(h.editor.isHandHeld, "another key's release isn't Space's")
    },
    test("a tool's key is taken while the editor takes the tool: on a read-only board, a tool that places shapes passes its key and stays unchosen, the Hand's key goes on being taken") {
        let frozen = ShapeID(), plain = ShapeID()
        var locked = AnyShapeRecord(ShapeRecord(id: frozen, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        locked[Frozen.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [locked, AnyShapeRecord(ShapeRecord(id: plain, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100))))]),
                              children: [frozen: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Card(CGRect(x: 0, y: 0, width: 100, height: 60))))]),
                                         plain: CanvasDocument(shapes: [])])
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey, PocketsPlugin(), FreezingPlugin()], file: file)
        let card = ToolID(placing: Card.kind)
        expect(h.enter(frozen))
        expect(!h.key("c"), "the key goes on, as one of a command that can't run does")
        expectEqual(h.editor.currentToolID, .hand)
        expect(h.key("h"))
        expect(h.editor.showBoard(.root))
        expect(h.key("c"))
        expectEqual(h.editor.currentToolID, card)
        h.key("h")
        expect(h.enter(plain))
        expect(h.key("C"))
        expectEqual(h.editor.currentToolID, card, "a board with a pocket on it that isn't frozen takes it")
        h.editor.transact(on: .root, "Freeze") { $0.update(plain) { $0[Frozen.self] = true } }
        expectEqual(h.editor.currentToolID, .hand, "a lock above the board leaves it")
        expect(!h.key("c"))
        h.editor.transact(on: .root, "Thaw") { $0.update(plain) { $0[Frozen.self] = nil } }
        expect(h.key("c"))
        expectEqual(h.editor.currentToolID, card)
    },
    test("a shortcut whose when doesn't hold passes the key on: to the key alone, if it answers that, else to AppKit") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "keys") { r in
            r.shortcut(KeyChord("x", .shift), "Armed", when: { _ in log.armed }) { _ in log.events.append("armed") }
            r.shortcut("x", "Plain") { _ in log.events.append("plain") }
            r.shortcut("y", "Never", when: { _ in false }) { _ in log.events.append("never") }
        }])
        h.hold(.shift)
        expect(h.key("X"))
        log.armed = true
        expect(h.key("X"))
        h.hold([])
        expect(!h.key("y"))
        expectEqual(log.events, ["plain", "armed"])
    },
    test("a held key does its thing once, unless its shortcut repeats; its repeats are the shortcut's all the same") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey, Contributor(id: "keys") { r in
            r.shortcut("n", "Once") { _ in log.events.append("once") }
            r.shortcut(.rightArrow, "Nudge", repeats: true) { _ in log.events.append("nudge") }
        }])
        expect(h.key("n"))
        expect(h.key("n", isRepeat: true), "kept, so AppKit doesn't beep")
        expect(h.key("\u{F703}"))
        expect(h.key("\u{F703}", isRepeat: true))
        expectEqual(log.events, ["once", "nudge", "nudge"])
        h.key("c")
        h.editor.setTool(.hand)
        expect(h.key("c", isRepeat: true))
        expectEqual(h.editor.currentToolID, .hand, "a tool's key, held, switches once")
    },
    test("a key's repeats run its shortcut again only while the canvas has seen it go down: one held down elsewhere, or let go of, repeats as nothing") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "keys") { r in
            r.shortcut(.rightArrow, "Nudge", repeats: true) { _ in log.events.append("nudge") }
            r.shortcut(.leftArrow, "Back", repeats: true) { _ in log.events.append("back") }
        }])
        let right = "\u{F703}", left = "\u{F702}"
        expect(h.key(right, isRepeat: true), "held down elsewhere (a list's pick gave the canvas the keyboard): taken, so AppKit doesn't beep")
        expectEqual(log.events, [], "and nothing done")
        expect(h.key(right))
        expect(h.key(right, isRepeat: true))
        h.hold(.shift)
        expect(h.key(right, isRepeat: true), "⇧ pressed while it's held: the same key")
        h.hold([])
        expectEqual(log.events, ["nudge", "nudge", "nudge"])
        expect(h.key(left))
        expect(h.key(right, isRepeat: true), "another key went down since")
        expectEqual(log.events, ["nudge", "nudge", "nudge", "back"])
        expect(h.key(right))
        h.editor.keysReleased()
        expect(h.key(right, isRepeat: true), "the canvas lost the keyboard meanwhile")
        expect(h.key(right))
        h.editor.keyUp(KeyStroke(left))
        expect(h.key(right, isRepeat: true), "another key's release isn't its")
        h.editor.keyUp(KeyStroke(right))
        expect(h.key(right, isRepeat: true), "let go of")
        expectEqual(log.events, ["nudge", "nudge", "nudge", "back", "nudge", "nudge", "nudge"])
    },
])

@MainActor let registrationTests = Suite("Registering shortcuts", [
    test("Keyboard says the toolbar's tip for a tool: its label and the key that switches to it, the label alone for a tool with no key") {
        let registry = try Registry(plugins: [KeyboardPlugin(), TilesPlugin()])
        let hand = try require(registry.tools.first { $0.id == .hand })
        let tile = try require(registry.tools.first { $0.id == ToolID(placing: Tile.kind) })
        expectEqual(registry.toolTip(for: hand), "\(hand.label) (H)")
        expectEqual(registry.toolTip(for: tile), tile.label)
        expectEqual(try Registry(plugins: [TilesPlugin()]).toolTip(for: hand), hand.label, "without Keyboard, a tool's tip is its label")
    },
    test("the Keyboard Shortcuts window's rows: a tool's label, a command's title or a shortcut's own, with its keys, in the order registered; keys under one name are one row, filed with the command if one runs it; the four arrows held alike are one key; then the core's hints") {
        let registry = try Registry(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey, Contributor(id: "x") { r in
            r.command("stamp", title: "Stamp", shortcuts: [KeyChord("s", .command)]) { _ in }
            r.shortcut(.return, "Stamp") { _ in }
            r.shortcut("t", "Tick") { _ in }
            r.command("tick", title: "Tick", shortcuts: ["y"]) { _ in }
            for arrow in [KeyChord.leftArrow, .rightArrow, .upArrow, .downArrow] {
                r.shortcut(arrow, "Nudge") { _ in }
                r.shortcut(KeyChord(arrow.key, .shift), "Nudge") { _ in }
            }
            r.shortcut(KeyChord(KeyChord.upArrow.key, .command), "Up") { _ in }
        }])
        let card = try require(registry.tools.first { $0.id == ToolID(placing: Card.kind) })
        expectEqual(registry.keyboardHelpRows, [
            KeyboardHelpRow(keys: ["H"], title: "Hand", place: .tool),
            KeyboardHelpRow(keys: ["Space"], title: "Pan", place: .canvas),
            KeyboardHelpRow(keys: ["⎋", "⌘."], title: "Cancel", place: .canvas),
            KeyboardHelpRow(keys: ["⌘Z"], title: "Undo", place: .command(.undo)),
            KeyboardHelpRow(keys: ["⇧⌘Z"], title: "Redo", place: .command(.redo)),
            KeyboardHelpRow(keys: ["Q"], title: "Tool Lock", place: .canvas),
            KeyboardHelpRow(keys: ["⌘=", "="], title: "Zoom In", place: .command(.zoomIn)),
            KeyboardHelpRow(keys: ["⌘-", "-"], title: "Zoom Out", place: .command(.zoomOut)),
            KeyboardHelpRow(keys: ["⌘0", "⇧0"], title: "Actual Size", place: .command(.zoomToActualSize)),
            KeyboardHelpRow(keys: ["⇧1"], title: "Zoom to Fit", place: .command(.zoomToFit)),
            KeyboardHelpRow(keys: ["⇞"], title: "Page Up", place: .command(.pageUp)),
            KeyboardHelpRow(keys: ["⇟"], title: "Page Down", place: .command(.pageDown)),
            KeyboardHelpRow(keys: ["↖"], title: "Start of Board", place: .command(.scrollToStart)),
            KeyboardHelpRow(keys: ["↘"], title: "End of Board", place: .command(.scrollToEnd)),
            KeyboardHelpRow(keys: ["C"], title: card.label, place: .tool),
            KeyboardHelpRow(keys: ["⌘S", "↩"], title: "Stamp", place: .command("stamp")),
            KeyboardHelpRow(keys: ["T", "Y"], title: "Tick", place: .command("tick")),
            KeyboardHelpRow(keys: ["←↑→↓", "⇧←↑→↓"], title: "Nudge", place: .canvas),
            KeyboardHelpRow(keys: ["⌘↑"], title: "Up", place: .canvas),
        ])
        expectEqual(Array(registry.keyboardHelp.suffix(2)), [KeyboardHelpRow(keys: ["⇧ Drag"], title: "Move Along One Axis", place: .pointer),
                                                             KeyboardHelpRow(keys: ["⌘ Scroll"], title: "Zoom", place: .pointer)],
                    "the core's hints, which Keyboard says, after the rows")
        let three = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "x") { r in
            for arrow in [KeyChord.leftArrow, .rightArrow, .upArrow] { r.shortcut(arrow, "Most") { _ in } }
        }])
        expectEqual(three.keyboardHelpRows.last?.keys, ["←", "→", "↑"], "three arrows are three keys")
    },
    test("a chord taken twice conflicts, whatever the letter's case, the Hand's H included") {
        expectThrows(RegistryError.conflict(point: "KeyboardShortcuts", key: "shortcut H", plugins: ["keyboard", "clash"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "clash") { $0.shortcut("H", "Mine") { _ in } }])
        }
        expectThrows(RegistryError.conflict(point: "KeyboardShortcuts", key: "shortcut ⌘K", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [KeyboardPlugin(),
                                       Contributor(id: "a") { $0.shortcut(KeyChord("k", .command), "A") { _ in } },
                                       Contributor(id: "b") { $0.command("b", title: "B", shortcuts: [KeyChord("K", .command)]) { _ in } }])
        }
    },
    test("a key for a tool no plugin registers, or a command none claims, is invalid; a key registered without Keyboard installed is an error") {
        expectThrows(RegistryError.invalid(point: "KeyboardShortcuts", reason: "Z switches to tool zap, which no plugin registers")) {
            _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "x") { $0.shortcut("z", forTool: "zap") }])
        }
        expectThrows(RegistryError.invalid(point: "KeyboardShortcuts", reason: "⌘K runs command stamp, which no plugin claims")) {
            _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "x") { $0.shortcut(KeyChord("k", .command), forCommand: "stamp") }])
        }
        _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "x") { $0.shortcut(KeyChord("k", .command), forCommand: .undo) }])
        expectThrows(RegistryError.ownerNotInstalled(point: "KeyboardShortcuts", owner: "keyboard", contributor: "zaps")) {
            _ = try Registry(plugins: [Contributor(id: "zaps") {
                $0.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt"), shortcut: "z") { _ in NoTool() }
            }])
        }
    },
    test("a tool's tooltip names its key; a tool without one is just its label") {
        let registry = try Registry(plugins: [KeyboardPlugin(), CardsPlugin(), cardKey, Contributor(id: "x") {
            $0.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt")) { _ in NoTool() }
        }])
        expectEqual(registry.tools.map { registry.help(for: $0) }, ["Hand (H)", "Card (C)", "Zap"])
        expectEqual(registry.shortcut(forTool: ToolID(placing: Card.kind))?.chord, "c")
    },
    test("a button that runs a command names its first key in its tooltip, as a tool's does; one without a key is just its title") {
        let registry = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "stamps") { r in
            r.command("stamp", title: "Stamp", shortcuts: [KeyChord(KeyChord.upArrow.key, .command), "s"]) { _ in }
            r.command("plain", title: "Plain") { _ in }
        }])
        expectEqual(registry.help("Stamp", forCommand: "stamp"), "Stamp (⌘↑)")
        expectEqual(registry.help("Plain", forCommand: "plain"), "Plain")
        expectEqual(registry.shortcut(forCommand: "stamp")?.chord, KeyChord(KeyChord.upArrow.key, .command))
    },
    test("the tool and command sugar register the key with the tool or command; the report shows each key and what it does") {
        let registry = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", shortcut: "d", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
            }
            r.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt"), shortcut: "z") { _ in NoTool() }
            r.command("stamp", title: "Stamp", shortcuts: [KeyChord("s", .command)]) { _ in }
            r.shortcut(.tab, "Next") { _ in }
        }])
        expectEqual(registry.shortcuts.map(\.action), [.tool(.hand), .custom("Pan"), .custom("Cancel"), .custom("Cancel"), .command(.undo), .command(.redo), .custom("Tool Lock"),
                                                       .command(.zoomIn), .command(.zoomOut), .command(.zoomIn), .command(.zoomOut),
                                                       .command(.zoomToActualSize), .command(.zoomToActualSize), .command(.zoomToFit),
                                                       .command(.pageUp), .command(.pageDown), .command(.scrollToStart), .command(.scrollToEnd),
                                                       .tool(ToolID(placing: Disc.kind)), .tool("zap"), .command("stamp"), .custom("Next")])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        keyboard      service KeyboardState · tool tips · menu keys · keyboard help · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut Q → Tool Lock · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut = → command zoomIn · shortcut - → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit · shortcut ⇞ → command pageUp · shortcut ⇟ → command pageDown · shortcut ↖ → command scrollToStart · shortcut ↘ → command scrollToEnd · key hint ⇧ Drag Move Along One Axis · key hint ⌘ Scroll Zoom
        discs         shape disc · tool disc · shortcut D → tool disc · tool zap · shortcut Z → tool zap · command stamp · shortcut ⌘S → command stamp · shortcut ⇥ → Next
        """)
    },
    test("a command declared with its key in one call: its title, its menu bar item, when it runs and its rule, and the key, which its items show") {
        let log = KeyLog()
        let registry = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "stamps") { r in
            r.command("stamp", title: "Stamp", in: StampSection.self, placed: .first, shortcut: KeyChord("s", [.command, .option]), runs: .whenIdle,
                      isEnabled: { !$0.shapes.isEmpty }) { _ in log.events.append("stamp") }
            r.command("wipe", title: "Wipe", answering: .delete, shortcuts: [.delete, .deleteForward]) { _ in }
        }])
        let stamp = try require(registry.menuBarCommands.first { $0.command == "stamp" })
        expectEqual(stamp.title, "Stamp")
        expectEqual(stamp.menu.titles, ["Arrange"])
        expectEqual(stamp.placement, .first)
        expectEqual(registry.moment(of: "stamp"), .whenIdle)
        expectEqual(stamp.key, MenuKey(key: "s", modifiers: [.command, .option]), "the key the menu keys slot gives: Keyboard's first for it")
        expectEqual(registry.menuKey(of: "wipe"), MenuKey(key: "\u{8}", modifiers: []), "Delete is Backspace's character to a menu")
        expectEqual(registry.menuKeys(of: "wipe"), [MenuKey(key: "\u{8}", modifiers: []), MenuKey(key: "\u{F728}", modifiers: [])],
                    "every key that runs it, in the order registered, the one its items show first")
        expectEqual(registry.menuKeys(of: "stamp"), [MenuKey(key: "s", modifiers: [.command, .option])])
        expectEqual(registry.command(answering: .delete), "wipe")
        expectEqual(registry.menuKey(of: "nobody"), nil)
        expectEqual(registry.menuKeys(of: "nobody"), [])
        expectEqual(registry.shortcuts.filter { $0.commands == ["wipe"] }.map(\.chord), [.delete, .deleteForward])
    },
    test("one key for two commands that are never both possible runs the one that can, passes while neither can, shows on both, and is one row named as said") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "pins") { r in
            r.command("pin", title: "Pin", isEnabled: { _ in !log.armed }) { _ in log.events.append("pin"); log.armed = true }
            r.command("unpin", title: "Unpin", isEnabled: { _ in log.armed }) { _ in log.events.append("unpin"); log.armed = false }
            r.command("never", title: "Never", isEnabled: { _ in false }) { _ in }
            r.shortcut(KeyChord("p", .shift), "Pin or Unpin", forCommands: ["pin", "unpin"])
            r.shortcut(KeyChord("n", .shift), "Never Mind", forCommands: ["never"])
        }])
        h.hold(.shift)
        expect(h.key("P"))
        expect(h.key("P"))
        expect(h.key("P"))
        expectEqual(log.events, ["pin", "unpin", "pin"])
        expect(!h.key("N"), "neither can run: the key goes on")
        h.hold([])
        let registry = h.editor.registry
        expectEqual(registry.shortcut(forCommand: "pin")?.chord, KeyChord("p", .shift))
        expectEqual(registry.shortcut(forCommand: "unpin")?.chord, KeyChord("p", .shift))
        expectEqual(registry.menuKey(of: "unpin"), MenuKey(key: "p", modifiers: .shift), "each command's items show it")
        expectEqual(registry.keyboardHelpRows.first { $0.keys == ["⇧P"] }, KeyboardHelpRow(keys: ["⇧P"], title: "Pin or Unpin", place: .command("pin")))
        expectEqual(registry.shortcuts.first { $0.chord == KeyChord("p", .shift) }?.action, .commands(["pin", "unpin"]))
        expect(registry.report.contains("shortcut ⇧P → command pin or unpin"), registry.report)
        expectThrows(RegistryError.invalid(point: "KeyboardShortcuts", reason: "⇧Q runs command gone, which no plugin claims")) {
            _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "x") { r in
                r.command("pin", title: "Pin") { _ in }
                r.shortcut(KeyChord("q", .shift), "Pin or Gone", forCommands: ["pin", "gone"])
            }])
        }
    },
    test("a chord is its key, lowercased, and its modifiers; it describes itself as menus show it") {
        expectEqual(KeyChord("V"), "v")
        expect(KeyChord("v") != KeyChord("v", .shift))
        let chords: [KeyChord] = ["v", KeyChord("g", [.shift, .command]), KeyChord("a", [.command, .shift, .option, .control]),
                                  KeyChord(".", .command), .escape, .return, .enter, .delete, .deleteForward, .tab, .space,
                                  .upArrow, .downArrow, .leftArrow, .rightArrow]
        expectEqual(chords.map(\.description), ["V", "⇧⌘G", "⌃⌥⇧⌘A", "⌘.", "⎋", "↩", "⌤", "⌫", "⌦", "⇥", "Space", "↑", "↓", "←", "→"])
    },
])

/// Arrange's section a test's command is in.
private enum StampSection {}
extension StampSection: MenuBarSection {
    static var menu: MenuBarMenu { "Arrange" }
}
