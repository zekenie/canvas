@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import JumpTo
import TestKit
import Titles

// The catalog of titled shapes a query is ranked from: lazy (nothing before the first ⌘K), read in
// slices, and kept up to date by what each commit changed.

/// Twelve titled shapes: the story's, less the one on a board the app can't show (Orphan) and the
/// untitled ones.
private let storyTitled = 12

@MainActor private func bigFile(_ count: Int) -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: (0..<count).map { shape(1000 + $0, Box(frame(CGFloat($0 % 50) * 120, CGFloat($0 / 50) * 80)), titled: "Box \($0)") }))
}

/// Moves a shape a point whenever a commit changes it other than by moving it: a service that commits
/// while hearing a commit, ahead of Jump To, so Jump To hears the move before the commit it answers.
final class JumpNudger {}

extension JumpNudger: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        let changed = changes.changed.subtracting(changes.moved)
        guard !changed.isEmpty else { return }
        editor.transact { $0.translate(changed, by: CGPoint(x: 1, y: 0)) }
    }
}

/// The story's plugins with a nudger ahead of Jump To.
@MainActor private func nudgedPlugins() -> [any CanvasPlugin] {
    var plugins = jumpPlugins()
    let at = plugins.firstIndex { $0.id == .jumpTo }!
    plugins.insert(Contributor(id: "jump-nudges") { $0.service { _ in JumpNudger() } }, at: at)
    return plugins
}

