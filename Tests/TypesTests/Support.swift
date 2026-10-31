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
import TestKit
import TextEditing
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
            memo.canBeRelationshipType()
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

/// An editor over `typePlugins` and `more`. With the model the plugins default to (a scripted one no test asks of) and plugins with
/// nothing of their own to hold, the registry is the one every such editor of the executable is over (`typeRegistry`); a test that
/// hands a model or a plugin with state of its own (a log, a probe, a switch) gets a registry of its own.
@MainActor func typeEditor(scheduler: any Scheduler = ManualScheduler(), model: (any LanguageModel)? = nil,
                           document: CanvasDocument = CanvasDocument(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    CanvasEditor(registry: try typeRegistry(model: model, more: more), file: file ?? CanvasFile(root: document), scheduler: scheduler)
}

@MainActor private var sharedTypeRegistries: [String: Registry] = [:]

/// The registry of `typePlugins(model:)` and `more`. A registry is frozen, so what one test's editors do cannot reach another's, and
/// making one (every plugin registering, every schema compiled) costs some 10 ms in a debug build, more than the editor a test of a
/// small board opens on it: so one is made for each list of plugins that are structs with no stored property, over the default model,
/// and every editor asking for that list is over it. Any other plugin or model gets a registry made for it.
@MainActor func typeRegistry(model: (any LanguageModel)? = nil, more: [any CanvasPlugin] = []) throws -> Registry {
    let nothingOfTheirOwn = more.allSatisfy { plugin in
        let mirror = Mirror(reflecting: plugin)
        return mirror.displayStyle == .struct && mirror.children.isEmpty
    }
    guard model == nil, nothingOfTheirOwn else { return try Registry(plugins: typePlugins(model: model ?? ScriptedLanguageModel()) + more) }
    let key = more.map { String(reflecting: type(of: $0)) }.joined(separator: ",")
    if let known = sharedTypeRegistries[key] { return known }
    let made = try Registry(plugins: typePlugins() + more)
    sharedTypeRegistries[key] = made
    return made
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

/// A bitmap's pixels as colors in `space`, exactly as `colorAt(x:y:)?.usingColorSpace(space)` gives them, but each distinct pixel
/// value converted once (CanvasTesting's `DeviceRGBPixels` does that for device RGB, with no alpha): read that way pixel by pixel, a
/// form's or a panel's render takes seconds, a color made and converted for each of its hundreds of thousands of pixels, of which
/// only a few hundred values are distinct.
@MainActor
final class PixelColors {
    private let rep: NSBitmapImageRep
    private let space: NSColorSpace
    /// The pixels, when they're whole bytes in one plane (else each is converted as it's read).
    private let bytes: UnsafeMutablePointer<UInt8>?
    private let bytesPerRow: Int, bytesPerPixel: Int
    private var converted: [UInt64: NSColor?] = [:]

    init(_ rep: NSBitmapImageRep, in space: NSColorSpace) {
        self.rep = rep
        self.space = space
        // The data first: a rep backed by a CGImage makes its bitmap, and so its layout, as it's asked for it.
        let data = rep.bitmapData
        bytesPerRow = rep.bytesPerRow
        bytesPerPixel = rep.bitsPerPixel / 8
        bytes = !rep.isPlanar && rep.bitsPerPixel % 8 == 0 && (1...8).contains(bytesPerPixel) ? data : nil
    }

    /// The color of the pixel at column `x`, row `y` from the top; nil where `colorAt` has none.
    subscript(x: Int, y: Int) -> NSColor? {
        guard (0..<rep.pixelsWide).contains(x), (0..<rep.pixelsHigh).contains(y) else { return nil }
        guard let bytes else { return convert(x, y) }
        let pixel = UnsafeRawPointer(bytes + y * bytesPerRow + x * bytesPerPixel)
        var value: UInt64 = 0
        for i in 0..<bytesPerPixel { value = value << 8 | UInt64(pixel.load(fromByteOffset: i, as: UInt8.self)) }
        if let known = converted[value] { return known }
        let color = convert(x, y)
        converted[value] = color
        return color
    }

    private func convert(_ x: Int, _ y: Int) -> NSColor? { rep.colorAt(x: x, y: y)?.usingColorSpace(space) }
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

/// A text view that hosts slash commands over a memo's line, as a mention text view does: it forwards what's
/// typed, every change to the text and the caret, and each key to `SlashCommandTyping`, and shows its list
/// as its own. A memo is not edited, so the text is nobody's but the view's.
@MainActor
final class IsAView: EditingTextView {
    private(set) var slashCommands: SlashCommandTyping?
    /// Between `shouldChangeText` and `didChangeText`: the selection moving then is the edit's.
    private var isChangingText = false

    init(frame: CGRect, owner: ShapeID, commands: SlashCommandState) {
        super.init(frame: frame)
        isRichText = false
        allowsUndo = true
        slashCommands = SlashCommandTyping(over: self, owner: owner, commands: commands)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var caretListWindow: CaretListWindow? { slashCommands?.window }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let should = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if should { isChangingText = true }
        return should
    }

    override func didChangeText() {
        isChangingText = false
        super.didChangeText()
        slashCommands?.didChange(isEdit: true)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isChangingText { slashCommands?.didChange(isEdit: false) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if !wasComposing, !hasMarkedText() { slashCommands?.didType(typed) }
    }

    override func keyDown(with event: NSEvent) {
        if slashCommands?.takesKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// `/is-a` typed on an empty line for a shape, in an unshown window with the keyboard in it: the real list
/// (`SlashChoicePicker`) that `type` narrows and the keys move and pick from.
@MainActor
final class IsALine {
    let editor: CanvasEditor
    let window: NSWindow
    let view: IsAView

    init(on owner: ShapeID, in editor: CanvasEditor) throws {
        self.editor = editor
        view = IsAView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), owner: owner, commands: try require(editor.slashCommands))
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
    }

    /// The open list of choices; nil once it has closed.
    var choices: SlashChoicePicker? { view.slashCommands?.choices }
    /// The titles of its rows, in order: none for a list that is closed or says nothing matches.
    var titles: [String] { choices?.listed.map(\.title) ?? [] }
    var highlighted: String? { choices?.highlightedChoice?.title }

    func type(_ text: String) { window.type(text) }
    func down() { window.press("\u{F701}", code: 125, modifiers: [.numericPad, .function]) }
    func up() { window.press("\u{F700}", code: 126, modifiers: [.numericPad, .function]) }
    func returnKey() { window.pressReturn() }
}
