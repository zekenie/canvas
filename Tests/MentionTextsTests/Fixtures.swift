import Adornments
@_spi(Host) import Canvas
import CanvasRPC
import ContextMenus
import CoreGraphics
import DetailPanel
import Draw
import Keyboard
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Validation

// Fixtures only, so these tests show MentionTextsPlugin's text knows no real kind: a folder (titled,
// mentionable, and the one kind a dispatch's `to` may mention), a crate (titled, but not mentionable),
// and a dispatch, titled and mentionable too, that holds every kind of mention text there is: any
// (`body`), only folders (`to`), a declared scope (`tags`: what joined `Crew`, the folders), and
// texts inside a list of objects (`steps`).

struct Folder: BoxShapeProps {
    static let kind: ShapeKind = "folder"
    static let properties = Properties<Folder> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Folder {
    init() { self.init(.zero) }
}

struct FolderDefinition {}

extension FolderDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Folder>, in context: RenderContext) {}
}

/// A titled kind that can't be mentioned.
struct Crate: BoxShapeProps {
    static let kind: ShapeKind = "crate"
    static let properties = Properties<Crate> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Crate {
    init() { self.init(.zero) }
}

struct CrateDefinition {}

extension CrateDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Crate>, in context: RenderContext) {}
}

/// What the folders belong to, as a declared scope.
enum Crew {}

extension Crew: DeclaredMentionScope {
    static let title = "Crew"
}

/// A step of a dispatch: what it says, which may mention anything.
struct Step: SchemaDefined, Equatable {
    static let properties = Properties<Step> {
        Property("text", \.text)
    }
    var text: MentionText = ""
}

/// A step holds mention text, so it names shapes too: nothing to write.
extension Step: ShapeNaming {}

struct Dispatch: BoxShapeProps {
    static let kind: ShapeKind = "dispatch"
    static let properties = Properties<Dispatch>(title: "Dispatch") {
        Property("frame", \.frame).required()
        Property("body", \.body)
        Property("to", \.to)
        Property("tags", \.tags)
        Property("steps", \.steps)
    }
    var frame: CGRect
    var body: MentionText = ""
    var to: ScopedMentionText<Only<Folder>> = ""
    var tags: ScopedMentionText<Crew> = ""
    var steps: [Step] = []
    init(_ frame: CGRect) { self.frame = frame }
}

extension Dispatch {
    init() { self.init(.zero) }
}

struct DispatchDefinition {}

extension DispatchDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Dispatch>, in context: RenderContext) {}
}

struct DispatchFixturesPlugin: CanvasPlugin {
    var id: PluginID { "dispatch-fixtures" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.mentionScope(Crew.self)
        registrar.shape(FolderDefinition()) { folder in
            folder.tool(label: "Folder", systemImage: "folder", placing: folder.placement(size: CGSize(width: 120, height: 80)) { Folder() })
            folder.title()
            folder.mentionable()
            folder.mentionable(in: Crew.self)
        }
        registrar.shape(CrateDefinition()) { crate in
            crate.tool(label: "Crate", systemImage: "shippingbox", placing: crate.placement(size: CGSize(width: 100, height: 100)) { Crate() })
            crate.title()
        }
        registrar.shape(DispatchDefinition()) { dispatch in
            dispatch.tool(label: "Dispatch", systemImage: "paperplane", placing: dispatch.placement(size: CGSize(width: 160, height: 100)) { Dispatch() })
            dispatch.title()
            dispatch.mentionable()
        }
    }
}

/// An editor 800 × 600 points with the fixtures' kinds, Titles and Mentions (and what they stand
/// on), Validation and Mentions' rule, and draw's words for them: names, checks, and (unless not)
/// the mention texts.
@MainActor func mentionTextsEditor(mentionTexts: Bool = true) throws -> CanvasEditor {
    let plugins: [any CanvasPlugin] = [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), DrawPlugin(), DispatchFixturesPlugin(),
                                       ValidationPlugin(), AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(),
                                       TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(), MentionValidationPlugin(),
                                       TitleNamesPlugin(), ValidationChecksPlugin()] + (mentionTexts ? [MentionTextsPlugin()] : [])
    let editor = CanvasEditor(registry: try Registry(plugins: plugins))
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// What `canvas draw -` says of a script that runs, as the wire carries it.
@MainActor func drawn(_ script: String, on editor: CanvasEditor, dryRun: Bool = false) throws -> JSON {
    try JSON(encoding: draw(script: script, dryRun: dryRun, reveal: false, program: RPC.commandName, in: editor))
}

/// Why `canvas draw -` refused a script: its error.
@MainActor func refused(_ script: String, on editor: CanvasEditor) throws -> DrawError {
    do throws(DrawError) {
        _ = try draw(script: script, dryRun: false, reveal: false, program: RPC.commandName, in: editor)
    } catch {
        return error
    }
    throw DrewAnyway()
}

struct DrewAnyway: Error {}

/// What `canvas kinds` says of a kind, as the wire carries it: a list of it alone.
@MainActor func kindsListed(named: String, in registry: Registry) throws -> JSON {
    try JSON(encoding: kinds(named: named, in: registry))
}

/// A result's rows' `did`s.
func dids(_ result: JSON) -> [JSON?] { (result["changes"]?.arrayValue ?? []).map { $0["did"] } }

/// A result's warnings, as `line: message`.
func warnings(_ result: JSON) -> [String] {
    (result["warnings"]?.arrayValue ?? []).map { "\($0["line"]?.intValue ?? 0): \($0["message"]?.stringValue ?? "")" }
}

extension CanvasEditor {
    /// The shape the script made called this, of any kind.
    func shape(called title: String) -> AnyShapeRecord? {
        document.shapes.first { registry.title(of: $0) == title }
    }

    /// A dispatch's props.
    func dispatch(_ title: String) -> Dispatch? { shape(called: title)?.typed(as: Dispatch.self)?.props }
}
