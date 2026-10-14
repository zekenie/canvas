@_spi(Host) import Canvas
import AppKit
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types

// How a relation row shows the rules of its end: an amber dot after the row's name on a type's note while the end is Needed;
// on a note that is one, amber `add layer` while a Needed row is empty, and the row's pills red with the wave while it breaks
// Only one. Drawn into a bitmap, over `RelationScene` (RelationRowTests.swift).

private let viewport = CGSize(width: 1200, height: 900)

/// How amber the most amber pixel in `rect` is: green over blue, red above green. Black, gray and red have none.
@MainActor private func amber(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
    var most = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let p = pixel(bitmap, at: CGPoint(x: x, y: y))
            if p[0] > p[1] { most = max(most, p[1] - p[2]) }
        }
    }
    return most
}

/// How red the most red pixel in `rect` is: red over green, with green and blue alike. Black, gray and amber have none.
@MainActor private func red(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
    var most = 0
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            let p = pixel(bitmap, at: CGPoint(x: x, y: y))
            if abs(p[1] - p[2]) < 20 { most = max(most, p[0] - p[1]) }
        }
    }
    return most
}

extension RelationScene {
    func setRule(_ rule: EndRule?, on arrow: ShapeID) {
        editor.transact { $0.update(arrow) { $0[RelationshipEndProperty.self] = rule } }
    }

    @MainActor func bitmap() -> NSBitmapImageRep {
        editor.viewportDidResize(to: viewport)
        return renderBitmap(editor, size: viewport)
    }
}

@MainActor let relationRowMarksTests = Suite("The rules of an end, in the rows", [
    test("a Needed end puts the amber dot after the row's name on the type's note, and no other end does; clearing it and undo take it away and bring it back") {
        let s = try RelationScene()
        let end = s.fromEnd("layer")
        s.toEnd()
        let name = try s.row(s.feature, "layer").nameRect
        expect(amber(s.bitmap(), in: name) < 20, "no rule, no dot")
        s.setRule(EndRule(needed: true, onlyOne: false), on: end)
        let dotted = s.bitmap()
        expect(contains(dotted, [245, 158, 10], in: try s.row(s.feature, "layer").nameRect), "the dot")
        expect(!contains(dotted, [245, 158, 10], in: try s.row(s.layer, "feature").nameRect), "the other type's row has none")
        s.setRule(EndRule(needed: false, onlyOne: true), on: end)
        expect(amber(s.bitmap(), in: try s.row(s.feature, "layer").nameRect) < 20, "Only one is not Needed")
        s.editor.undo()
        expect(contains(s.bitmap(), [245, 158, 10], in: try s.row(s.feature, "layer").nameRect), "undone")
        // The name column makes room for the dot: the name is not cut by it.
        let column = try s.row(s.feature, "layer")
        expect(column.nameRect.width > 0)
    },
    test("a note's empty Needed row reads `add layer` in amber, and a relationship in it takes the amber away; Needed is no mark on the other type's row") {
        let s = try RelationScene()
        let end = s.fromEnd("layer")
        s.toEnd()
        let value = try s.row(s.note, "layer").valueRect
        expectEqual(try s.row(s.note, "layer").content, .empty("add layer"))
        expect(amber(s.bitmap(), in: value) < 20, "faint, not amber")
        s.setRule(EndRule(needed: true, onlyOne: false), on: end)
        expect(amber(s.bitmap(), in: try s.row(s.note, "layer").valueRect) > 50, "amber")
        expect(amber(s.bitmap(), in: try s.row(s.layerNote, "feature").valueRect) < 20, "the Layer note's row asks nothing")
        let arrow = s.relate(s.note, s.layerNote)
        expect(amber(s.bitmap(), in: try s.row(s.note, "layer").valueRect) < 20, "it has one")
        s.editor.undo()
        expect(amber(s.bitmap(), in: try s.row(s.note, "layer").valueRect) > 50, "and without it again")
        _ = arrow
    },
    test("a note that breaks Only one has the row's pills red with the wave, and a note that does not has them as they were; deleting one takes the red away") {
        let s = try RelationScene()
        let end = s.fromEnd("layer")
        s.toEnd()
        s.setRule(EndRule(needed: false, onlyOne: true), on: end)
        let other = s.editor.addSlip("Ground", of: [s.layer], at: CGPoint(x: 800, y: 1500))
        let first = s.relate(s.note, s.layerNote)
        expect(red(s.bitmap(), in: try s.row(s.note, "layer").valueRect) < 40, "one is allowed")
        let second = s.relate(s.note, other)
        let value = try s.row(s.note, "layer").valueRect
        expect(red(s.bitmap(), in: value) > 80, "both pills red")
        let marked = try s.row(s.note, "layer")
        expect(s.editor.fieldChecks?.check(of: try require(s.editor.file.record(s.note))).mark(at: try require(marked.relation)) == .wrong)
        s.editor.transact { $0.delete([second]) }
        expect(red(s.bitmap(), in: try s.row(s.note, "layer").valueRect) < 40, "deleted")
        s.editor.undo()
        expect(red(s.bitmap(), in: try s.row(s.note, "layer").valueRect) > 80, "undone")
        _ = first
    },
    test("the look of a relation row is the check's mark on it: needed on an empty row, wrong on a row of pills, plain otherwise") {
        expectEqual(RowLook.of(content: .empty("add layer"), mark: .needed), .needed)
        expectEqual(RowLook.of(content: .empty("add layer"), mark: nil), .empty)
        expectEqual(RowLook.of(content: .related([], more: 0), mark: .wrong), .wrong)
        expectEqual(RowLook.of(content: .related([], more: 0), mark: nil), .plain)
        expectEqual(RowLook.of(content: .related([], more: 0), mark: .needed), .plain)
    },
])
