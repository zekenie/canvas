@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SlashCommands
import TestKit

// A kit's slash commands (Kits.swift): while the kit a plugin joined is off in the file, `/` lists none of its
// commands, for a shape's text, a selection or every shape, and none runs; a command typed for a declared one
// whose plugin's kit is off isn't offered, by its rule or by `when` alone. Turned on, each is back.

/// The workshop's commands, from a plugin in the kit: `plane` on boxes, which widens them, and `sweep`, about
/// every shape at once.
@MainActor private func workshopCommands() -> Contributor {
    Contributor(id: "workshop-commands") { r in
        r.join(Workshop.self)
        r.slashCommands(Box.self) { SlashCommand("plane") { box, _ in box.frame.size.width += 10 } }
        r.selectionSlashCommand(.atOnce("sweep", when: { target, _ in
            if case .everything = target { return true }
            return false
        }) { _, _, _ in })
    }
}

/// Commands of no kit's that run the workshop's Carve, as typed: by its rule, and by `when` alone.
@MainActor private func carveCommands() -> Contributor {
    Contributor(id: "carve-commands") { r in
        r.slashCommands(Box.self) {
            SlashCommand("carve-it", command: .carve)
            SlashCommand("carve-try", command: .carve, tries: true)
        }
    }
}

@MainActor let slashKitTests = Suite("A kit's slash commands", [
    test("while the kit is off, / lists none of its commands and none of those typed for its declared command; on, they're listed and run") {
        let carves = WorkshopLog()
        let h = try slashHarness([WorkshopPlugin(log: carves), workshopCommands(), carveCommands()])
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let state = try require(h.editor.slashCommands)
        @MainActor func names(_ target: SlashTarget) -> [String] { state.commands(for: target).map { $0.name } }
        let kits = ["plane", "sweep", "carve-it", "carve-try"]
        for target in [SlashTarget.text(box), .selection([box]), .everything([box])] {
            expect(!names(target).contains(where: kits.contains), "\(target): \(names(target))")
        }
        expect(!state.run("plane", for: .selection([box]), with: SlashArguments([])), "nor does one run")
        expectEqual(h.editor.document[box]?.box?.width, 100)
        h.editor.turn(Workshop.self, on: true)
        expect(names(.text(box)).contains("plane") && names(.selection([box])).contains("carve-it") && names(.selection([box])).contains("carve-try"))
        expect(names(.everything([box])).contains("sweep"))
        expect(state.run("plane", for: .selection([box]), with: SlashArguments([])))
        expectEqual(h.editor.document[box]?.box?.width, 110)
        expect(state.run("carve-it", for: .selection([box]), with: SlashArguments([])))
        expectEqual(carves.carved, 1)
        h.editor.turn(Workshop.self, on: false)
        expect(!names(.selection([box])).contains(where: kits.contains), "off again")
    },
])
