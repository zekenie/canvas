import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// `canvas draw` and `canvas measure` over a shape laid out larger than it stores (CanvasTesting's
// stretch, laid out by the gauge it names, standing in for a typed note): draw places and reports
// the frame the shape is laid out in (`at`, measure's `size`), and writes the size it stores.

/// Names stretches, gauges, pens and tiles by their labels.
@MainActor private func roomNames() -> Contributor {
    Contributor(id: "room-names") { registrar in
        registrar.drawNames(name: { record, _ in
            if let stretch = record.typed(as: Stretch.self) { return fold(stretch.props.label) }
            if let gauge = record.typed(as: CanvasTesting.Gauge.self) { return fold(gauge.props.label) }
            if let pen = record.typed(as: Pen.self) { return fold(pen.props.label) }
            return record.typed(as: Tile.self).flatMap { fold($0.props.label) }
        }, namingProperty: { kind, _ in
            [Stretch.kind, CanvasTesting.Gauge.kind, Pen.kind, Tile.kind].contains(kind) ? "label" : nil
        }, isDerived: { _, _ in false }, fold: fold)
    }
}

/// A text format for the gauge a stretch names: a gauge's title, kept as its id.
private let gaugeFormat = Contributor(id: "gauge-format") { registrar in
    registrar.drawTextFormat(mediaType: GaugeLink.mediaType, describes: "a gauge's title") { text, context throws(AutomationError) in
        let gauge = try context.shape(called: text) { $0.kind == CanvasTesting.Gauge.kind ? nil : "which only gauges can be named here" }
        return gauge.id.rawValue.uuidString
    }
}

@MainActor private func roomEditor() throws -> CanvasEditor {
    try makeEditor([roomNames(), gaugeFormat, StretchesPlugin(), pens])
}

/// What a stretch is stored at when a script says no `size:`: its tool's.
private let storedSize = CGSize(width: 100, height: 60)

/// A row's `at`: `[[x, y], [width, height]]`.
private func at(_ row: JSON?) -> CGRect? {
    guard let origin = row?["at"]?.arrayValue?.first?.arrayValue?.compactMap(\.numberValue),
          let size = row?["at"]?.arrayValue?.last?.arrayValue?.compactMap(\.numberValue), origin.count == 2, size.count == 2 else { return nil }
    return CGRect(x: origin[0], y: origin[1], width: size[0], height: size[1])
}

/// The row of the statement on `line`.
private func row(_ result: JSON, line: Int) -> JSON? { rows(result).first { $0["line"]?.numberValue == Double(line) } }

@MainActor private func stretch(_ title: String, in editor: CanvasEditor) -> AnyShapeRecord? {
    editor.document.shapes.first { $0.typed(as: Stretch.self)?.props.label == title }
}

/// Every stretch on the board, stored at `size`: nothing a run writes holds a laid-out size.
@MainActor private func expectStored(_ size: CGSize = storedSize, in editor: CanvasEditor, _ message: String = "", line: UInt = #line) {
    for record in editor.document.shapes where record.kind == Stretch.kind {
        expectEqual(record.box?.size, size, "a stretch is stored at its own size \(message)", line: line)
    }
}

/// A gauge on the board, labeled, `width` by `height`.
@MainActor @discardableResult private func gauge(_ label: String, _ width: CGFloat, _ height: CGFloat, at origin: CGPoint = CGPoint(x: 1200, y: 0),
                                                  in editor: CanvasEditor) -> ShapeID {
    let record = AnyShapeRecord(ShapeRecord(CanvasTesting.Gauge(CGRect(origin: origin, size: CGSize(width: 60, height: 40)), label: label, width: width, height: height)))
    editor.transact { $0.insert(record) }
    return record.id
}

private let both = """
gauge "G" width: 300 height: 120
stretch "S" gauge: "G" right of "G"
"""

