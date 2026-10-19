@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Find
import Keyboard
import Selection
import TestKit

@MainActor let pointTests = Suite("Findable texts", [
    test("the report shows each contribution by its name and kinds") {
        let registry = try Registry(plugins: findPlugins(more: [BadgesPlugin()]))
        let lines = Dictionary(registry.report.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "")
        }, uniquingKeysWith: { first, _ in first })
        expectEqual(lines["memos"], "shape memo · findable body → memo")
        expectEqual(lines["badges"], "findable badge → every shape that is a box")
        expectEqual(lines["find-in-boards"], "service FindState · overlay FindOverlay · command find in Edit › Find · shortcut ⌘F → command find · command findNext in Edit › Find · shortcut ⌘G → command findNext · command findPrevious in Edit › Find · shortcut ⇧⌘G → command findPrevious")
    },
    test("two contributions of one name to one kind conflict; a blank name is refused; a list without Find refuses any") {
        let twice = Contributor(id: "twice") { registrar in
            registrar.findableTexts("body", of: Memo.self, texts: { _, _ in [] }, rects: { _, _, ranges, _ in ranges.map { _ in [] } })
        }
        do {
            _ = try Registry(plugins: findPlugins(more: [twice]))
            expect(false, "a second body on memos")
        } catch RegistryError.conflict {}
        let blank = Contributor(id: "blank") { registrar in
            registrar.forEveryShape { scope in
                scope.findableTexts(" ", texts: { _, _ in [] }, rects: { _, _, ranges, _ in ranges.map { _ in [] } })
            }
        }
        do {
            _ = try Registry(plugins: findPlugins(more: [blank]))
            expect(false, "a blank name")
        } catch RegistryError.invalid {}
        do {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), MemosPlugin()])
            expect(false, "memos contribute to Find, which isn't installed")
        } catch RegistryError.ownerNotInstalled {}
    },
    test("an every-shape contribution goes only on the kinds its where picks") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))),
                                                                       AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 100, y: 0, width: 50, height: 50))))])),
                                more: [BadgesPlugin()])
        let find = try search("badge", in: h)
        expectEqual(find.results.count, 1, "the box's, not the disc's")
        expectEqual(find.texts(of: find.found[0]), ["Badge 50"])
    },
])

@MainActor let indexTests = Suite("Find's index", [
    test("before the first ⌘F it reads nothing, a commit costing a revision noted") {
        let plugin = MemosPlugin()
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["alpha", "beta"]))), memos: plugin)
        let find = try require(h.editor.find)
        h.editor.transact { $0.insert(ShapeRecord(Memo(CGRect(x: 0, y: 0, width: 10, height: 10), "gamma"))) }
        expectEqual(find.recordsRead, 0)
        expectEqual(plugin.textsRead, 0)
        expectEqual(find.indexedShapes, 0)
        _ = try search("gamma", in: h)
        expectEqual(find.indexedShapes, 3)
    },
    test("it's built in slices of the main actor, on the scheduler, the field's spinner on meanwhile") {
        let many = (0..<4000).map { "memo number \($0) says something" }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(many))))
        let find = try require(h.editor.find)
        find.open()
        expect(find.isIndexing, "a build this size takes more than a slice")
        expect(h.scheduler.pendingCount > 0, "the next slice waits its turn")
        try settle(find, h)
        expect(!find.isIndexing)
        expect(find.indexSlices.count > 1, "\(find.indexSlices.count) slices")
        expectEqual(find.indexedShapes, 4000)
    },
    test("a commit reads again only what it changed: a move reads nothing, an edit its shape, a new shape and a deleted one theirs") {
        let ids = (0..<3).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["alpha", "beta", "gamma"], ids: ids))))
        let find = try search("alpha", in: h)
        let read = find.recordsRead
        h.editor.transact { $0.moveBox(ids[1], to: CGPoint(x: 900, y: 900)) }
        expectEqual(find.recordsRead, read, "a move reads nothing")
        h.editor.transact { $0.update(ids[1], as: Memo.self) { $0.props.body = "alphabet" } }
        expectEqual(find.recordsRead, read + 1)
        try settle(find, h)
        expectEqual(find.found, [ids[0], ids[1]])
        h.editor.transact { $0.delete([ids[0]]) }
        try settle(find, h)
        expectEqual(find.found, [ids[1]])
        expectEqual(find.indexedShapes, 2)
    },
    test("a change on another board (elsewhere) is read; a pocket deleted takes its boards' texts out") {
        let pockets = PocketFile(root: ["root alpha"], inA: ["a alpha"], inA1: ["a1 alpha"], inB: ["b beta"])
        let h = try findHarness(pockets.file)
        let find = try search("alpha", in: h)
        expectEqual(find.results.count, 3)
        let inB = pockets.inB[0].id
        _ = h.editor.transact(on: pockets.bBoard) { $0.update(inB, as: Memo.self) { $0.props.body = "b alpha" } }
        try settle(find, h)
        expectEqual(find.results.count, 4, "the change on B's board, which isn't shown")
        h.editor.transact { $0.delete([pockets.a]) }
        try settle(find, h)
        expectEqual(find.found, [pockets.root[0].id, inB], "A's board and A1's went with it")
        expectEqual(find.indexedShapes, 2)
        h.editor.undo()
        try settle(find, h)
        expectEqual(find.results.count, 4, "undone: back")
    },
    test("a shape whose text another's change changes (affected) is read again") {
        let target = ShapeID(), echo = ShapeID()
        let records = [AnyShapeRecord(ShapeRecord(id: target, Memo(CGRect(x: 100, y: 100, width: 160, height: 40), "plain"))),
                       AnyShapeRecord(ShapeRecord(id: echo, Memo(CGRect(x: 300, y: 100, width: 160, height: 40), "echo", echo: target)))]
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: records)))
        let find = try search("zebra", in: h)
        expect(find.results.isEmpty)
        h.editor.transact { $0.update(target, as: Memo.self) { $0.props.body = "zebra" } }
        try settle(find, h)
        expectEqual(find.found, [target, echo], "the echo shows the target's new text")
    },
])
