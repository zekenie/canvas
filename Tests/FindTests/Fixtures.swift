import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Find
import Geometry
import Keyboard
import Selection
import TestKit
import Topology

/// A white box of text on one line, in a monospaced grid (`MemoStyle`): what Find's tests search.
/// It may echo another memo, whose body it shows after its own (`echo`), live: a text read from more
/// than its shape, whose contribution names what a commit changes it by (`affected`).
struct Memo: BoxShapeProps {
    static let kind: ShapeKind = "memo"
    static let properties = Properties<Memo> {
        Property("frame", \.frame).required()
        Property("body", \.body)
        Property("echo", \.echo)
    }
    var frame: CGRect
    var body: String
    var echo: ShapeID?

    init(_ frame: CGRect, _ body: String, echo: ShapeID? = nil) {
        self.frame = frame
        self.body = body
        self.echo = echo
    }
}

extension Memo {
    init() { self.init(.zero, "") }
}

/// Where a memo's text goes: from its top-left, `inset` in, each character `advance` wide, one line
/// `line` tall.
enum MemoStyle {
    static let inset: CGFloat = 8
    static let advance: CGFloat = 8
    static let line: CGFloat = 16
    /// A hit's line rect for characters `range` of a memo's text.
    static func rect(_ range: Range<Int>) -> CGRect {
        CGRect(x: inset + CGFloat(range.lowerBound) * advance, y: inset, width: CGFloat(range.count) * advance, height: line)
    }
}

struct MemoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Memo>, in context: RenderContext) {
        context.cg.setFillColor(NSColor.white.cgColor)
        context.cg.fill(shape.frame)
    }
}

/// The memo kind and its findable text ("body": its own, then what it echoes). Its rects are the
/// grid's; `rectsAsked` counts the shapes laid out, `textsRead` the texts read.
@MainActor final class MemosPlugin: CanvasPlugin {
    nonisolated var id: PluginID { "memos" }
    var rectsAsked = 0
    var textsRead = 0

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(MemoDefinition()) { memo in
            memo.findableTexts("body", affected: { changes, context in
                // Fixtures are small: every memo that echoes something the commit changed.
                let changed = changes.changed.union(changes.removed)
                return Set(context.editor.document.shapes.compactMap { record in
                    record.typed(as: Memo.self).flatMap { $0.props.echo.map { changed.contains($0) } == true ? $0.id : nil }
                })
            }, texts: { [self] memo, context in
                textsRead += 1
                return [FindableText(field: "body", text: Self.text(of: memo, in: context.editor))]
            }, rects: { [self] _, _, ranges, _ in
                rectsAsked += 1
                return ranges.map { [MemoStyle.rect($0)] }
            })
        }
    }

    static func text(of memo: ShapeRecord<Memo>, in editor: CanvasEditor) -> String {
        guard let echo = memo.props.echo, let other = editor.shape(inFile: echo)?.typed(as: Memo.self) else { return memo.props.body }
        return memo.props.body + " " + other.props.body
    }
}

/// A box with a badge's text (`BadgeStyle`): a contribution for every shape of the kinds that hold
/// it (`where:`), ringed, laid out again as the zoom changes (`followsZoom`), and said zoomed out in
/// its top quarter (`zoomedOut`).
@MainActor final class BadgesPlugin: CanvasPlugin {
    nonisolated var id: PluginID { "badges" }
    var layouts = 0

    func register(into registrar: inout PluginRegistrar) {
        registrar.forShapes(adopting: ShapeCapability("that is a box") { $0.kind == Box.kind }) { boxes in
            boxes.findableTexts("badge", look: .ring, followsZoom: true,
                                zoomedOut: { record, _, _ in record.box.map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height / 4) } },
                                texts: { record, _ in [FindableText(field: "badge", text: "Badge \(Int(record.box?.width ?? 0))")] },
                                rects: { [self] _, _, ranges, context in
                                    layouts += 1
                                    return ranges.map { _ in [CGRect(x: 0, y: -20 / context.editor.camera.zoom, width: 60, height: 16)] }
                                })
        }
    }
}

