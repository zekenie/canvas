import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import ContextMenus
import DetailPanel
import Draw
import Keyboard
import LanguageModels
import Mentions
import ProseMaps
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Types
import Validation

// Fixtures only: a memo, a box of words that is titled, can be a type and be an instance of one
// (`canBeType()`, `typeable()`) as a note is, a slab, titled and nothing else, and a plain pocket's
// worth of nothing. Types' draw words know no kind.

struct Memo: BoxShapeProps {
    static let kind: ShapeKind = "memo"
    static let properties = Properties<Memo>(title: "Memo") {
        Property("frame", \.frame).required()
        Property("text", \.text)
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
struct MemoDefinition: ShapeDefinition {
    static let style = MentionTextStyle(font: .systemFont(ofSize: 16), color: .black, lineHeight: 19)
    static func placement(_ shape: ShapeRecord<Memo>) -> MentionTextPlacement {
        MentionTextPlacement(shape.props.text, in: shape.frame.insetBy(dx: 16, dy: 16), style: style)
    }
    func render(_ shape: ShapeRecord<Memo>, in context: RenderContext) {
        context.drawMentionText(Self.placement(shape))
    }
}

/// Titled, and nothing else: it is no type and no instance.
struct Slab: BoxShapeProps {
    static let kind: ShapeKind = "slab"
    static let properties = Properties<Slab> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 60)) { self.frame = frame }
    init() { self.init(CGRect(x: 0, y: 0, width: 100, height: 60)) }
}

struct SlabDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slab>, in context: RenderContext) {}
}

struct MemosPlugin: CanvasPlugin {
    var id: PluginID { "memos" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(MemoDefinition()) { memo in
            memo.tool(label: "Memo", systemImage: "note.text", placing: memo.placement(size: CGSize(width: 240, height: 52)) { Memo() })
            memo.title()
            memo.mentionText { [MemoDefinition.placement($0)] }
            memo.mentionable(untitled: { $0.props.text.firstLine })
            memo.typeWords(\.text, drawnIn: { MemoDefinition.placement($0) })
            memo.canBeType()
            memo.typeable()
        }
        registrar.shape(SlabDefinition()) { slab in
            slab.tool(label: "Slab", systemImage: "square", placing: slab.placement(size: CGSize(width: 100, height: 60)) { Slab() })
            slab.title()
        }
    }
}

/// An editor 800 × 600 points with the memos, Types and what it stands on, and draw's names and the
/// type words (unless not).
@MainActor func typeNamesEditor(typeNames: Bool = true) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), DrawPlugin(), MemosPlugin(), ValidationPlugin(),
                                       AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(),
                                       TitlesPlugin(), MentionsPlugin(), TypesPlugin(), TypeValidationPlugin(), TypeDetailsPlugin(),
                                       ValidationDetailsPlugin(), LanguageModelsPlugin(model: ScriptedLanguageModel()), ProseMapsPlugin(),
                                       TitleNamesPlugin(), ValidationChecksPlugin()] + (typeNames ? [TypeNamesPlugin(), FieldValuesPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins), scheduler: ManualScheduler())
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// What `canvas draw -` says of a script that runs, as the wire carries it.
@MainActor func drawn(_ script: String, on editor: CanvasEditor, dryRun: Bool = false) throws -> JSON {
    try JSON(encoding: draw(script: script, dryRun: dryRun, reveal: false, program: RPC.commandName, in: editor))
}

/// Why `canvas draw -` refused a script: its error's fields (`reason`, `hint`, `line`, `statement`),
/// and its message.
@MainActor func refused(_ script: String, on editor: CanvasEditor) throws -> JSON {
    do throws(DrawError) {
        _ = try draw(script: script, dryRun: false, reveal: false, program: RPC.commandName, in: editor)
    } catch {
        var data: [String: JSON] = ["reason": .string(error.reason), "message": .string(error.message)]
        if let hint = error.hint { data["hint"] = .string(hint) }
        if let line = error.line { data["line"] = .number(Double(line)) }
        if let statement = error.statement { data["statement"] = .string(statement) }
        return .object(data)
    }
    throw DrewAnyway()
}

/// What `canvas kinds` says, as the wire carries it: a list, of the kind named alone if one is.
@MainActor func kindsListed(named: String? = nil, in registry: Registry) throws -> JSON {
    try JSON(encoding: kinds(named: named, in: registry))
}

struct DrewAnyway: Error {}

extension CanvasEditor {
    /// The shape the script made called this, of any kind.
    func shape(called title: String) -> AnyShapeRecord? {
        document.shapes.first { registry.title(of: $0) == title }
    }

    /// A memo that is a type, titled, as a person would put it down (`/is-a type` runs the same).
    @discardableResult
    func addType(_ title: String, schema: String = TypeSchemaProperty.starter) -> ShapeID {
        var record = AnyShapeRecord(ShapeRecord(Memo(frame: CGRect(x: 40, y: 40 + 80 * CGFloat(document.shapes.count), width: 240, height: 52))))
        record[TitleProperty.self] = title
        record[TypeSchemaProperty.self] = SchemaText(schema)
        transact { $0.insert(record) }
        return record.id
    }
}
