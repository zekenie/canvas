import Adornments
import AppKit
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import LanguageModels
import Mentions
import ProseMaps
import Selection
import SlashCommands
import TableOfContents
import Titles
import Topology
import Types
import Validation

// Types knows no kind: these tests make types of a kind of their own, a memo, which hands Types its
// words as a note does (`typeWords`, `canBeType()`), so what's held here holds for any kind.

/// A white box of words: mention text, titled, mentionable, drawn in its padding. Fitted to its
/// words (its height a line's at least) when they're written through `TypeWords`.
struct Memo: BoxShapeProps {
    static let kind: ShapeKind = "memo"
    static let properties = Properties<Memo>(title: "Memo") {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the memo says.")
    }
    var frame: CGRect
    var text: MentionText
    init(frame: CGRect = CGRect(x: 0, y: 0, width: 240, height: 52), text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    init() { self.init(text: "") }
}

@MainActor
enum MemoStyle {
    static let padding: CGFloat = 16
    static let lineHeight: CGFloat = 19
    /// A memo of one line, or none.
    static let emptyHeight = (lineHeight + 0.5).rounded(.up) + padding * 2
    static let text = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: lineHeight)
    static let fill = NSColor.white

    static func textBox(of frame: CGRect) -> CGRect { frame.insetBy(dx: padding, dy: padding) }

    /// As tall as its words at its width, a line at least.
    static func fit(_ memo: inout Memo) {
        let inner = memo.frame.width - padding * 2
        guard inner > 0 else { return }
        let lines = text.measuredString(memo.text, width: inner)
            .boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        memo.frame.size.height = max(emptyHeight, (lines + 0.5).rounded(.up) + padding * 2)
    }

    /// How tall a memo of `lines` lines is.
    static func height(lines: Int) -> CGFloat { max(emptyHeight, (CGFloat(lines) * lineHeight + 0.5).rounded(.up) + padding * 2) }
}

extension ShapeRecord where Props == Memo {
    @MainActor var placement: MentionTextPlacement { MentionTextPlacement(props.text, in: MemoStyle.textBox(of: frame), style: MemoStyle.text) }
}

@MainActor
struct MemoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Memo>, in context: RenderContext) {
        context.cg.setFillColor(MemoStyle.fill.cgColor)
        context.cg.fill(shape.frame)
        context.fillTypeHighlights(of: shape, in: shape.placement)
        context.drawMentionText(shape.placement)
    }
}

struct MemosPlugin: CanvasPlugin {
    /// Whether a tool places a memo (`registry.placement(for:)` reads placements from the tools): a memo
    /// isn't `Editable`, so placing one doesn't edit it.
    var placing = true
    var id: PluginID { "memos" }
    func register(into registrar: inout PluginRegistrar) {
        let placing = placing
        registrar.shape(MemoDefinition()) { memo in
            if placing {
                memo.tool(label: "Memo", systemImage: "note.text", placing: memo.placement(size: CGSize(width: 240, height: 52)) { Memo() })
            }
            memo.title()
            memo.mentionText { [$0.placement] }
            memo.mentionable(untitled: { $0.props.text.firstLine })
            memo.typeWords(\.text, drawnIn: { $0.placement }, fitting: { MemoStyle.fit(&$0) })
            memo.canBeType()
            memo.typeable()
        }
    }
}

/// Every plugin a type contributes to (validation, titles and the slash commands, mentions and the
/// context menu, the detail panel, adornments and the table of contents they show on),
/// with the keyboard and the selection, the language model its sync asks (a scripted one, so no test
/// reaches the network) and the prose maps its highlights are.
@MainActor func typePlugins(model: any LanguageModel = ScriptedLanguageModel()) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), MemosPlugin(), ValidationPlugin(), AdornmentsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(),
     TypesPlugin(), TypeValidationPlugin(), TypeDetailsPlugin(), ValidationDetailsPlugin(),
     LanguageModelsPlugin(model: model), ProseMapsPlugin()]
}

@MainActor func typeEditor(scheduler: any Scheduler = ManualScheduler(), model: any LanguageModel = ScriptedLanguageModel(),
                           document: CanvasDocument = CanvasDocument(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: typePlugins(model: model) + more), file: file ?? CanvasFile(root: document), scheduler: scheduler)
}

/// A memo at `origin`, `width` wide, saying `words`, as tall as they make it.
@MainActor func memo(_ words: String = "", at origin: CGPoint = CGPoint(x: 40, y: 40), width: CGFloat = 240) -> Memo {
    var memo = Memo(frame: CGRect(origin: origin, size: CGSize(width: width, height: MemoStyle.emptyHeight)), text: MentionText(plain: words))
    MemoStyle.fit(&memo)
    return memo
}

/// A memo that's a type: `schema`, and `words`, titled `title` if given.
@MainActor func typeRecord(_ schema: String, words: String = "", title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 40),
                           width: CGFloat = 240, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    typeRecord(schema, words: MentionText(plain: words), title: title, at: origin, width: width, id: id)
}

@MainActor func typeRecord(_ schema: String, words: MentionText, title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 40),
                           width: CGFloat = 240, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var props = memo(at: origin, width: width)
    props.text = words
    MemoStyle.fit(&props)
    var record = ShapeRecord(id: id, props)
    record[TypeSchemaProperty.self] = SchemaText(schema)
    if let title { record[TitleProperty.self] = title }
    return AnyShapeRecord(record)
}

/// A memo that is each of the types, in that order, titled `title` if given.
@MainActor func instanceRecord(_ words: String = "", of types: [ShapeID], title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 400),
                               id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = ShapeRecord(id: id, memo(words, at: origin))
    record[IsAProperty.self] = types.map(TypeLink.init)
    if let title { record[TitleProperty.self] = title }
    return AnyShapeRecord(record)
}

extension CanvasEditor {
    /// Adds a type: a memo with `schema`.
    @discardableResult
    func addType(_ schema: String, words: String = "", title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 40), width: CGFloat = 240) -> ShapeID {
        let record = typeRecord(schema, words: words, title: title, at: origin, width: width)
        transact { $0.insert(record) }
        return record.id
    }

    /// Adds a type whose words are `words`, mentions and all.
    @discardableResult
    func addType(_ schema: String, words: MentionText, at origin: CGPoint = CGPoint(x: 40, y: 40), width: CGFloat = 240) -> ShapeID {
        let record = typeRecord(schema, words: words, at: origin, width: width)
        transact { $0.insert(record) }
        return record.id
    }

    /// Adds a memo that is each of the types, in that order.
    @discardableResult
    func addInstance(_ words: String = "", of types: [ShapeID], title: String? = nil, at origin: CGPoint = CGPoint(x: 40, y: 400)) -> ShapeID {
        let added = instanceRecord(words, of: types, title: title, at: origin)
        transact { $0.insert(added) }
        return added.id
    }

    /// The types a shape is, as its record says.
    func typesOf(_ id: ShapeID) -> [ShapeID] { document[id]?[IsAProperty.self]?.map(\.shape) ?? [] }

    func memo(_ id: ShapeID) -> Memo? { document[id]?.typed(as: Memo.self)?.props }
    func schema(_ id: ShapeID) -> String? { document[id]?[TypeSchemaProperty.self]?.text }
    func words(_ id: ShapeID) -> MentionText? { memo(id)?.text }
    func title(_ id: ShapeID) -> String? { document[id]?[TitleProperty.self] }

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
