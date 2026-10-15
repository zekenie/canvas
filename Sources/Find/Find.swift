import Canvas
import CoreGraphics
import Keyboard

/// Find, as a plugin: ⌘F searches the board shown and every board under it for text that matches
/// what's typed, folded (case, diacritics, width) and forgiving a typo, as a browser's ⌘F searches
/// a page; highlights each hit where its shape draws it; and lists the shapes it's in, in the
/// detail panel's place (`FindPanelPlugin` gives `FindPanel` as the panel's takeover). ⌘G and ⇧⌘G
/// step through the hits, showing each one's board. It knows no kind and no concern: what a shape
/// shows as text, and where, comes from the plugins that draw it (`FindableTexts`: Mentions' text,
/// Titles' titles, Arrows' arrow labels). It never transacts.
extension PluginID {
    /// Never "find": that's the command's name (`CanvasCommand.find`).
    public static let findInBoards: PluginID = "find-in-boards"
}

// MARK: The extension point

/// A text a shape shows, as Find searches it: plain text, as it reads (a mention's name where its
/// pill is), and which of its contribution's texts it is (`field`, what `rects` is handed back).
public struct FindableText: Hashable, Sendable {
    public let field: String
    public let text: String

    public init(field: String, text: String) {
        self.field = field
        self.text = text
    }
}

/// What a contribution's closures may read besides the shape: the registry, the editor's services,
/// and the editor itself where a text's place is the editor's to say (an adornment's frame, a
/// title's cover).
@MainActor
public struct FindContext {
    public let editor: CanvasEditor
    public var registry: Registry { editor.registry }
    public func service<S: EditorService>(_: S.Type) -> S? { editor.service(S.self) }
}

/// A kind, as an every-shape contribution's `where` sees it: its definition and the registry (what
/// it opted into elsewhere: Mentions asks whether it draws mention text).
@MainActor
public struct FindableKind {
    public let kind: ShapeKind
    public let definition: any ShapeDefinition
    public let registry: Registry

    /// Whether this kind's shapes hold an added property (Titles: `TitleProperty`).
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool { registry.properties(for: kind).contains(P.key) }
}

/// The texts each kind's shapes show, for Find: from the plugin that draws them. Keyed by kind (or
/// every kind) and name: a plugin's "title" on a kind once. Several contributions on one kind add up
/// (a note's text, Mentions', and its title, Titles').
public enum FindableTexts {}

extension FindableTexts: KeyedExtensionPoint {
    public typealias Contribution = FindableTextsContribution
    public static var owner: PluginID { .findInBoards }

    public static func uniqueKeys(of contribution: FindableTextsContribution, for target: ShapeTarget) -> [AnyHashable] {
        [FindableKey(target: target, name: contribution.name)]
    }

    /// "findable title → every shape", "findable label → arrow".
    public static func summary(of contribution: FindableTextsContribution, for target: ShapeTarget) -> String {
        "findable \(contribution.name) → \(target == .any ? "every shape" : "\(target)")"
    }

    /// A name says what's found, so it can't be blank.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for contribution in registry.contributions(to: FindableTexts.self)
        where contribution.value.name.allSatisfy(\.isWhitespace) {
            throw .invalid(point: "FindableTexts", reason: "\(contribution.pluginID) contributes texts to \(contribution.target) with no name")
        }
    }
}

struct FindableKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    let name: String
    var description: String { "\(target) \(name)" }
}

/// What `FindableTexts` keeps. Only the sugar makes one.
@MainActor
public struct FindableTextsContribution {
    let name: String
    let appliesTo: @MainActor (FindableKind) -> Bool
    let texts: @MainActor (AnyShapeRecord, FindContext) -> [FindableText]
    let rects: @MainActor (AnyShapeRecord, String, [Range<Int>], FindContext) -> [[CGRect]]
    let zoomedOut: (@MainActor (AnyShapeRecord, String, FindContext) -> CGRect?)?
    let affected: (@MainActor (ChangeSet, FindContext) -> Set<ShapeID>)?
    let followsZoom: Bool
    let look: FindLook
}

