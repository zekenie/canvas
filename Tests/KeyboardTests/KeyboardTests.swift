@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import HostSlots
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
        expect(!h.key("q"))
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
            r.command("stamp", shortcuts: [KeyChord("s", .command), .deleteForward]) { _ in log.events.append("stamp") }
        }])
        h.hold(.command)
        expect(h.key("s"))
        h.hold([])
        expect(!h.key("s"), "⌘S, not S")
        expect(h.key("\u{F728}"))
        expect(h.editor.perform("stamp"))
        expectEqual(log.events, ["stamp", "stamp", "stamp"])
    },
    test("a command's keys pass while it can't run, as its menu item is dimmed then") {
        let log = KeyLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), Contributor(id: "stamps") { r in
            r.command("stamp", shortcuts: ["s"], isEnabled: { _ in log.armed }) { _ in log.events.append("stamp") }
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
    test("a chord taken twice conflicts, whatever the letter's case, the Hand's H included") {
        expectThrows(RegistryError.conflict(point: "KeyboardShortcuts", key: "shortcut H", plugins: ["keyboard", "clash"])) {
            _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "clash") { $0.shortcut("H", "Mine") { _ in } }])
        }
        expectThrows(RegistryError.conflict(point: "KeyboardShortcuts", key: "shortcut ⌘K", plugins: ["a", "b"])) {
            _ = try Registry(plugins: [KeyboardPlugin(),
                                       Contributor(id: "a") { $0.shortcut(KeyChord("k", .command), "A") { _ in } },
                                       Contributor(id: "b") { $0.command("b", shortcuts: [KeyChord("K", .command)]) { _ in } }])
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
            r.command("stamp", shortcuts: [KeyChord(KeyChord.upArrow.key, .command), "s"]) { _ in }
            r.command("plain") { _ in }
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
            r.command("stamp", shortcuts: [KeyChord("s", .command)]) { _ in }
            r.shortcut(.tab, "Next") { _ in }
        }])
        expectEqual(registry.shortcuts.map(\.action), [.tool(.hand), .custom("Pan"), .custom("Cancel"), .custom("Cancel"), .command(.undo), .command(.redo),
                                                       .command(.zoomIn), .command(.zoomOut), .command(.zoomToActualSize), .command(.zoomToFit),
                                                       .tool(ToolID(placing: Disc.kind)), .tool("zap"), .command("stamp"), .custom("Next")])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn · command zoomOut · command zoomToActualSize · command zoomToFit
        keyboard      service KeyboardState · tool tips · key strokes · key releases · shortcut H → tool hand · shortcut Space → Pan · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel · shortcut ⌘Z → command undo · shortcut ⇧⌘Z → command redo · shortcut ⌘= → command zoomIn · shortcut ⌘- → command zoomOut · shortcut ⌘0 → command zoomToActualSize · shortcut ⇧1 → command zoomToFit
        discs         shape disc · tool disc · shortcut D → tool disc · tool zap · shortcut Z → tool zap · command stamp · shortcut ⌘S → command stamp · shortcut ⇥ → Next
        """)
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