/// The plugins a Find test runs on: keys, the selection, the graph (whose walk orders hits), Find,
/// memos and pockets (boards in a file), `more` after.
@MainActor func findPlugins(_ memos: MemosPlugin = MemosPlugin(), more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FindPlugin(), FixturesPlugin(), PocketsPlugin(), memos] + more
}

/// A harness over `file`, its view 800 × 600 (so things are in view or not), Find's plugins.
@MainActor func findHarness(_ file: CanvasFile, memos: MemosPlugin = MemosPlugin(), more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: findPlugins(memos, more: more), file: file)
    h.editor.viewportDidResize(to: viewport)
    return h
}

let viewport = CGSize(width: 800, height: 600)

/// Memos on a board in a row, 200 apart, each 160 × 40: `bodies` in order.
func memos(_ bodies: [String], y: CGFloat = 100, ids: [ShapeID]? = nil) -> [AnyShapeRecord] {
    bodies.enumerated().map { i, body in
        AnyShapeRecord(ShapeRecord(id: ids?[i] ?? ShapeID(), Memo(CGRect(x: 100 + CGFloat(i) * 200, y: y, width: 160, height: 40), body)))
    }
}

/// A file of pockets two deep: the root's memos and pocket A (and pocket B after it), A's board's
/// memos and pocket A1, A1's board's memos, B's board's memos.
struct PocketFile {
    let a = ShapeID(), a1 = ShapeID(), b = ShapeID()
    var aBoard: BoardID { BoardID(owner: a) }
    var a1Board: BoardID { BoardID(owner: a1) }
    var bBoard: BoardID { BoardID(owner: b) }
    let root: [AnyShapeRecord]
    let inA: [AnyShapeRecord]
    let inA1: [AnyShapeRecord]
    let inB: [AnyShapeRecord]

    init(root: [String], inA: [String], inA1: [String], inB: [String]) {
        self.root = memos(root)
        self.inA = memos(inA)
        self.inA1 = memos(inA1)
        self.inB = memos(inB)
    }

    var file: CanvasFile {
        let pockets = [AnyShapeRecord(ShapeRecord(id: a, Pocket(CGRect(x: 100, y: 300, width: 100, height: 100)))),
                       AnyShapeRecord(ShapeRecord(id: b, Pocket(CGRect(x: 300, y: 300, width: 100, height: 100))))]
        let inner = AnyShapeRecord(ShapeRecord(id: a1, Pocket(CGRect(x: 100, y: 300, width: 100, height: 100))))
        // A's pocket first in its board, so its board comes before what follows it in file order.
        return CanvasFile(root: CanvasDocument(shapes: Array(root.prefix(1)) + [pockets[0]] + Array(root.dropFirst()) + [pockets[1]]),
                          children: [a: CanvasDocument(shapes: [inner] + inA), a1: CanvasDocument(shapes: inA1), b: CanvasDocument(shapes: inB)])
    }
}

extension FindState {
    /// The results' shapes, in order.
    var found: [ShapeID] { results.map(\.id) }
}

/// Opens Find on `h` (⌘F), builds its index to the end and waits for the search of `query`.
@MainActor func search(_ query: String, in h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> FindState {
    let find = try require(h.editor.find, file: file, line: line)
    if !find.isActive { find.open() }
    find.query = query
    try settle(find, h, file: file, line: line)
    return find
}

/// Runs the index's slices (the harness's scheduler) and waits for the search.
@MainActor func settle(_ find: FindState, _ h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws {
    var turns = 0
    while find.isIndexing, turns < 10_000 {
        h.wait(0)
        turns += 1
    }
    _ = try awaitResult(file: file, line: line) { await find.settled() }
}

/// The world rect of a memo's characters `range`, where it is now.
@MainActor func memoRect(_ id: ShapeID, _ range: Range<Int>, in editor: CanvasEditor) -> CGRect? {
    editor.document[id]?.box.map { MemoStyle.rect(range).offsetBy(dx: $0.minX, dy: $0.minY) }
}