/// How Find marks a hit where a contribution's text is drawn.
public enum FindLook: Hashable, Sendable {
    /// As a highlighter on paper: the text on the shape's own surface stays as dark as it was (a
    /// note's text, a card's).
    case marker
    /// A translucent wash, for text drawn over the canvas itself, whose color follows the
    /// appearance (an arrow's label).
    case wash
    /// A ring around it, for text on a dark badge a wash would hide (a title's pill).
    case ring
}

// MARK: Sugar

extension PluginRegistrar {
    /// Texts every shape of the kinds `where` picks shows, for Find: what a horizontal that draws
    /// text on shapes it doesn't define contributes (Mentions' text, Titles' titles). `where` is
    /// asked once per kind; keep it to the kinds that opted into what it draws.
    ///
    /// - `name`: what's found, in the registry's report ("title").
    /// - `look`: how a hit is marked (`FindLook`): a highlighter's by default.
    /// - `texts`: the shape's texts as it shows them, plain; cheap, read into Find's index as a
    ///   commit changes the shape (and for the shapes `affected` names).
    /// - `rects`: where each range (UTF-16, of the field's text) is drawn, one array of line rects
    ///   per range, in world units from the shape's bounds' top-left (`shapes.geometry(of:)`), as
    ///   the shape draws its text now. Asked only for shapes in view with hits, and again as the
    ///   shape changes (`followsZoom`: and as the zoom does, for a text sized in view points, a
    ///   pill's); keep what it lays out by text and width, so a range's rects are a lookup.
    /// - `zoomedOut`: where the text is said on a shape drawn as a skeleton (a title's cover), world
    ///   units, where the shape is; nil, or none given, for the shape's bounds.
    /// - `affected`: the shapes each commit changes the texts of without changing them (a note
    ///   showing another shape's live name); it must cost what the commit changed.
    public mutating func findableTexts(
        _ name: String,
        where appliesTo: @escaping @MainActor (FindableKind) -> Bool,
        look: FindLook = .marker,
        followsZoom: Bool = false,
        affected: (@MainActor (ChangeSet, FindContext) -> Set<ShapeID>)? = nil,
        zoomedOut: (@MainActor (AnyShapeRecord, String, FindContext) -> CGRect?)? = nil,
        texts: @escaping @MainActor (AnyShapeRecord, FindContext) -> [FindableText],
        rects: @escaping @MainActor (AnyShapeRecord, String, [Range<Int>], FindContext) -> [[CGRect]]
    ) {
        contribute(FindableTextsContribution(name: name, appliesTo: appliesTo, texts: texts, rects: rects, zoomedOut: zoomedOut,
                                             affected: affected, followsZoom: followsZoom, look: look),
                   to: FindableTexts.self, for: .any)
    }

    /// Texts the shapes of a kind another plugin registers show, for Find (Arrows' arrow
    /// labels), as above.
    public mutating func findableTexts<P: ShapeProps>(
        _ name: String,
        of _: P.Type,
        look: FindLook = .marker,
        followsZoom: Bool = false,
        affected: (@MainActor (ChangeSet, FindContext) -> Set<ShapeID>)? = nil,
        zoomedOut: (@MainActor (ShapeRecord<P>, String, FindContext) -> CGRect?)? = nil,
        texts: @escaping @MainActor (ShapeRecord<P>, FindContext) -> [FindableText],
        rects: @escaping @MainActor (ShapeRecord<P>, String, [Range<Int>], FindContext) -> [[CGRect]]
    ) {
        contribute(FindableTextsContribution(typed: P.self, name: name, look: look, followsZoom: followsZoom, affected: affected,
                                             zoomedOut: zoomedOut, texts: texts, rects: rects),
                   to: FindableTexts.self, for: .kind(P.kind))
    }
}

extension ShapeRegistrar {
    /// Texts this kind's shapes show, for Find, as `registrar.findableTexts(_:of:…)` says.
    public mutating func findableTexts(
        _ name: String,
        look: FindLook = .marker,
        followsZoom: Bool = false,
        affected: (@MainActor (ChangeSet, FindContext) -> Set<ShapeID>)? = nil,
        zoomedOut: (@MainActor (ShapeRecord<Definition.Props>, String, FindContext) -> CGRect?)? = nil,
        texts: @escaping @MainActor (ShapeRecord<Definition.Props>, FindContext) -> [FindableText],
        rects: @escaping @MainActor (ShapeRecord<Definition.Props>, String, [Range<Int>], FindContext) -> [[CGRect]]
    ) {
        contribute(FindableTextsContribution(typed: Definition.Props.self, name: name, look: look, followsZoom: followsZoom, affected: affected,
                                             zoomedOut: zoomedOut, texts: texts, rects: rects),
                   to: FindableTexts.self)
    }
}

