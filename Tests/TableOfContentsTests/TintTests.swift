import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import SwiftUI
import TableOfContents
import TestKit

// The color of a row's symbol when it is the shape's own (`ContentsContext.color(of:)`): a plugin's
// `shapeTints`, here for a frozen shape (CanvasTesting's `Frozen` flag standing in for a color a shape
// holds), else the kind's.

/// A box with a name, whose row asks for its shape's color.
struct Chip: BoxShapeProps {
    static let kind: ShapeKind = "chip"
    static let properties = Properties<Chip> {
        Property("frame", \.frame).required()
        Property("name", \.name)
    }
    var frame: CGRect
    var name: String
    init(_ frame: CGRect = widgetFrame, name: String = "") {
        self.frame = frame
        self.name = name
    }
}

extension Chip {
    init() { self.init(widgetFrame) }
}

struct ChipDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Chip>, in context: RenderContext) {}
}

/// The tint a frozen shape has of its own, which the test can change.
@MainActor final class OwnTint {
    var color: NSColor = .systemRed
}

/// Chips (their kind's tint is teal), the flag, and the tint a frozen shape has.
@MainActor func tintPlugins(_ own: OwnTint) -> [any CanvasPlugin] {
    [FreezingPlugin(), Contributor(id: "chips") { r in
        r.shape(ChipDefinition()) { chip in
            chip.tint(.systemTeal)
            chip.contentsRow { chip, context in ContentsLabel(chip.props.name, color: context.color(of: chip)) }
        }
        r.shapeTints { record, _ in record[Frozen.self] == true ? own.color : nil }
    }]
}

@MainActor let tintRowTests = Suite("The table of contents' symbols' colors", [
    test("a row's symbol is in the color its shape has, its kind's tint when it has none, and the row is made again with the shape") {
        let own = OwnTint()
        let chip = ShapeID(), other = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: chip, Chip(CGRect(x: 0, y: 0, width: 100, height: 60), name: "A"))),
            AnyShapeRecord(ShapeRecord(id: other, Chip(CGRect(x: 200, y: 0, width: 100, height: 60), name: "B"))),
        ]))
        let editor = try contentsEditor(tintPlugins(own), file: file)
        @MainActor func color(_ id: ShapeID) throws -> Color? {
            let label = try require(editor.contents.entries.first { $0.id == id }?.label)
            return label.color
        }
        expectEqual(try color(chip), Color(nsColor: .systemTeal), "its kind's")
        let made = editor.contents.rowsMade
        editor.freeze([chip])
        expectEqual(try color(chip), Color(nsColor: own.color), "its own")
        expectEqual(try color(other), Color(nsColor: .systemTeal))
        expectEqual(editor.contents.rowsMade - made, 1, "the one row the commit changed")
        editor.freeze([chip], false)
        expectEqual(try color(chip), Color(nsColor: .systemTeal), "taken away")
    },
    test("a change to what tints are remakes the rows, those kept for a board left and those of another board's outline") {
        let own = OwnTint()
        let chip = ShapeID(), inside = ShapeID(), pocket = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: chip, Chip(CGRect(x: 0, y: 0, width: 100, height: 60), name: "A"))),
            AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 200, y: 0, width: 100, height: 60)))),
        ]), children: [pocket: CanvasDocument(shapes: [
            AnyShapeRecord(ShapeRecord(id: inside, Chip(CGRect(x: 0, y: 0, width: 100, height: 60), name: "C"))),
        ])])
        let editor = try contentsEditor([PocketsPlugin()] + tintPlugins(own), file: file)
        editor.freeze([chip])
        @MainActor func color(_ id: ShapeID, in entries: [ContentsEntry]) throws -> Color? {
            let label = try require(entries.first { $0.id == id }?.label)
            return label.color
        }
        expectEqual(try color(chip, in: editor.contents.entries), Color(nsColor: .systemRed))
        let pocketBoard = BoardID(owner: pocket)
        editor.transact(on: pocketBoard, "Freeze") { $0.update(inside) { $0[Frozen.self] = true } }
        expectEqual(try color(inside, in: editor.contents.outline(of: pocketBoard)), Color(nsColor: .systemRed), "another board's outline")
        own.color = .systemPurple
        editor.shapeTintsDidChange()
        expectEqual(try color(chip, in: editor.contents.entries), Color(nsColor: .systemPurple), "the board shown's rows")
        expectEqual(try color(inside, in: editor.contents.outline(of: pocketBoard)), Color(nsColor: .systemPurple), "another board's outline")
        expect(editor.showBoard(pocketBoard))
        expectEqual(try color(inside, in: editor.contents.entries), Color(nsColor: .systemPurple), "a board shown after")
        own.color = .systemGreen
        editor.shapeTintsDidChange()
        expect(editor.showBoard(.root))
        expectEqual(try color(chip, in: editor.contents.entries), Color(nsColor: .systemGreen), "the rows kept for a board left")
    },
])
