import Adornments
import AppKit
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Foundation
import Keyboard
import MentionValidation
import Mentions
import Selection
import TableOfContents
import TestKit
import Titles
import Validation

// Fixtures only, so these tests show the bridge knows no real kind: two kinds that can be
// mentioned, one that can't (and CanvasTesting's boxes, which can't either, and have no tool), and
// a kind whose text may mention any of them, beside text that may mention only cards.

/// A titled box that can be mentioned: the one kind a letter's `to` admits.
struct Card: BoxShapeProps {
    static let kind: ShapeKind = "card"
    static let properties = Properties<Card> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Card {
    init() { self.init(.zero) }
}

struct CardDefinition {}

extension CardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Card>, in context: RenderContext) {}
}

/// Another titled box that can be mentioned, though not by a letter's `to`.
struct Sheet: BoxShapeProps {
    static let kind: ShapeKind = "sheet"
    static let properties = Properties<Sheet> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Sheet {
    init() { self.init(.zero) }
}

struct SheetDefinition {}

extension SheetDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Sheet>, in context: RenderContext) {}
}

/// A box with a tool that can't be mentioned: named by its tool's label, "Blob", where a mention
/// of one holds no name.
struct Blob: BoxShapeProps {
    static let kind: ShapeKind = "blob"
    static let properties = Properties<Blob> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Blob {
    init() { self.init(.zero) }
}

struct BlobDefinition {}

extension BlobDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Blob>, in context: RenderContext) {}
}

/// Text that may mention anything mentionable (`body`), and text that may mention only cards
/// (`to`).
struct Letter: BoxShapeProps {
    static let kind: ShapeKind = "letter"
    static let properties = Properties<Letter> {
        Property("frame", \.frame).required()
        Property("body", \.body)
        Property("to", \.to)
    }
    var frame: CGRect
    var body: MentionText = ""
    var to: ScopedMentionText<Only<Card>> = ""
    init(_ frame: CGRect = .zero, body: MentionText = "", to: ScopedMentionText<Only<Card>> = "") {
        self.frame = frame
        self.body = body
        self.to = to
    }
}

extension Letter {
    init() { self.init(.zero) }
}

struct LetterDefinition {}

extension LetterDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Letter>, in context: RenderContext) {}
}

/// Mention text a letter keeps as an added property, set only on the letters that have one.
enum Postscript {}

extension Postscript: ShapeProperty {
    static let key: PropertyKey = "postscript"
    static var defaultValue: MentionText? { nil }
}

/// Cards, sheets, blobs and letters; blobs have a place tool (no key).
struct ValidationFixturesPlugin: CanvasPlugin {
    var id: PluginID { "mention-validation-fixtures" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(CardDefinition()) { card in
            card.title()
            card.mentionable()
        }
        registrar.shape(SheetDefinition()) { sheet in
            sheet.title()
            sheet.mentionable()
        }
        registrar.shape(BlobDefinition()) { blob in
            blob.tool(label: "Blob", systemImage: "drop", placing: blob.placement(size: CGSize(width: 60, height: 60)) { Blob() })
        }
        registrar.declare(Postscript.self)
        registrar.shape(LetterDefinition()) { letter in
            letter.optIn(to: Postscript.self)
        }
    }
}

/// The keyboard and the selection first, CanvasTesting's fixtures (boxes; pockets, whose boards
/// nest; frozen shapes), this target's, the pieces Mentions builds on (the context menu, where it
/// puts Show What Mentions, among them), Mentions, Validation, then the bridge.
@MainActor func validationPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(), FreezingPlugin(), ValidationFixturesPlugin(),
     AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(), ValidationPlugin(),
     MentionValidationPlugin()] + more
}

@MainActor func validationHarness(document: CanvasDocument = CanvasDocument()) throws -> EditorHarness {
    try EditorHarness(plugins: validationPlugins(), document: document)
}

extension CanvasEditor {
    /// Inserts a shape titled `title`, in a transaction of its own.
    @discardableResult
    func add<P: ShapeProps>(_ props: P, titled title: String) -> ShapeID {
        var shape = ShapeRecord(props)
        shape[TitleProperty.self] = title
        transact { $0.insert(shape) }
        return shape.id
    }

    func rename(_ id: ShapeID, _ title: String) {
        transact { $0.update(id) { $0[TitleProperty.self] = title } }
    }

    /// Each issue of a shape, as "field: message", in the rules' order.
    func issues(of id: ShapeID) -> [String] {
        (validation?.results[id]?.issues ?? []).map { "\($0.field ?? "-"): \($0.message)" }
    }
}

/// Fixed ids, so a test's stored text is the same every run.
let idA = ShapeID(UUID(uuidString: "7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D")!)
let idB = ShapeID(UUID(uuidString: "0A1B2C3D-4E5F-4061-8293-A4B5C6D7E8F9")!)

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

/// A deterministic generator, so the fuzz is the same every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