@MainActor let catalogTests = Suite("Jump To's catalog", [
    test("nothing is read before the first ⌘K: commits cost a note of their revision, whatever they change") {
        let h = try storyHarness()
        h.editor.rename(id(41), "Cashier", on: BoardID(owner: id(2)))
        h.add(Box(frame(0, 0)))
        h.editor.transact { $0.delete([id(3)]) }
        expectEqual(h.jump.entriesRead, 0)
        expectEqual(h.jump.catalogCount, 0)
        expect(!h.jump.isReady && !h.jump.isOpen)
        expect(h.openJumpTo())
        expect(h.jump.isOpen && h.jump.isReady, "a file this small is read in the first slice")
        expectEqual(h.jump.catalogCount, storyTitled - 1, "as the file is now: Plan note one is gone")
        expectEqual(h.listing("cashier"), ["41"])
    },
    test("it holds every titled shape on every board the app can show, named or derived: none untitled, none on a board it can't") {
        let h = try storyHarness()
        h.openJumpTo()
        expectEqual(h.jump.catalogCount, storyTitled)
        for text in ["orphan", "untitled"] { expectEqual(h.listing(text), ["(No matches)"], text) }
        // A derived title: the card's text, read from it.
        let derived = try storyHarness(file: CanvasFile(root: CanvasDocument(shapes: [])))
        derived.editor.add(Card(frame(0, 0), text: "Receipt"))
        expectEqual(derived.listing("receipt"), ["(No matches)"], "a kind with no title isn't listed")
    },
    test("a move reads nothing; a rename reads the one shape, and it's found by its new name; a shape added is read") {
        let h = try storyHarness()
        h.openJumpTo()
        let read = h.jump.entriesRead
        h.editor.transact { $0.moveBox(id(1), to: CGPoint(x: 300, y: 300)) }
        h.editor.transact { $0.moveBox(id(1), to: CGPoint(x: 310, y: 300)) }
        expectEqual(h.jump.entriesRead, read, "a drag's events change no title")
        h.editor.rename(id(1), "Omega", on: .root)
        expectEqual(h.jump.entriesRead, read + 1)
        expectEqual(h.listing("omega"), ["1"])
        expectEqual(h.listing("alpha"), ["(No matches)"])
        h.jump.setQuery("")
        h.editor.add(Box(frame(0, 0)), id: id(60))
        expectEqual(h.jump.entriesRead, read + 2, "an added shape is read (untitled: it's no entry)")
        expectEqual(h.jump.catalogCount, storyTitled)
        h.editor.transact { $0.update(id(60)) { $0[TitleProperty.self] = "Quokka" } }
        expectEqual(h.listing("quokka"), ["60"])
        h.editor.transact { $0.update(id(60)) { $0[TitleProperty.self] = nil } }
        expectEqual(h.listing("quokka"), ["(No matches)"], "its title cleared: no entry")
    },
    test("a rename of a container changes the path of what's inside it, though nothing inside it changed") {
        let h = try storyHarness()
        expectEqual(h.candidates("checkout").first { number(of: $0.id) == 12 }?.pathText, "Alpha")
        let read = h.jump.entriesRead
        h.editor.rename(id(1), "Omega", on: .root)
        expectEqual(h.jump.entriesRead, read + 1, "only the container's title is read")
        expectEqual(h.candidates("checkout").first { number(of: $0.id) == 12 }?.pathText, "Omega")
        expectEqual(h.listing("omega checkout"), ["12", "22", "31"])
    },
    test("shapes on other boards are kept as commits reach them: a rename there (transact(on:)), and a pocket deleted takes its boards' shapes out, its undo brings them back") {
        let h = try storyHarness()
        h.openJumpTo()
        let beta = BoardID(owner: id(11))
        h.editor.rename(id(21), "Omega", on: beta)
        expectEqual(h.listing("omega"), ["21"])
        let held = h.jump.catalogCount
        // Alpha, with Beta and everything under it: 11, 12, 21, 22, 23, 31 (and 1 itself).
        h.editor.transact { $0.delete([id(1)]) }
        expectEqual(h.jump.catalogCount, held - 7)
        expectEqual(h.listing("checkout"), ["41"])
        h.editor.undo()
        expectEqual(h.jump.catalogCount, held)
        expectEqual(h.listing("checkout"), ["12", "41", "22", "31"])
        expectEqual(h.listing("omega"), ["21"], "and as it was named")
    },
    test("a shape put in a corral, or taken out of one, and a container moved into another, change the paths of what's in them, as they're listed and ranked") {
        let h = try storyHarness()
        @MainActor func path(_ n: Int, _ text: String = "checkout") -> String? { h.candidates(text).first { number(of: $0.id) == n }?.pathText }
        let beta = BoardID(owner: id(11))
        expectEqual(path(22), "Alpha › Beta › Gamma")
        h.editor.transact(on: beta, "Take") { $0.setContainer(id(22), to: nil) }
        expectEqual(path(22), "Alpha › Beta", "taken out of the corral")
        expect(!h.listing("gamma checkout").contains("22"), "no longer ranked by Gamma")
        h.editor.transact(on: beta, "Put") { $0.setContainer(id(22), to: id(21)) }
        expectEqual(path(22), "Alpha › Beta › Gamma", "put back")
        // A shape added to Beta, then put in the corral.
        h.editor.transact(on: beta, "Add") { $0.insert(shape(60, Box(frame(300, 300)), titled: "Checkout")) }
        expectEqual(path(60), "Alpha › Beta")
        h.editor.transact(on: beta, "Put") { $0.setContainer(id(60), to: id(21)) }
        expectEqual(path(60), "Alpha › Beta › Gamma")
        // A container taken out of one, and into another: what's inside it keeps its place in it.
        expectEqual(path(31), "Alpha › Beta › Gamma › Epsilon")
        h.editor.transact(on: beta, "Take") { $0.setContainer(id(23), to: nil) }
        expectEqual(path(31), "Alpha › Beta › Epsilon")
        h.editor.transact(on: beta, "Add") { $0.insert(shape(24, Corral(CGRect(x: 0, y: 2000, width: 4000, height: 900)), titled: "Kappa")) }
        h.editor.transact(on: beta, "Put") { $0.setContainer(id(23), to: id(24)) }
        expectEqual(path(31), "Alpha › Beta › Kappa › Epsilon")
        expectEqual(h.listing("kappa epsilon checkout").first, "31")
        expectEqual(h.listing("gamma epsilon checkout"), ["(No matches)"], "Gamma no longer holds Epsilon")
        h.editor.undo()
        expectEqual(path(31), "Alpha › Beta › Epsilon")
    },
    test("a commit heard out of turn, after one a service made while hearing it, reads the file again") {
        let h = try storyHarness()
        h.openJumpTo()
        var read = h.jump.entriesRead
        h.editor.rename(id(1), "Omega", on: .root)
        expectEqual(h.jump.entriesRead - read, 1, "heard in turn: the one shape")
        let nudged = try EditorHarness(plugins: nudgedPlugins(), file: storyFile())
        nudged.editor.viewportDidResize(to: viewSize)
        nudged.openJumpTo()
        read = nudged.jump.entriesRead
        // The nudger hears the rename first and moves the shape: that commit reaches Jump To before
        // the rename does, a revision ahead of what it has heard.
        nudged.editor.rename(id(1), "Omega", on: .root)
        expect(nudged.jump.entriesRead - read >= storyTitled, "read again: \(nudged.jump.entriesRead - read)")
        expectEqual(nudged.listing("omega checkout"), ["12", "22", "31"])
        expectEqual(nudged.listing("alpha"), ["(No matches)"])
        expectEqual(nudged.jump.catalogCount, storyTitled)
    },
    test("a commit that reaches a shape on a board the app can't show doesn't list it; a pick of a shape that's not in the file is nothing") {
        let h = try storyHarness()
        h.openJumpTo()
        let held = h.jump.catalogCount
        // A paste brings a pocket's board, and a box's, which the app doesn't show.
        h.editor.transact { $0.insert(shape(70, Box(frame(0, 800))), contents: [id(70): CanvasDocument(shapes: [shape(92, Box(frame(0, 0)), titled: "Zebra")])]) }
        h.editor.transact { $0.insert(shape(71, Pocket(frame(200, 800))), contents: [id(71): CanvasDocument(shapes: [shape(93, Box(frame(0, 0)), titled: "Yak")])]) }
        expectEqual(h.jump.catalogCount, held + 1)
        expectEqual(h.listing("zebra"), ["(No matches)"])
        expectEqual(h.listing("yak"), ["93"])
        h.editor.rename(id(41), "Zebra", on: BoardID(owner: id(2)))
        expectEqual(h.listing("zebra"), ["41"])
        h.jump.pick(id(999))
        expect(h.jump.recent.isEmpty, "nothing to follow, so no recent pick")
        expect(h.jump.isOpen)
    },
    test("a document replaced, and a file put in place, are read again") {
        let h = try storyHarness()
        h.openJumpTo()
        expectEqual(h.jump.catalogCount, storyTitled)
        var shapes = h.editor.document.shapes
        shapes[1] = shape(2, Pocket(frame(400, 100, 200, 150)), titled: "Sigma")
        h.editor.replaceDocument(with: CanvasDocument(shapes: shapes))
        expectEqual(h.listing("sigma"), ["2"])
        expectEqual(h.listing("delta"), ["(No matches)"])
        let other = CanvasFile(root: CanvasDocument(shapes: [shape(80, Box(frame(0, 0)), titled: "Kappa")]))
        h.editor.replaceFile(with: other)
        expect(h.jump.isOpen, "the palette stays open, over another file")
        expectEqual(h.jump.catalogCount, 1)
        expectEqual(h.listing("kappa"), ["80"])
        expectEqual(h.listing("sigma"), ["(No matches)"])
    },
    test("a big file is read in slices on the scheduler, the first at once; a commit meanwhile is applied to what's read; ready, it's all there") {
        let h = try storyHarness(file: bigFile(4000))
        h.openJumpTo()
        expect(!h.jump.isReady, "the first slice stopped short of 4,000 shapes")
        expect(h.jump.catalogCount > 0 && h.jump.catalogCount < 4000)
        expectEqual(h.scheduler.pendingCount, 1)
        h.editor.rename(id(1000), "Renamed", on: .root)
        expect(!h.jump.isReady && h.jump.isOpen, "still building, the palette open")
        h.wait(1)
        expect(h.jump.isReady)
        expectEqual(h.jump.catalogCount, 4000)
        expect(h.jump.buildSlices > 1)
        expect(h.jump.longestBuildSlice < .milliseconds(20), "a slice is a couple of milliseconds (a debug build's, with a shape's read to overshoot by): \(h.jump.longestBuildSlice)")
        expectEqual(h.listing("renamed"), ["1000"])
        expectEqual(h.listing("box 3999").first, "4999", "(a title a character short of it is a typo, found after)")
    },
    test("commits all through a build are applied to what's read, not a reason to start over: it finishes, with every titled shape and every commit's change") {
        // Root: 12,000 boxes, then a pocket "Late" whose board's 50 boxes aren't read until the end.
        var root = (0..<12000).map { shape(1000 + $0, Box(frame(CGFloat($0 % 50) * 120, CGFloat($0 / 50) * 80)), titled: "Box \($0)") }
        root.append(shape(1, Pocket(frame(0, 9000)), titled: "Late"))
        let late = CanvasDocument(shapes: (0..<50).map { shape(50000 + $0, Box(frame(CGFloat($0) * 120, 0)), titled: "Late \($0)") })
        let h = try storyHarness(file: CanvasFile(root: CanvasDocument(shapes: root), children: [id(1): late]))
        let late0 = BoardID(owner: id(1))
        h.openJumpTo()
        expect(!h.jump.isReady)
        var changes: [(Int, () -> Void)] = [
            (0, { h.editor.rename(id(1000), "Zed first", on: .root) }),                  // already read
            (1, { h.editor.rename(id(1000 + 11999), "Zed last", on: .root) }),            // not yet
            (2, { h.editor.transact { $0.delete([id(1002)]) } }),                        // read, before the build's place
            (3, { h.editor.transact { $0.delete([id(1000 + 11998)]) } }),                 // not yet read
            (4, { h.editor.transact { $0.insert(shape(70001, Box(frame(0, 8000)), titled: "Zed fresh")) } }),
            (5, { h.editor.rename(id(50007), "Zed board", on: late0) }),                  // on a board not yet read
            (6, { h.editor.rename(id(1001), nil, on: .root) }),                          // a title cleared
        ]
        var commits = 0, step = 0
        while !h.jump.isReady, step < 500 {
            h.scheduler.runNext()
            step += 1
            // A commit after every slice, the planned ones first, then churn.
            if let at = changes.firstIndex(where: { _ in true }) {
                changes.remove(at: at).1()
            } else {
                h.editor.rename(id(1000 + 100 + step), "Churn \(step)", on: .root)
            }
            commits += 1
        }
        expect(h.jump.isReady, "commits at every slice didn't keep it from finishing (\(step) slices, \(commits) commits)")
        expect(commits > 7, "the build outlasted the planned commits: \(commits)")
        // 12,000 boxes and the pocket and its 50, less two deleted and one untitled, plus one added.
        expectEqual(h.jump.catalogCount, 12000 + 1 + 50 - 2 - 1 + 1)
        expectEqual(h.listing("zed first"), ["1000"])
        expectEqual(h.listing("zed last"), ["12999"])
        expectEqual(h.listing("zed fresh"), ["70001"])
        expectEqual(h.listing("zed board"), ["50007"])
        expect(!h.listing("box 2").contains("1002"), "a shape deleted after it was read is gone")
        expect(!h.listing("box 11998").contains("12998"), "a shape deleted before it was read is never listed")
        expectEqual(h.listing("late 49"), ["50049"], "the board read last is all there")
        expectEqual(h.listing("churn 9").first, "\(1000 + 100 + 9)", "a commit that touched nothing planned")
    },
    test("closing the palette in the middle of the build keeps reading it; reopening finds it read") {
        let h = try storyHarness(file: bigFile(4000))
        h.openJumpTo()
        h.jump.close()
        h.wait(1)
        expect(h.jump.isReady)
        expectEqual(h.jump.catalogCount, 4000)
        h.openJumpTo()
        expectEqual(h.scheduler.pendingCount, 0, "read already: nothing to build")
    },
    test("recent picks and ties: a pick is the latest recent one, at most twenty are kept") {
        let h = try storyHarness(file: bigFile(40))
        h.openJumpTo()
        for n in 0..<30 { h.jump.pick(id(1000 + n)); h.openJumpTo() }
        expectEqual(h.jump.recent.count, 20)
        expectEqual(h.jump.recent.first, id(1029))
        h.jump.pick(id(1005))
        expectEqual(h.jump.recent.first, id(1005))
        expectEqual(h.jump.recent.count, 20, "a pick already recent is moved up, not kept twice")
    },
])
