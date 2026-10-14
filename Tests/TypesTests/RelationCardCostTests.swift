import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Types
import Validation

// What opening a relation row's card costs, as a unit test with a thread-CPU bound (a gesture, not a line of `./build.sh bench`):
// the card of a hub's row, a thousand relationships, made (the sheet asked of the book once, a line for each, laid out, the first
// stop focused, the core's card shown). The figure is `cardOpen`'s, 10 ms, for a release build; this suite runs in a debug
// one, which does the same work several times slower, so the bound is that figure times `debugFactor`, and the measured time is
// printed beside it. A keystroke in a cell of that card reloads its whole sheet: its time is printed, held to nothing (the held
// keystroke is the commit's, `Budget.relationCardKeystroke`).

#if DEBUG
private let debugFactor = 20.0
#else
private let debugFactor = 1.0
#endif

extension Duration {
    fileprivate var ms: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}

@MainActor let relationCardCostTests = Suite("What a relation row's card costs", [
    test("relationCardOpen: the card of a hub's row, a thousand relationships, opens in the figure of a note's table of two hundred lines") {
        let r = try RowCardRig()
        defer { r.close() }
        let s = r.s
        var arrows: [ShapeID] = []
        s.editor.transact("Hub") { transaction in
            for n in 0..<1_000 {
                let layer = slipRecord("Layer \(n)", of: [s.layer], at: CGPoint(x: 3_000 + CGFloat(n % 50) * 300, y: 3_000 + CGFloat(n / 50) * 200))
                transaction.insert(layer)
                var bond = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: s.note, to: layer.id)))
                bond[IsAProperty.self] = [TypeLink(s.rel)]
                bond[FieldValuesProperty.self] = FieldValues(["role": .string("engineer \(n)")])
                transaction.insert(bond)
                arrows.append(bond.id)
            }
        }
        _ = s.editor.validation?.results
        _ = s.index.relations(of: s.note)
        var opened = false
        let elapsed = threadCPUTime { opened = (try? r.open()) ?? false }
        expect(opened, "the card opened")
        let form = try require(r.form)
        expectEqual(form.sheet.lines.count, 1_001, "a line for each relationship, and the blank one")
        print("  relationCardOpen: the card of a row holding 1,000 relationships: \(String(format: "%.1f", elapsed.ms)) ms (budget 10)")
        expect(elapsed.ms < 10 * debugFactor, "the card took \(elapsed.ms) ms to open")
        // A keystroke in a cell: the commit, and the open card made again.
        form.focus(FieldStop(line: 0, column: 1))
        let typed = threadCPUTime { r.window.type("x") }
        print("  relationCardReload: a keystroke in a cell of that card, the commit and the card's sheet made again: \(String(format: "%.1f", typed.ms)) ms (reported)")
        expect(r.values(try require(form.sheet.lines[0].owner)).value(at: FieldPath(field: "role")) != nil)
    },
])