extension FindableTextsContribution {
    init<P: ShapeProps>(typed _: P.Type, name: String, look: FindLook, followsZoom: Bool,
                        affected: (@MainActor (ChangeSet, FindContext) -> Set<ShapeID>)?,
                        zoomedOut: (@MainActor (ShapeRecord<P>, String, FindContext) -> CGRect?)?,
                        texts: @escaping @MainActor (ShapeRecord<P>, FindContext) -> [FindableText],
                        rects: @escaping @MainActor (ShapeRecord<P>, String, [Range<Int>], FindContext) -> [[CGRect]]) {
        let typedTexts: @MainActor (AnyShapeRecord, FindContext) -> [FindableText] = { record, context in
            guard let shape = record.typed(as: P.self) else { return [] }
            return texts(shape, context)
        }
        let typedRects: @MainActor (AnyShapeRecord, String, [Range<Int>], FindContext) -> [[CGRect]] = { record, field, ranges, context in
            guard let shape = record.typed(as: P.self) else { return ranges.map { _ in [] } }
            return rects(shape, field, ranges, context)
        }
        var typedZoomedOut: (@MainActor (AnyShapeRecord, String, FindContext) -> CGRect?)?
        if let zoomedOut {
            typedZoomedOut = { record, field, context in
                guard let shape = record.typed(as: P.self) else { return nil }
                return zoomedOut(shape, field, context)
            }
        }
        self.init(name: name, appliesTo: { _ in true }, texts: typedTexts, rects: typedRects, zoomedOut: typedZoomedOut,
                  affected: affected, followsZoom: followsZoom, look: look)
    }
}

// MARK: Board headings

/// What a board is called over its rows in Find's list: its title, and a symbol before it.
public struct FindHeading: Hashable {
    public var title: String
    public var systemImage: String?

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }
}

/// What heads each board's rows in Find's list, from the plugin that knows what a board is called
/// (Boards', its `BoardFindPlugin`: the path's names), so Find never learns what names a board. At
/// most one: two are `RegistryError.conflict` at startup. Without one the root's rows are headed
/// "Board" and another board's have no name.
public enum FindHeadings {}

extension FindHeadings: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (BoardID, CanvasEditor) -> FindHeading
    public static var owner: PluginID { .findInBoards }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["heading"] }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "find heading" }
}

extension PluginRegistrar {
    /// What a board is called over its rows in Find's list (`FindHeadings`). Read in the panel's
    /// body, for each board with rows in view:
    ///
    ///     registrar.findHeading { board, editor in FindHeading(editor.name(of: board), systemImage: editor.symbol(of: board)) }
    public mutating func findHeading(_ heading: @escaping @MainActor (BoardID, CanvasEditor) -> FindHeading) {
        contribute(heading, to: FindHeadings.self)
    }
}

// MARK: The plugin

/// ⌘F, ⌘G and ⇧⌘G (Edit › Find's items), the state they drive (`editor.find`), and the
/// highlights. Its panel (`FindPanel`) is in the detail panel's place while Find is open, from a
/// plugin of its own (`FindPanelPlugin`).
public struct FindPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .findInBoards }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { FindState(editor: $0) }
        registrar.overlay(FindOverlay())
        // Never mid-gesture. ⌘G and ⇧⌘G while there's something to step to: hits, or, with Find
        // closed, a query to open it on again.
        registrar.command(.find, shortcuts: [KeyChord("f", .command)], isEnabled: { $0.session == nil }) { $0.find?.open() }
        registrar.command(.findNext, shortcuts: [KeyChord("g", .command)], isEnabled: { $0.find?.canStep(in: $0) ?? false }) {
            $0.find?.step(forward: true)
        }
        registrar.command(.findPrevious, shortcuts: [KeyChord("g", [.command, .shift])], isEnabled: { $0.find?.canStep(in: $0) ?? false }) {
            $0.find?.step(forward: false)
        }
    }
}

extension CanvasEditor {
    /// Find's state; nil without FindPlugin.
    public var find: FindState? { service(FindState.self) }
}
