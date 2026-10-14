@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Types
import Validation

// What a far pick and a far delete cost, as unit tests with a thread-CPU bound (gestures, not lines of `./build.sh bench`): a pick
// of a private note on a board of 10,000 shapes, a far note made private with a thousand relationships through a thousand pills,
// and an arrow and its pill deleted on a board not shown. The figures are the design's, for a release build; this suite runs in a
// debug one, which does the same work several times slower, so the bound each case holds is that figure times `debugFactor`, and
// the measured time is printed beside it.

#if DEBUG
private let debugFactor = 8.0
#else
private let debugFactor = 1.0
#endif

@MainActor private func drawing() -> [any CanvasPlugin] {
    [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()]
}

extension Duration {
    fileprivate var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

extension RelationScene {
    /// `count` plain slips on a board, in a field of columns, in one step.
    func fill(_ board: BoardID, with count: Int) {
        editor.transact(on: board, "Fill") { transaction in
            for n in 0..<count { transaction.insert(slipRecord("f\(n)", at: CGPoint(x: 3_000 + CGFloat(n % 100) * 300, y: 3_000 + CGFloat(n / 100) * 100))) }
        }
        editor.undoHistory.seal()
    }
}

@MainActor let farCostTests = Suite("What a far pick and a far delete cost", [
    test("farPick: one pick of a private note on another board, 10,000 shapes on each of two boards, is a step of 16 milliseconds") {
        let s = try RelationScene.drawn()
        s.fill(.root, with: 10_000)
        s.fill(s.pocketBoard, with: 10_000)
        expect(s.editor.showBoard(.root))
        // The board has been shown: every shape's frame is kept, as a frame of the canvas leaves them.
        for record in s.editor.document.shapes { _ = s.editor.shapeContext.frame(of: record.id) }
        let row = try s.featureRow()
        var made: ShapeID?
        let elapsed = threadCPUTime { made = s.editor.relate(s.note, to: s.awayLayer, in: row) }
        _ = try require(made)
        expectEqual(s.editor.file.record(s.awayLayer)?.meta[Open.self], true)
        print("  farPick: a pick of a private note on another board, \(s.editor.document.shapes.count) shapes here: \(String(format: "%.1f", elapsed.ms)) ms (budget 16)")
        expect(elapsed.ms < 16 * debugFactor, "the pick took \(elapsed.ms) ms")
    },
    test("farHubCommit: a far note made private with a thousand relationships through a thousand pills, the commit, the index and Validation's read, is 75 milliseconds") {
        let s = try RelationScene.drawn()
        s.setOpen(s.awayLayer)
        var arrows: [ShapeID] = []
        s.editor.transact("Hub") { transaction in
            for n in 0..<1_000 {
                let holder = slipRecord("Feature \(n)", of: [s.feature], at: CGPoint(x: 3_000 + CGFloat(n % 50) * 300, y: 3_000 + CGFloat(n / 50) * 200))
                transaction.insert(holder)
                let pill = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(x: 3_000 + CGFloat(n % 50) * 300 + 250, y: 3_000 + CGFloat(n / 50) * 200, width: 100, height: 32),
                                                                             stands: [s.awayLayer], says: "Down")))
                transaction.insert(pill)
                var bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: holder.id, to: pill.id)))
                bond[IsAProperty.self] = [TypeLink(s.rel)]
                transaction.insert(bond)
                arrows.append(bond.id)
            }
        }
        _ = s.editor.validation?.results
        for id in arrows { _ = s.editor.issues(id) }
        let elapsed = threadCPUTime {
            s.setOpen(s.awayLayer, false)
            for id in arrows { _ = s.editor.issues(id) }
        }
        expect(s.editor.issues(arrows[0]).count == 1, "the pill is not admitted: one warning")
        print("  farHubCommit: a far note made private through 1,000 pills: \(String(format: "%.1f", elapsed.ms)) ms (budget 75)")
        expect(elapsed.ms < 75 * debugFactor, "the commit and the read took \(elapsed.ms) ms")
    },
    test("farDelete: one arrow and its pill deleted on a board of 10,000 shapes that is not shown, 16 milliseconds, and its undo and redo 100") {
        let s = try RelationScene.drawn()
        s.setOpen(s.layerNote)
        s.fill(s.pocketBoard, with: 10_000)
        let pill = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(x: 2_000, y: 2_000, width: 100, height: 32), stands: [s.layerNote], says: "Foundation")))
        var bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.away, to: pill.id)))
        bond[IsAProperty.self] = [TypeLink(s.rel)]
        let farBond = bond
        s.editor.transact(on: s.pocketBoard, "Draw") { transaction in
            transaction.insert(pill)
            transaction.insert(farBond)
        }
        s.editor.undoHistory.seal()
        expect(s.editor.showBoard(.root))
        let start = try s.bytes()
        var done = false
        let elapsed = threadCPUTime { done = s.editor.unrelate([farBond.id]) }
        expect(done)
        expect(s.editor.file.record(pill.id) == nil && s.editor.file.record(farBond.id) == nil, "the arrow and its pill are gone")
        let undone = threadCPUTime { s.editor.undo() }
        expect(try s.bytes() == start, "undo returns the far board")
        let redone = threadCPUTime { s.editor.redo() }
        print("  farDelete: an arrow and its pill on a board of 10,000 shapes not shown: \(String(format: "%.1f", elapsed.ms)) ms (budget 16), undo \(String(format: "%.1f", undone.ms)) ms, redo \(String(format: "%.1f", redone.ms)) ms (budget 100)")
        expect(elapsed.ms < 16 * debugFactor, "the delete took \(elapsed.ms) ms")
        expect(undone.ms < 100 * debugFactor && redone.ms < 100 * debugFactor, "undo took \(undone.ms) ms, redo \(redone.ms)")
    },
])
