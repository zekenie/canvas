import Canvas
import CanvasTesting
import CoreGraphics
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
            r.shortcut(KeyChord("z", .command), "Undo") { _ in log.events.append("⌘z") }
        }])
        h.key("d")
        h.hold(.shift)
        h.key("D")
        h.key("E")
        h.key("?")                              // ⇧/, on a US keyboard
        h.hold([.shift, .command])
        expect(!h.key("Z"), "⇧⌘Z isn't ⌘Z")
        h.hold(.command)
        h.key("z")
        h.hold(.option)
        expect(!h.key("e"), "⌥E isn't E")
        h.hold([])
        expectEqual(log.events, ["d", "⇧d", "e", "?", "⌘z"])
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
])

@MainActor let registrationTests = Suite("Registering shortcuts", [
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
    test("a key for a tool no plugin registers is invalid; a key registered without Keyboard installed is an error") {
        expectThrows(RegistryError.invalid(point: "KeyboardShortcuts", reason: "Z switches to tool zap, which no plugin registers")) {
            _ = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "x") { $0.shortcut("z", forTool: "zap") }])
        }
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
    test("the tool and command sugar register the key with the tool or command; the report shows each key and what it does") {
        let registry = try Registry(plugins: [KeyboardPlugin(), Contributor(id: "discs") { r in
            r.shape(DiscDefinitionForTests()) { disc in
                disc.tool(label: "Disc", systemImage: "circle", shortcut: "d", placing: disc.placement(size: CGSize(width: 40, height: 40)) { Disc(.zero) })
            }
            r.tool(ToolDescriptor(id: "zap", label: "Zap", systemImage: "bolt"), shortcut: "z") { _ in NoTool() }
            r.command("stamp", shortcuts: [KeyChord("s", .command)]) { _ in }
            r.shortcut(.space, "Pan") { _ in }
        }])
        expectEqual(registry.shortcuts.map(\.action), [.tool(.hand), .custom("Cancel"), .custom("Cancel"), .tool(ToolID(placing: Disc.kind)),
                                                       .tool("zap"), .command("stamp"), .custom("Pan")])
        expectEqual(registry.report, """
        core          tool hand
        keyboard      service KeyboardState · key strokes · shortcut H → tool hand · shortcut ⎋ → Cancel · shortcut ⌘. → Cancel
        discs         shape disc · tool disc · shortcut D → tool disc · tool zap · shortcut Z → tool zap · command stamp · shortcut ⌘S → command stamp · shortcut Space → Pan
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
