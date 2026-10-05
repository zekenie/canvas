@_spi(Host) import Canvas
import CanvasTesting
import Publishing
import SwiftUI
import TableOfContents
import TestKit

// The globe at the end of a public shape's row in the table of contents: which shapes are public at
// a glance, and how many things stand for each.

@MainActor let rowTests = Suite("A public shape's row", [
    test("a public shape's row ends in a globe, saying Public, and how many references once any; a private one's has none") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame)), b = h.add(Plaque(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let contents = try require(h.editor.tableOfContents)
        @MainActor func marks(_ id: ShapeID) -> [ContentsMark] { contents.entries.first { $0.id == id }?.marks ?? [] }
        expectEqual(marks(a), [])
        h.publish(a)
        expectEqual(marks(a), [ContentsMark(symbol: "globe", color: .secondary, help: "Public")])
        expectEqual(marks(b), [], "only the public one")
        let holder = h.hold([a])
        expectEqual(marks(a).map(\.help), ["Public · 1 reference"], "its row is made again as something comes to stand for it")
        h.hold([a])
        h.lens("what", answering: [a])
        expectEqual(marks(a).map(\.help), ["Public · 3 references"])
        h.editor.transact { $0.delete([holder]) }
        expectEqual(marks(a).map(\.help), ["Public · 2 references"])
        h.editor.undo()
        expectEqual(marks(a).map(\.help), ["Public · 3 references"])
    },
    test("an answer provided with no commit changes the mark too") {
        let h = try publishingHarness()
        let a = h.add(Plaque(plaqueFrame))
        h.publish(a)
        let lens = h.lens("what")
        let contents = try require(h.editor.tableOfContents)
        @MainActor func help() -> [String] { contents.entries.first { $0.id == a }?.marks.map(\.help) ?? [] }
        expectEqual(help(), ["Public"])
        h.provide(lens, "what", [a])
        expectEqual(help(), ["Public · 1 reference"])
        h.provide(lens, "what", [], revision: 2)
        expectEqual(help(), ["Public"])
    },
    test("a seal (always public) and a draft have no mark: there's nothing to toggle") {
        let h = try publishingHarness()
        let seal = h.add(Seal(plaqueFrame)), draft = h.add(Draft(CGRect(x: 300, y: 100, width: 100, height: 100)))
        let contents = try require(h.editor.tableOfContents)
        expectEqual(contents.entries.filter { [seal, draft].contains($0.id) }.flatMap(\.marks), [])
    },
])
