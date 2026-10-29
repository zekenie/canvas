import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import ShippedTesting
import TestKit

// Arrange's commands over many shapes at once (`Transaction.bringToFront(_:)`, `sendToBack(_:)`, `bringForward(_:)` and
// `sendBackward(_:)`): each shape restacked in turn over a replay of the stack, and the board changed once (`StackReplay`),
// so a board's worth costs the board and not, for each shape, the shapes it passes. On the generated board
// (`generatedBoard`), the shipped list's services hearing each commit.

extension Budget {
    /// One of Arrange's commands over every shape of a board of 10,000, every other or every tenth, in one commit: the
    /// thread's CPU, release. Some 130 to 145 ms for every shape brought to the front or sent to the back (each one's
    /// key made, the board changed once, and every service hearing 10,000 shapes changed), 65 to 70 for every other,
    /// 30 to 50 for the steps (every shape's bounds), where restacking each in the stack in turn took 2.6 s to bring
    /// every shape to the front and 23 s to send every tenth back a step (2026-10-29, quiet).
    static let restackMany = 300.0
}

@MainActor let restackingBenchmarks = Suite("Restacking benchmarks", [
    test("Arrange's commands over many shapes restack them in one pass: every shape, every other and every tenth") {
        let registry = try ShippedPlugins.registry(model: ScriptedLanguageModel())
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let h = EditorHarness { CanvasEditor(registry: registry, document: document, scheduler: $0) }
            let editor = h.editor
            let all = editor.document.shapes.map(\.id)
            let half = all.enumerated().compactMap { $0.offset % 2 == 0 ? $0.element : nil }
            let tenth = all.enumerated().compactMap { $0.offset % 10 == 0 ? $0.element : nil }
            let commands: [(name: String, ids: [ShapeID], restack: (inout Transaction, [ShapeID]) -> Void)] = [
                ("every shape brought to the front", all, { $0.bringToFront($1) }),
                ("every shape sent to the back", all, { $0.sendToBack($1) }),
                ("every shape brought forward", all, { $0.bringForward($1) }),
                ("every shape sent backward", all, { $0.sendBackward($1) }),
                ("every other shape brought to the front", half, { $0.bringToFront($1) }),
                ("every other shape sent to the back", half, { $0.sendToBack($1) }),
                ("every tenth shape brought forward", tenth, { $0.bringForward($1) }),
                ("every tenth shape sent backward", tenth, { $0.sendBackward($1) }),
            ]
            for command in commands {
                let cost = median(runs: 1, onThread: true) { editor.transact(command.name) { command.restack(&$0, command.ids) } }
                report(String(format: "%7d shapes, %@: %8.1f ms (budget %.0f)", size, command.name, cost, Budget.restackMany))
                if holdsToBudgets, size >= 10_000 { expect(cost < Budget.restackMany, "\(command.name) over \(size) shapes took \(cost) ms") }
            }
        }
    },
])
