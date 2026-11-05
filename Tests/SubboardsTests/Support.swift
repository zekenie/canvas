import Adornments
import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Colors
import Connections
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import SlashCommands
import Subboards
import SwiftUI
import TableOfContents
import TestKit
import Titles
import Topology
import Transform
import Types

/// Every plugin a subboard contributes to (Boards, and through it Selection, ContextMenus and the
/// panel; Titles, and slash commands for its `/title` and `/turn-into-subboard`; Transform, whose
/// container channel it takes; Colors, whose color it opts into (it needs slash commands and context menus); Ports, which owns its channel and its ports; Mentions, the table of
/// contents and the keys), and CanvasTesting's fixtures, for boxes. No connector, so no dots show.
@MainActor func subboardPlugins() -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), SubboardsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
     SlashCommandsPlugin(), TableOfContentsPlugin(), AdornmentsPlugin(), PortsPlugin(), TitlesPlugin(), MentionsPlugin(), BoardsPlugin(),
     TransformPlugin(), ColorsPlugin(), TypesPlugin()]
}

/// A channel of another plugin's, which a subboard has ports on too: it takes every channel there is.
enum Wire {}
extension Wire: Channel {
    static let id: ChannelID = "wire"
}

func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }

/// Where a card sits in the tests that draw it: in a 320 × 240 canvas, 40 in from the top left.
let cardFrame = CGRect(x: 40, y: 40, width: 240, height: 160)

/// A root holding subboard S (at `cardFrame`) and box A below it; S's board holding `inside` boxes
/// and subboard T, whose board holds box B.
struct Nest {
    let s = ShapeID(), a = ShapeID(), t = ShapeID(), b = ShapeID()
    var inside = 2
    var sBoard: BoardID { BoardID(owner: s) }
    var tBoard: BoardID { BoardID(owner: t) }
    /// S's middle, on the root, while the camera hasn't moved.
    let sPoint = CGPoint(x: 160, y: 120)

    func file(title: String? = nil) -> CanvasFile {
        var sub = ShapeRecord(id: s, Subboard(frame: cardFrame))
        sub[TitleProperty.self] = title
        let boxes = (0..<inside).map { i in record(ShapeID(), Box(CGRect(x: CGFloat(i) * 120, y: 0, width: 100, height: 100))) }
        return CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(sub), record(a, Box(CGRect(x: 40, y: 260, width: 100, height: 100)))]),
                          children: [s: CanvasDocument(shapes: boxes + [record(t, Subboard(frame: CGRect(x: 0, y: 200, width: 240, height: 160)))]),
                                     t: CanvasDocument(shapes: [record(b, Box(CGRect(x: 0, y: 0, width: 100, height: 100)))])])
    }
}

@MainActor func nestHarness(_ nest: Nest = Nest(), title: String? = nil) throws -> EditorHarness {
    try EditorHarness(plugins: subboardPlugins(), file: nest.file(title: title))
}

extension CanvasEditor {
    /// A shape's name as Titles keeps it, as typed.
    func name(_ id: ShapeID) -> String? { document[id]?[TitleProperty.self] }
}

extension EditorHarness {
    /// ⌘ and a key on the canvas: whether a shortcut took it.
    func command(_ key: Character) -> Bool {
        hold(.command)
        defer { hold([]) }
        return self.key(String(key))
    }
}

/// The canvas with one subboard at `cardFrame`, titled `title`, whose board holds `inside` boxes,
/// in the light appearance, or the dark.
@MainActor func render(title: String?, inside: Int = 0, dark: Bool = false) throws -> NSBitmapImageRep {
    var nest = Nest()
    nest.inside = inside
    var file = nest.file(title: title)
    // Only the subboard: no box below it, and nothing nested but the boxes.
    file = CanvasFile(root: CanvasDocument(shapes: file.root.shapes.filter { $0.id == nest.s }),
                      children: inside == 0 ? [:] : [nest.s: CanvasDocument(shapes: (file.children[nest.s]?.shapes ?? []).filter { $0.kind == Box.kind })])
    let editor = try CanvasEditor(registry: Registry(plugins: subboardPlugins()), file: file, scheduler: ManualScheduler())
    return dark ? renderDark(editor, size: CGSize(width: 320, height: 240)) : renderBitmap(editor, size: CGSize(width: 320, height: 240))
}

/// The card's fill on the light canvas, a faint indigo over white.
let cardFill = [250, 250, 255]

/// Draws as `renderBitmap` does, in the dark appearance.
@MainActor func renderDark(_ editor: CanvasEditor, size: CGSize) -> NSBitmapImageRep {
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

/// The darkest channel of the darkest pixel in `rect`: text drawn dark reads low, the placeholder's
/// light gray higher, and nothing but the card's fills higher still.
@MainActor func darkest(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Int {
    var darkest = 255
    for y in stride(from: rect.minY, to: rect.maxY, by: 1) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 1) {
            darkest = min(darkest, pixel(bitmap, at: CGPoint(x: x, y: y)).prefix(3).max() ?? 255)
        }
    }
    return darkest
}

/// Whether a pixel in `rect` is the kind's indigo: blue well over red, as its symbol is drawn.
@MainActor func hasIndigo(_ bitmap: NSBitmapImageRep, in rect: CGRect) -> Bool {
    stride(from: rect.minY, to: rect.maxY, by: 1).contains { y in
        stride(from: rect.minX, to: rect.maxX, by: 1).contains { x in
            let p = pixel(bitmap, at: CGPoint(x: x, y: y))
            return p[2] > p[0] + 80
        }
    }
}

@MainActor func expectColor(_ actual: [Int], _ expected: [Int], _ what: String, within tolerance: Int = 12,
                            file: StaticString = #fileID, line: UInt = #line) {
    expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= tolerance }, "\(what): \(actual) is not about \(expected)", file: file, line: line)
}

/// The canvas and the panel side by side in an unshown window, as the app places them. The editor
/// keeps real time, so SwiftUI's updates land while the main run loop runs (`window.spin`).
@MainActor
final class PanelWindow {
    let editor: CanvasEditor
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas: CanvasView
    let hosting: NSView

    init(_ editor: CanvasEditor) {
        self.editor = editor
        canvas = CanvasView(editor: editor)
        canvas.frame = CGRect(x: 0, y: 0, width: 900 - DetailStyle.idealWidth, height: 600)
        let canvas = canvas, window = window
        // Weak: the window holds the panel, which holds this.
        hosting = NSHostingView(rootView: DetailPanelView(editor: editor, onExit: { [weak window, weak canvas] in
            if let canvas { window?.makeFirstResponder(canvas) }
        }))
        hosting.frame = CGRect(x: 900 - DetailStyle.idealWidth, y: 0, width: DetailStyle.idealWidth, height: 600)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        root.addSubview(canvas)
        root.addSubview(hosting)
        window.contentView = root
        window.settle()
    }

    /// The header's title field: in the panel's top 44 points.
    var titleField: NSTextField? {
        hosting.descendants(NSTextField.self).first { $0.isEditable && $0.convert($0.bounds, to: hosting).maxY <= 44 }
    }
}
