import Adornments
import AppKit
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import LanguageModels
import Mentions
import Ports
import Schemas
import Selection
import TableOfContents
import TestKit
import Titles
import Topology
import Validation

/// Every plugin a schema card contributes to (validation, the table of contents, titles, mentions and
/// the context menu their Show What Mentions is in, the detail panel, ports), with the keyboard and
/// the selection, to place and select one as a person does, Adornments, which Titles places its pill
/// with, and the language model its sync asks: a scripted one, so no test reaches the network.
@MainActor func schemaPlugins(model: any LanguageModel = ScriptedLanguageModel()) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), SchemasPlugin(), ValidationPlugin(), AdornmentsPlugin(), ContextMenusPlugin(),
     TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(), DetailPanelPlugin(), PortsPlugin(), LanguageModelsPlugin(model: model)]
}

@MainActor func schemaEditor(scheduler: any Scheduler = ManualScheduler(), model: any LanguageModel = ScriptedLanguageModel(),
                             document: CanvasDocument = CanvasDocument(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: schemaPlugins(model: model) + more), file: file ?? CanvasFile(root: document), scheduler: scheduler)
}

/// A card at `origin`, `width` wide, of `schema`, as tall as its description makes it (a line's,
/// with none).
@MainActor func card(_ schema: String, prompt: String = "", at origin: CGPoint = CGPoint(x: 40, y: 40), width: CGFloat = 240) -> SchemaCard {
    var card = SchemaCard(frame: CGRect(origin: origin, size: CGSize(width: width, height: SchemaCard.defaultSize.height)), schema: SchemaText(schema))
    card.setPrompt(SchemaPromptText(plain: prompt))
    return card
}

extension CanvasEditor {
    @discardableResult
    func add(_ props: SchemaCard, id: ShapeID = ShapeID()) -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(id: id, props))
        transact { $0.insert(record) }
        return record.id
    }

    func schemaCard(_ id: ShapeID) -> SchemaCard? { document[id]?.typed(as: SchemaCard.self)?.props }

    func issues(_ id: ShapeID) -> [ValidationIssue] { validation?.result(for: id)?.issues ?? [] }
}

/// Whether any pixel in `rect` (view points) is about `color`.
@MainActor func contains(_ bitmap: NSBitmapImageRep, _ color: [Int], in rect: CGRect, within tolerance: Int = 12) -> Bool {
    stride(from: rect.minY, to: rect.maxY, by: 1).contains { y in
        stride(from: rect.minX, to: rect.maxX, by: 1).contains { x in
            zip(pixel(bitmap, at: CGPoint(x: x, y: y)), color).allSatisfy { abs($0 - $1) <= tolerance }
        }
    }
}

/// Whether any pixel in `rect` is text-dark (every channel below `below`).
@MainActor func hasInk(_ bitmap: NSBitmapImageRep, in rect: CGRect, below: Int = 140) -> Bool {
    stride(from: rect.minY, to: rect.maxY, by: 1).contains { y in
        stride(from: rect.minX, to: rect.maxX, by: 1).contains { x in pixel(bitmap, at: CGPoint(x: x, y: y)).prefix(3).allSatisfy { $0 < below } }
    }
}

/// Colors on the card, as 0...255 sRGB (renderBitmap draws in device RGB, close enough here).
enum Palette {
    static let card = [255, 255, 255]
    static let accent = [191, 46, 158]
    /// A skeleton's greeked text (the canvas's, a fifth of black) on the card.
    static let textBar = [204, 204, 204]
    /// A skeleton's edge, inside its frame.
    static let skeletonEdge = [230, 230, 230]
}
