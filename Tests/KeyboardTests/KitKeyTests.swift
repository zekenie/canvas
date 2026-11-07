@_spi(Host) import Canvas
import CanvasTesting
import Keyboard
import TestKit

// A kit's keys (Kits.swift): while the kit a plugin joined is off in the file, its keys pass, a tool's, a
// command's and its own; on, they take the key. Their chords stay claimed either way, and the Keyboard
// Shortcuts window's rows leave out an off kit's.

/// The workshop's keys, from a plugin in the kit: P its plank tool, C its Carve, J a jig of its own.
@MainActor private func workshopKeys(_ log: KeyLog) -> Contributor {
    Contributor(id: "workshop-keys") { r in
        r.join(Workshop.self)
        r.shortcut("p", forTool: ToolID(placing: Plank.kind))
        r.shortcut("c", forCommand: .carve)
        r.shortcut("j", "Jig") { _ in log.events.append("jig") }
    }
}

@MainActor let kitKeyTests = Suite("A kit's keys", [
    test("while the kit is off, its tool's key, its command's and its own pass; turned on, they take the key; off again, they pass") {
        let log = KeyLog(), carves = WorkshopLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), FixturesPlugin(), WorkshopPlugin(log: carves), workshopKeys(log)])
        expect(!h.key("p") && !h.key("c") && !h.key("j"), "every key passes")
        expectEqual(h.editor.currentToolID, .hand)
        expectEqual(carves.carved, 0)
        expectEqual(log.events, [])
        h.editor.turn(Workshop.self, on: true)
        expect(h.key("p"))
        expectEqual(h.editor.currentToolID, ToolID(placing: Plank.kind))
        expect(h.key("c"))
        expectEqual(carves.carved, 1)
        expect(h.key("j"))
        expectEqual(log.events, ["jig"])
        h.editor.undo()
        expect(!h.key("c") && !h.key("j"), "the kit off again")
        expectEqual(carves.carved, 1)
    },
    test("a kit's chord is claimed whether it's on or off: another plugin can't take it") {
        let taken = Contributor(id: "taken") { $0.shortcut("j", "Jog") { _ in } }
        do {
            _ = try Registry(plugins: [KeyboardPlugin(), FixturesPlugin(), WorkshopPlugin(), workshopKeys(KeyLog()), taken])
            expect(false, "two claims to J")
        } catch {
            expect("\(error)".contains("shortcut J"), "\(error)")
        }
    },
    test("the Keyboard Shortcuts window's rows leave out an off kit's keys") {
        let registry = try Registry(plugins: [KeyboardPlugin(), FixturesPlugin(), WorkshopPlugin(), workshopKeys(KeyLog())])
        let off = registry.keyboardHelp(kitsOn: []).map(\.title), on = registry.keyboardHelp(kitsOn: [Workshop.id]).map(\.title)
        expect(!off.contains("Plank") && !off.contains("Carve") && !off.contains("Jig"), "\(off)")
        expect(on.contains("Plank") && on.contains("Carve") && on.contains("Jig"), "\(on)")
        expectEqual(off.filter { !on.contains($0) }, [], "nothing but the kit's is left out")
    },
])
