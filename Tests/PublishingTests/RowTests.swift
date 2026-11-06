@_spi(Host) import Canvas
import CanvasTesting
import SwiftUI
import TableOfContents
import TestKit

// The crossed eye at the end of a private shape's row in the table of contents: which shapes are
// private at a glance, as on the canvas. A public shape's row has none, however many things stand for
// it (Connections lists them).

@MainActor let rowTests = Suite("A private shape's row", [
    test("a private shape's row ends in the crossed eye, saying Private; a public one's has none") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let contents = try require(h.editor.tableOfContents)
        @MainActor func marks(_ id: ShapeID) -> [ContentsMark] { contents.entries.first { $0.id == id }?.marks ?? [] }
        expectEqual(marks(a), [], "public, as every shape starts")
        h.conceal(a)
        expectEqual(marks(a), [ContentsMark(symbol: "eye.slash", color: .secondary, help: "Private")])
        expectEqual(marks(b), [], "only the private one")
        h.publish(a)
        expectEqual(marks(a), [], "public again")
        h.editor.undo()
        expectEqual(marks(a).map(\.help), ["Private"], "undo")
    },
    test("what stands for a public shape doesn't mark its row") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame))
        h.hold([a])
        let lens = h.lens("what", answering: [a])
        let contents = try require(h.editor.tableOfContents)
        @MainActor func marks() -> [ContentsMark] { contents.entries.first { $0.id == a }?.marks ?? [] }
        expectEqual(marks(), [])
        h.provide(lens, "what", [], revision: 2)
        expectEqual(marks(), [])
    },
    test("a seal (always public) and a draft have no mark: there's nothing to toggle") {
        let h = try publishingHarness()
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.conceal(seal, draft)
        let contents = try require(h.editor.tableOfContents)
        expectEqual(contents.entries.filter { [seal, draft].contains($0.id) }.flatMap(\.marks), [])
    },
])
