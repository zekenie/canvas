import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import TableOfContents
import TestKit
import Titles

// Fixtures only: CanvasTesting's kinds (a `Box` can't be mentioned) and a few kinds of this
// target's own, so every test here shows Mentions knows no real kind. C's and E's tests use these
// too, and keep fixtures of their own in their own files.

/// A box named with a title Titles keeps, mentionable as its defaults have it: its title, else
/// "Untitled Plate", with its tool's symbol. It joins `Blockers`.
struct Plate: BoxShapeProps {
    static let kind: ShapeKind = "plate"
    static let properties = Properties<Plate> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Plate {
    init() { self.init(.zero) }
}

struct PlateDefinition {}

extension PlateDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Plate>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemTeal)
    }
}

/// An untitled kind called by its caption, with a symbol, detail and tint of its own: a token with
/// a blank caption is "Untitled Token".
struct Token: BoxShapeProps {
    static let kind: ShapeKind = "token"
    static let properties = Properties<Token> {
        Property("frame", \.frame).required()
        Property("caption", \.caption)
        Property("isStarred", \.isStarred)
    }
    var frame: CGRect
    var caption = ""
    var isStarred = false
    init(_ frame: CGRect, caption: String = "", isStarred: Bool = false) {
        self.frame = frame
        self.caption = caption
        self.isStarred = isStarred
    }
}

extension Token {
    init() { self.init(.zero) }
}

struct TokenDefinition {}

extension TokenDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Token>, in context: RenderContext) {
        context.fillWithShadow(CGPath(ellipseIn: shape.frame, transform: nil), .systemOrange)
    }
}

/// A kind called by `label:`, before its title: an endpoint is its path ("GET /users").
struct Endpoint: BoxShapeProps {
    static let kind: ShapeKind = "endpoint"
    static let properties = Properties<Endpoint> {
        Property("frame", \.frame).required()
        Property("path", \.path)
    }
    var frame: CGRect
    var path = ""
    init(_ frame: CGRect, path: String = "") {
        self.frame = frame
        self.path = path
    }
}

extension Endpoint {
    init() { self.init(.zero) }
}

struct EndpointDefinition {}

extension EndpointDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Endpoint>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemPurple)
    }
}

/// An editable box whose text may mention shapes, as a sticky note's: it draws its text with
/// `drawMentionText` through its one placement, edits it in a `MentionTextView`, names its row
/// with the text's live names, and is mentioned by its title, else its first line.
struct Jot: BoxShapeProps {
    static let kind: ShapeKind = "jot"
    static let properties = Properties<Jot> {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the jot says.")
    }
    var frame: CGRect
    var text: MentionText
    init(_ frame: CGRect, text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
}

extension Jot {
    init() { self.init(.zero) }
}

@MainActor
enum JotStyle {
    static let size = CGSize(width: 200, height: 200)
    static let padding: CGFloat = 16
    static let color = NSColor(srgbRed: 1.0, green: 0.87, blue: 0.45, alpha: 1)
    /// As a note's text: 16 points in fixed 19-point lines.
    static let text = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: 19)
    /// TextKit 2 sets a line's glyphs a point lower than string drawing does.
    static let editorInset = NSSize(width: padding, height: padding - 1)
}

extension ShapeRecord where Props == Jot {
    /// Where the jot draws its text: the render and the pills both read this.
    @MainActor var mentionTexts: [MentionTextPlacement] {
        [MentionTextPlacement(props.text, in: props.frame.insetBy(dx: JotStyle.padding, dy: JotStyle.padding), style: JotStyle.text)]
    }
}

struct JotDefinition {}

extension JotDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Jot>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), JotStyle.color)
        guard !context.isEditing else { return }
        for placement in shape.mentionTexts { context.drawMentionText(placement) }
    }
}

extension JotDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Jot>, context: EditContext<Jot>) -> EditingView {
        let editor = JotEditor(text: shape.props.text, size: shape.frame.size, context: context)
        return EditingView(view: editor, firstResponder: editor.textView)
    }
}

/// The jot's editing view: a `MentionTextView` over the jot, as the note's editor is.
final class JotEditor: NSView, NSTextViewDelegate {
    let textView: MentionTextView<AnyMentionable>
    private let context: EditContext<Jot>

    init(text: MentionText, size: CGSize, context: EditContext<Jot>) {
        self.context = context
        textView = MentionTextView(frame: CGRect(origin: .zero, size: size), text: text, style: JotStyle.text,
                                   owner: context.shapeID, mentions: context.service(MentionState.self))
        super.init(frame: .zero)
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = JotStyle.editorInset
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        clipsToBounds = true
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func textDidChange(_ notification: Notification) {
        let text = textView.mentionText
        context.update { if $0.text != text { $0.text = text } }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        context.end()
        return true
    }
}

/// Text restricted to what may block: plates and tokens join it.
enum Blockers {}

extension Blockers: DeclaredMentionScope {
    static let title = "Blockers"
}

/// A kind holding restricted text: only plates, or only what may block.
struct Brief: BoxShapeProps {
    static let kind: ShapeKind = "brief"
    static let properties = Properties<Brief> {
        Property("frame", \.frame).required()
        Property("plates", \.plates)
        Property("blockedBy", \.blockedBy)
    }
    var frame: CGRect
    var plates: ScopedMentionText<Only<Plate>> = ""
    var blockedBy: ScopedMentionText<Blockers> = ""
    init(_ frame: CGRect) { self.frame = frame }
}

extension Brief {
    init() { self.init(.zero) }
}

struct BriefDefinition {}

extension BriefDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Brief>, in context: RenderContext) {}
}