@MainActor let drawRoomTests = Suite("draw: the room a shape takes", [
    test("a gauge and the stretch that names it, drawn in one script: the stretch's row is its laid-out size, and its box stores the tool's") {
        let editor = try roomEditor()
        let result = try drawn(both, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["created", "created"])
        let laidOut = try require(at(row(result, line: 2)))
        expectEqual(laidOut.size, CGSize(width: 300, height: 120), "the larger of each side")
        let record = try require(stretch("S", in: editor))
        expectEqual(record.box?.origin, laidOut.origin)
        expectEqual(record.box?.size, storedSize)
        expectEqual(editor.shapeContext.frame(of: record.id), laidOut, "the frame it has once the run has committed")
        expectEqual(messages(result), [])
        expectStored(in: editor)
    },
    test("a shape drawn right of the stretch is clear of its laid-out right edge") {
        let editor = try roomEditor()
        let result = try drawn(both + "\n" + #"tile "T" right of "S""#, on: editor)
        let laidOut = try require(at(row(result, line: 2)))
        expectEqual(editor.shapeContext.frame(of: try require(stretch("S", in: editor)).id), laidOut, "the row is the frame the board has")
        expectEqual(laidOut.size, CGSize(width: 300, height: 120))
        let tile = try require(at(row(result, line: 3)))
        expect(tile.minX >= laidOut.maxX + 40, "the tile at \(tile) is clear of \(laidOut)")
        expect(!tile.intersects(laidOut))
    },
    test("run again, every row is unchanged, nothing is said to be resized, and the document is as it was") {
        let editor = try roomEditor()
        let script = both + "\n" + #"tile "T" right of "S""#
        _ = try drawn(script, on: editor)
        let before = editor.document
        let again = try drawn(script, on: editor)
        expectEqual(rows(again).map { $0["did"] }, ["unchanged", "unchanged", "unchanged"])
        expect(!messages(again).contains { $0.contains("resized") }, "\(messages(again))")
        expectEqual(editor.document, before)
        expectStored(in: editor)
    },
    test("a stretch restated with no placement after its gauge grew is an obstacle at its new size to what the script places") {
        let editor = try roomEditor()
        _ = try drawn(both, on: editor)
        let gauge = try require(editor.document.shapes.first { $0.kind == CanvasTesting.Gauge.kind }).id
        editor.transact("Grow") { $0.update(gauge, as: CanvasTesting.Gauge.self) { $0.props.width = 500; $0.props.height = 200 } }
        let result = try drawn(#"stretch "S" gauge: "G""# + "\n" + #"tile "T" right of "S""#, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["unchanged", "created"])
        let laidOut = try require(at(row(result, line: 1)))
        expectEqual(laidOut.size, CGSize(width: 500, height: 200), "the size the gauge says now")
        let tile = try require(at(row(result, line: 2)))
        expect(tile.minX >= laidOut.maxX + 40, "\(tile) is clear of \(laidOut)")
        expect(!messages(result).contains { $0.contains("resized") }, "\(messages(result))")
        expectStored(in: editor)
    },
    test("a stretch whose stored box fits the pen but whose laid-out frame hangs over its edge is nudged in by the laid-out frame, and the warning says so") {
        let editor = try roomEditor()
        _ = PenBoardForRoom(editor)
        gauge("G", 150, 60, in: editor)
        let result = try drawn(#"stretch "S" gauge: "G" right of "M" (gap: tight)"#, on: editor)
        let laidOut = try require(at(row(result, line: 1)))
        expectEqual(laidOut.size, CGSize(width: 150, height: 60))
        expect(laidOut.maxX <= 400, "the laid-out frame \(laidOut) is inside the pen, which ends at 400")
        expect(messages(result).contains(#""S" was over the edge of "Pen", so it was nudged in"#), "\(messages(result))")
        expectEqual(editor.shapeContext.frame(of: try require(stretch("S", in: editor)).id), laidOut, "the board has the frame the row says")
        expectStored(in: editor)
    },
    test("size: written on a stretch is what is stored, and the row says the larger of it and the frame it is laid out in") {
        let editor = try roomEditor()
        let small = try drawn(both.replacingOccurrences(of: #"gauge: "G""#, with: #"gauge: "G" size: 150x80"#), on: editor)
        expectEqual(stretch("S", in: editor)?.box?.size, CGSize(width: 150, height: 80))
        expectEqual(try require(at(row(small, line: 2))).size, CGSize(width: 300, height: 120), "the gauge's is larger")
        let big = try drawn(#"stretch "S" gauge: "G" size: 400x200"#, on: editor)
        expectEqual(stretch("S", in: editor)?.box?.size, CGSize(width: 400, height: 200))
        expectEqual(try require(at(row(big, line: 1))).size, CGSize(width: 400, height: 200), "its own is larger")
    },
    test("canvas measure of the script says, for each shape, the size draw reports") {
        let editor = try roomEditor()
        let script = both + "\n" + #"tile "T" right of "S""#
        let measured = try run(["measure", "-"], on: editor, input: script).get()
        let result = try drawn(script, on: editor)
        let sizes = (measured["shapes"]?.arrayValue ?? []).map { $0["size"]?.arrayValue?.compactMap(\.numberValue) }
        expectEqual(sizes.count, 3)
        for (index, size) in sizes.enumerated() {
            let drawn = try require(at(row(result, line: index + 1))).size
            expectEqual(size, [Double(drawn.width), Double(drawn.height)], "statement \(index + 1)")
        }
        expectEqual(sizes[1], [300, 120])
    },
    test("a stretch that names a gauge on the board, not in the script, is laid out by it") {
        let editor = try roomEditor()
        gauge("G", 260, 90, in: editor)
        let result = try drawn(#"stretch "S" gauge: "G""#, on: editor)
        expectEqual(try require(at(row(result, line: 1))).size, CGSize(width: 260, height: 90))
        expectStored(in: editor)
        let measured = try run(["measure", "-"], on: editor, input: #"stretch "S""#).get()
        expectEqual(measured["shapes"]?.arrayValue?.first?["size"]?.arrayValue?.compactMap(\.numberValue), [100, 60], "measure reads a script alone: no gauge")
    },
    test("a stretch restated as it is, with its gauge restated bigger in the same script, is unchanged, and its row, measure and the board a moment later say the size the gauge now says") {
        let editor = try roomEditor()
        _ = try drawn(both, on: editor)
        let script = #"gauge "G" width: 500 height: 200"# + "\n" + #"stretch "S" gauge: "G""#
        let result = try drawn(script, on: editor)
        expectEqual(rows(result).map { $0["did"] }, ["updated", "unchanged"])
        expectEqual(try require(at(row(result, line: 2))).size, CGSize(width: 500, height: 200))
        let measured = try run(["measure", "-"], on: editor, input: script).get()
        expectEqual(measured["shapes"]?.arrayValue?.last?["size"]?.arrayValue?.compactMap(\.numberValue), [500, 200])
        let record = try require(stretch("S", in: editor))
        expectEqual(editor.shapeContext.frame(of: record.id)?.size, CGSize(width: 500, height: 200))
        expectStored(in: editor)
    },
    test("a script that deletes the gauge a stretch names, and restates the stretch, reports the frame the board has afterward: the stored one") {
        let editor = try roomEditor()
        _ = try drawn(both, on: editor)
        let result = try drawn(#"delete "G""# + "\n" + #"stretch "S""# + "\n" + #"tile "T" right of "S""#, on: editor)
        let reported = try require(at(row(result, line: 2)))
        let record = try require(stretch("S", in: editor))
        expectEqual(editor.shapeContext.frame(of: record.id), reported, "the row is what the board has once the gauge is gone")
        expectEqual(reported.size, storedSize)
        let tile = try require(at(row(result, line: 3)))
        expect(!tile.intersects(reported), "\(tile) is clear of \(reported)")
        expectStored(in: editor)
    },
    test("nothing a run writes holds a laid-out size: every stretch of a mixed script is stored at what the script or its tool says") {
        let editor = try roomEditor()
        gauge("B", 260, 90, in: editor)
        _ = try drawn(both + "\n" + #"stretch "U" gauge: "G" right of "S""# + "\n" + #"stretch "V" gauge: "B" size: 120x70 below "S""# + "\n" + #"tile "T" right of "U""#, on: editor)
        let sizes = Dictionary(uniqueKeysWithValues: editor.document.shapes.compactMap { r in r.typed(as: Stretch.self).map { ($0.props.label, r.box?.size) } })
        expectEqual(sizes, ["S": storedSize, "U": storedSize, "V": CGSize(width: 120, height: 70)])
        _ = try drawn(#"gauge "G" width: 500 height: 200"#, on: editor)
        expectEqual(editor.document.shapes.filter { $0.kind == Stretch.kind }.count, 3)
        expectEqual(stretch("S", in: editor)?.box?.size, storedSize, "a gauge restated bigger writes nothing to the stretches")
    },
])

/// Pen "Pen" (0, 0, 400 × 300) holding tile "M" (150, 100, 120 × 80).
@MainActor private struct PenBoardForRoom {
    let pen: ShapeID, m: ShapeID

    init(_ editor: CanvasEditor) {
        let pen = AnyShapeRecord(ShapeRecord(Pen(CGRect(x: 0, y: 0, width: 400, height: 300), label: "Pen")))
        editor.transact { $0.insert(pen) }
        m = tile("M", CGRect(x: 150, y: 100, width: 120, height: 80), in: editor).id
        editor.transact { [m] in $0.setContainer(m, to: pen.id) }
        self.pen = pen.id
    }
}
