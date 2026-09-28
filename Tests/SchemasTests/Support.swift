import Adornments
import AppKit
import Canvas
import CanvasTesting
import DetailPanel
import Keyboard
import LanguageModels
import Ports
import Schemas
import Selection
import TableOfContents
import TestKit
import Titles
import Validation

/// Every plugin a schema card contributes to (validation, the table of contents, titles, the detail
/// panel, ports), with the keyboard and the selection, to place and select one as a person does,
/// Adornments, which Titles places its pill with, and the language model its sync asks: a scripted
/// one, so no test reaches the network.
@MainActor func schemaPlugins(model: any LanguageModel = ScriptedLanguageModel()) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), SchemasPlugin(), ValidationPlugin(), AdornmentsPlugin(), TableOfContentsPlugin(), TitlesPlugin(),
     DetailPanelPlugin(), PortsPlugin(), LanguageModelsPlugin(model: model)]
}

@MainActor func schemaEditor(scheduler: any Scheduler = ManualScheduler(), model: any LanguageModel = ScriptedLanguageModel(),
                             document: CanvasDocument = CanvasDocument(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: schemaPlugins(model: model) + more), file: file ?? CanvasFile(root: document), scheduler: scheduler)
}

/// A card at `origin`, `width` wide, as tall as its schema makes it (the empty card's height for a
/// text that isn't a JSON object).
func card(_ schema: String, at origin: CGPoint = CGPoint(x: 40, y: 40), width: CGFloat = 240) -> SchemaCard {
    var card = SchemaCard(frame: CGRect(origin: origin, size: CGSize(width: width, height: SchemaCard.defaultSize.height)))
    card.setSchema(schema)
    return card
}

extension CanvasEditor {
    @discardableResult
    func add(_ props: SchemaCard) -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(props))
        transact { $0.insert(record) }
        return record.id
    }

    func schemaCard(_ id: ShapeID) -> SchemaCard? { document[id]?.typed(as: SchemaCard.self)?.props }

    func issues(_ id: ShapeID) -> [ValidationIssue] { validation?.result(for: id)?.issues ?? [] }
}

/// What a card of `size` shows for `schema`, each row as it reads.
@MainActor func rows(_ schema: String, size: CGSize? = nil) -> [String] {
    let layout = SchemaCardLayout(SchemaDocument(schema), size: size ?? CGSize(width: 240, height: SchemaCard.height(for: schema) ?? 67))
    return layout.rows.map(\.text) + (layout.more > 0 ? ["+\(layout.more) more"] : []) + (layout.rules.map { ["Rules \($0)"] } ?? [])
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
    static let chip = [241, 241, 241]
    static let accent = [102, 92, 219]
    static let bar = [204, 204, 204]
}
