import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import Connections
import ContextMenus
import DetailPanel
import Draw
import Engineering
import Find
import Keyboard
import LineRows
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Transform

/// The pasteboards of the tests' own that `kitPlugins` made (the kit reads SQL from Clipboard's, and no test touches the person's),
/// released as each test ends.
@MainActor private var kitPasteboards: [NSPasteboard] = []

@MainActor func releaseKitPasteboards() {
    for pasteboard in kitPasteboards { pasteboard.releaseGlobally() }
    kitPasteboards = []
}

@MainActor private func newKitPasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard.withUniqueName()
    kitPasteboards.append(pasteboard)
    return pasteboard
}

/// Every plugin the kit's kinds contribute to (Selection's resizing; Titles, and through it Adornments and slash commands;
/// Mentions, and through it the panel, the context menu and Topology; the table of contents; Draw, whose writers it gives;
/// Clipboard, whose paste readers it gives, on the tests' own pasteboard; the keys), the kit's own plugin, CanvasTesting's
/// fixtures (boxes) and its freezing (a locked shape, without Locking). With `find`, Find and the kit's rows as its texts too.
@MainActor func kitPlugins(_ refusals: RefusalLog = RefusalLog(), find: Bool = false) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), DrawPlugin(), AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
     ClipboardPlugin(pasteboard: newKitPasteboard()),
     SlashCommandsPlugin(), TableOfContentsPlugin()] + (find ? [FindPlugin()] : []) + [TitlesPlugin(), MentionsPlugin(), PortsPlugin(), TransformPlugin(), LineRowsPlugin(),
     EngineeringPlugin()] + (find ? [EngineeringFindPlugin()] : []) + [FreezingPlugin(log: refusals)]
}

/// An empty board of `kitPlugins`, its view 1000 × 800 at 100% (view points are world units), the kit on unless `on` is false.
@MainActor func kitHarness(on: Bool = true, _ refusals: RefusalLog = RefusalLog()) throws -> EditorHarness {
    let h = try EditorHarness(plugins: kitPlugins(refusals))
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    if on {
        h.editor.turn(EngineeringKit.self, on: true)
        h.editor.undoHistory.seal()
    }
    return h
}

/// `orders`: id uuid pk, customer_id uuid unique, status order_status (the enum, when one is given), placed_at timestamptz?.
func orders(_ frame: CGRect = CGRect(x: 100, y: 100, width: 260, height: 116), status: ShapeID? = nil) -> DatabaseTable {
    DatabaseTable(frame: frame, columns: [
        Column(name: "id", type: TypeRef("uuid"), primaryKey: true),
        Column(name: "customer_id", type: TypeRef("uuid"), unique: true),
        Column(name: "status", type: TypeRef("order_status", shape: status)),
        Column(name: "placed_at", type: TypeRef("timestamptz"), nullable: true),
    ])
}

extension EditorHarness {
    /// A shape of `props` titled `title`, in a step of its own.
    @discardableResult
    func add<P: ShapeProps>(_ props: P, titled title: String?) -> ShapeID {
        var record = ShapeRecord(props)
        record[TitleProperty.self] = title
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// The shapes of a kind on the board, back to front.
    func shapes(_ kind: ShapeKind) -> [AnyShapeRecord] { editor.document.shapes.filter { $0.kind == kind } }

    /// A command typed in the command bar, on the selection or, with none, on every shape on the board.
    @discardableResult
    func slash(_ name: String, _ text: String) -> Bool {
        let ids = editor.selectedShapeIDs
        let target: SlashTarget = ids.isEmpty ? .everything(editor.document.shapes.map(\.id)) : .selection(ids)
        return editor.slashCommands?.run(name, for: target, with: SlashArguments(text)) ?? false
    }

    /// The commands the bar offers for the selection, or every shape with none.
    var offered: [String] {
        let ids = editor.selectedShapeIDs
        return editor.slashCommands?.commands(for: ids.isEmpty ? .everything(editor.document.shapes.map(\.id)) : .selection(ids)).map(\.name) ?? []
    }
}

/// The canvas, `size` view points, drawn as `renderBitmap` draws it, in the light appearance or the dark.
@MainActor func render(_ editor: CanvasEditor, size: CGSize = CGSize(width: 600, height: 500), dark: Bool = false) -> NSBitmapImageRep {
    guard dark else { return renderBitmap(editor, size: size) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        let bounds = CGRect(origin: .zero, size: size)
        editor.draw(in: cg, bounds: bounds, dirtyRect: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

@MainActor func expectColor(_ actual: [Int], _ expected: [Int], _ what: String, within tolerance: Int = 3,
                            file: StaticString = #fileID, line: UInt = #line) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(what): \(actual) is not about \(expected)", file: file, line: line)
}

/// The paper, #EBEBEB, in both appearances.
let paper = [235, 235, 235]
