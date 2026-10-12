import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import TestKit

// `size:` with a width alone (`size: 300x`): the shape is that wide, and as tall as its kind works it
// out to be there (`DerivedProps`), or, for a kind that works nothing out, as tall as it was. Over a
// scroll, whose height follows what it says at its width, and tiles and cards.

/// A box whose height follows what it says at its width, as a note's follows its text.
struct Scroll: BoxShapeProps {
    static let kind: ShapeKind = "scroll"
    static let properties = Properties<Scroll> {
        Property("frame", \.frame).required()
        Property("label", \.label)
        Property("says", \.says)
    }
    var frame: CGRect
    var label: String
    var says: String
    init(_ frame: CGRect, label: String = "", says: String = "") {
        self.frame = frame
        self.label = label
        self.says = says
    }
}

extension Scroll {
    init() { self.init(.zero) }

    /// How tall a scroll `width` wide is that says this: 20 a line, a line 10 letters for each 100 of
    /// its width; 40 at least.
    static func height(saying says: String, width: CGFloat) -> CGFloat {
        let line = max(1, Int(width / 10))
        return max(40, CGFloat((says.count + line - 1) / line) * 20)
    }
}

struct ScrollDefinition {}

extension ScrollDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Scroll>, in context: RenderContext) {}
}

/// Written as a kind's setters would: its height fits what it says at its width.
extension ScrollDefinition: DerivedProps {
    func derive(_ props: inout Scroll) { props.frame.size.height = Scroll.height(saying: props.says, width: props.frame.width) }
}

/// Scrolls, placed 100 × 40, and names for them and for tiles, each by its label.
@MainActor func scrollsPlugins() -> [any CanvasPlugin] {
    let scrolls = Contributor(id: "scrolls") { registrar in
        registrar.shape(ScrollDefinition()) { scroll in
            scroll.tool(label: "Scroll", systemImage: "scroll", placing: scroll.placement(size: CGSize(width: 100, height: 40)) { Scroll() })
        }
    }
    let names = Contributor(id: "names") { registrar in
        registrar.drawNames(name: { record, _ in
            if let tile = record.typed(as: Tile.self) { return fold(tile.props.label) }
            return record.typed(as: Scroll.self).flatMap { fold($0.props.label) }
        }, namingProperty: { kind, _ in kind == Tile.kind || kind == Scroll.kind ? "label" : nil }, isDerived: { _, _ in false }, fold: fold)
    }
    return [scrolls, names]
}

/// The size of the board shape called this: a scroll's or a tile's label.
@MainActor private func size(of title: String, in editor: CanvasEditor) -> CGSize? {
    editor.document.shapes.first { $0.typed(as: Scroll.self)?.props.label == title || $0.typed(as: Tile.self)?.props.label == title }?.box?.size
}

/// Ninety letters: three lines 300 wide, nine 100 wide.
private let ninety = String(repeating: "a", count: 90)

@MainActor let drawSizeTests = Suite("Drawing: a width alone", [
    test("a new shape drawn with a width alone is that wide, as tall as its kind works it out there; one that works nothing out, as its tool places it") {
        let editor = try makeEditor(scrollsPlugins())
        let result = try drawn("""
            scroll "Wide" size: 300x says: \(ninety)
            scroll "Plain" right of "Wide" says: \(ninety)
            scroll "Both" right of "Plain" size: 300x200 says: \(ninety)
            tile "Tile" below "Wide" size: 300x
            """, on: editor)
        expectEqual(size(of: "Wide", in: editor), CGSize(width: 300, height: 60), "three lines at 300")
        expectEqual(size(of: "Plain", in: editor), CGSize(width: 100, height: 180), "nine at the tool's 100")
        expectEqual(size(of: "Both", in: editor), CGSize(width: 300, height: 200), "both sides as written")
        expectEqual(size(of: "Tile", in: editor), CGSize(width: 300, height: 80), "a tile's 80")
        expectEqual(rows(result).first?["at"]?.arrayValue?.last, [300, 60], "placed at what it works out")
    },
    test("restated with a width alone, a shape's worked out again at that width though nothing else is set; again, it's unchanged; a kind that works nothing out keeps its height") {
        let editor = try makeEditor(scrollsPlugins())
        _ = try drawn("scroll \"S\" size: 300x400 says: \(ninety)\ntile \"T\" right of \"S\" size: 300x160", on: editor)
        expectEqual(size(of: "S", in: editor), CGSize(width: 300, height: 400))
        _ = try drawn(#"scroll "S" size: 300x"#, on: editor)
        expectEqual(size(of: "S", in: editor), CGSize(width: 300, height: 60), "fitted to what it says")
        expectEqual(rows(try drawn(#"scroll "S" size: 300x"#, on: editor)).first?["did"], "unchanged")
        _ = try drawn(#"scroll "S" size: 150x"#, on: editor)
        expectEqual(size(of: "S", in: editor), CGSize(width: 150, height: 120))
        _ = try drawn("scroll \"S\" size: 600x says: \(String(repeating: "b", count: 130))", on: editor)
        expectEqual(size(of: "S", in: editor), CGSize(width: 600, height: 60), "what it says now, at the width it's given")
        _ = try drawn(#"tile "T" size: 200x"#, on: editor)
        expectEqual(size(of: "T", in: editor), CGSize(width: 200, height: 160))
        editor.undo()
        expectEqual(size(of: "T", in: editor), CGSize(width: 300, height: 160), "one step")
    },
    test("a style gives a width alone, whole; a statement's own size wins") {
        let editor = try makeEditor(scrollsPlugins())
        _ = try drawn("""
            style narrow size: 200x
            style big size: 400x300
            scroll "A" style: narrow says: \(ninety)
            scroll "B" right of "A" style: big, narrow says: \(ninety)
            scroll "C" right of "B" style: narrow size: 150x90 says: \(ninety)
            scroll "D" right of "C" style: big size: 500x says: \(ninety)
            """, on: editor)
        expectEqual(size(of: "A", in: editor), CGSize(width: 200, height: 100))
        expectEqual(size(of: "B", in: editor), CGSize(width: 200, height: 100), "the later style's, its width alone")
        expectEqual(size(of: "C", in: editor), CGSize(width: 150, height: 90))
        expectEqual(size(of: "D", in: editor), CGSize(width: 500, height: 40), "the statement's width alone")
    },
    test("a width alone that would change a title worked out from the shape's size is refused, said as written") {
        let editor = try drawEditor()
        _ = try drawn("card", on: editor)
        let renames = try refused(#"card "Card, 100 × 60" size: 200x"#, on: editor)
        expectEqual(renames.reason, "renames")
        expectEqual(renames.message, #"size: 200x would rename "Card, 100 × 60" to "Card, 200 × 60""#)
    },
])