/// Plates, tokens, endpoints, jots and briefs, each with a place tool (no key).
struct MentionFixturesPlugin: CanvasPlugin {
    var id: PluginID { "mention-fixtures" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.mentionScope(Blockers.self)
        registrar.shape(PlateDefinition()) { plate in
            plate.tool(label: "Plate", systemImage: "rectangle.fill", placing: plate.placement(size: CGSize(width: 120, height: 80)) { Plate() })
            plate.title()
            plate.mentionable()
            plate.mentionable(in: Blockers.self)
        }
        registrar.shape(TokenDefinition()) { token in
            token.tool(label: "Token", systemImage: "circle", placing: token.placement(size: CGSize(width: 60, height: 60)) { Token() })
            token.mentionable(untitled: { $0.props.caption },
                              symbol: { $0.props.isStarred ? "star.fill" : nil },
                              detail: { $0.props.isStarred ? "Starred" : nil },
                              tint: { $0.props.isStarred ? .systemYellow : nil })
        }
        registrar.mentionable(Token.self, in: Blockers.self)
        registrar.shape(EndpointDefinition()) { endpoint in
            endpoint.tool(label: "Endpoint", systemImage: "network",
                          placing: endpoint.placement(size: CGSize(width: 160, height: 60)) { Endpoint() })
            endpoint.title()
            endpoint.mentionable(label: { $0.props.path })
        }
        registrar.shape(JotDefinition()) { jot in
            jot.tool(label: "Jot", systemImage: "note.text", placing: jot.editingPlacement(size: JotStyle.size) { Jot() })
            jot.title()
            jot.mentionable(untitled: { $0.props.text.firstLine })
            jot.mentionText { $0.mentionTexts }
            jot.contentsRow(affected: MentionRows.affected) { jot, context in
                ContentsLabel(context.plainText(jot.props.text), placeholder: "Empty Jot")
            }
        }
        registrar.shape(BriefDefinition())
    }
}

/// The standard list: the keyboard and the selection first, CanvasTesting's fixtures (boxes, discs,
/// tags), this target's, adornments (Titles' pills), the detail panel, the context menu (where
/// Mentions puts Show What Mentions), the table of contents, titles, then Mentions, then `more`.
@MainActor func mentionPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), MentionFixturesPlugin(), AdornmentsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin()] + more
}

extension EditorHarness {
    /// A shape of the document by id, read after the id is worked out (a lookup whose subscript
    /// inserts the shape would read the document from before).
    func record(_ id: ShapeID) -> AnyShapeRecord? { editor.document[id] }
}

@MainActor func mentionHarness(_ more: [any CanvasPlugin] = [], document: CanvasDocument = CanvasDocument()) throws -> EditorHarness {
    try EditorHarness(plugins: mentionPlugins(more), document: document)
}

extension CanvasEditor {
    /// Inserts a shape titled `title` (nil: untitled), in a transaction of its own.
    @discardableResult
    func add<P: ShapeProps>(_ props: P, titled title: String?, id: ShapeID = ShapeID()) -> ShapeID {
        var shape = ShapeRecord(id: id, props)
        shape[TitleProperty.self] = title
        transact { $0.insert(shape) }
        return shape.id
    }

    func rename(_ id: ShapeID, _ title: String?) {
        transact { $0.update(id) { $0[TitleProperty.self] = title } }
    }

    func setText(_ id: ShapeID, _ text: MentionText) {
        transact { $0.update(id, as: Jot.self) { $0.props.text = text } }
    }

    func delete(_ ids: ShapeID...) {
        transact { $0.delete(Set(ids)) }
    }

    var mentionState: MentionState { service(MentionState.self)! }
}

/// A mention text that mentions `targets`, each with the label given, between words.
func mentioning(_ parts: [MentionRun]) -> MentionText { MentionText(parts) }

/// Fixed ids, so a test's stored text is the same every run.
let idA = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
let idB = ShapeID(UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!)
let idC = ShapeID(UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)

/// A shape of `kind` a board keeps aside, as one from a newer version of its kind: read from a
/// board, as nothing else makes one.
@MainActor func keptAside(_ kind: ShapeKind, id: ShapeID, in registry: Registry) throws -> AnyShapeRecord {
    let json = """
    { "format" : 1, "schema" : { "\(kind.rawValue)" : 99 }, "shapes" : [
      { "id" : "\(id)", "kind" : "\(kind.rawValue)", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] } } ] }
    """
    let record = try require(BoardCodec(registry: registry).decode(Data(json.utf8)).document[id])
    expect(record.isOpaque)
    return record
}

/// The editor's document with `records` appended, as a board read again from disk puts it in place
/// (the only way a shape kept aside comes into an editor).
@MainActor func append(_ records: [AnyShapeRecord], to editor: CanvasEditor) {
    editor.replaceDocument(with: CanvasDocument(shapes: editor.document.shapes + records))
}
