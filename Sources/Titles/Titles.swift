import Canvas
import TableOfContents

/// Titles, as a plugin: what a shape is called, a trait any kind can opt into. A kind's title is
/// kept by Titles, in the `title` property it adds to the kinds that opt in (`TitleProperty`), where
/// someone names the shape (a note, a task); or derived from what the kind keeps itself (an
/// ellipse's size). Any shape of a titled kind may have none. A titled shape shows its title in a
/// pill just outside its top-left corner, and its row in the table of contents is called by it;
/// `TitleHeader` renames it in the detail panel. The core never learns what a title is.
extension PluginID {
    public static let titles: PluginID = "titles"
}

/// What a shape is called, where Titles keeps it: the property it adds to each kind that opts in
/// with `x.title()`, and so a property of that kind's schema. A string of 1 to 80 characters (the
/// schema's `minLength` and `maxLength`, in code points); nil until the shape is named, and again
/// once its name is cleared. Nothing refuses a title outside the bounds: Validation checks every
/// shape against its kind's schema, and warns about it.
public enum TitleProperty {}

extension TitleProperty: ShapeProperty {
    public static let key: PropertyKey = "title"
    public static var defaultValue: String? { nil }
    public static var keywords: PropertyKeywords<String> {
        PropertyKeywords().description("What the shape is called.").minLength(1).maxLength(maxLength)
    }
    /// The longest title that draws no warning, in characters (code points, as JSON Schema counts).
    public static let maxLength = 80
}

/// The extension point: which kinds have titles, what a shape's is, and whether the canvas shows it.
/// At most one per kind: two plugins titling the same kind is `RegistryError.conflict` at startup.
public enum ShapeTitles {}

extension ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = TitleContribution
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What `ShapeTitles` stores for a kind: its shapes' titles, as they read (`oneLine`), and whether
/// the canvas shows them in a pill. Only the sugar below makes one.
@MainActor
public struct TitleContribution {
    let title: @MainActor (AnyShapeRecord) -> String?
    let showsPill: Bool

    init<P: ShapeProps>(_: P.Type, showsPill: Bool, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        title = { oneLine($0.typed(as: P.self).flatMap(make)) }
        self.showsPill = showsPill
    }
}

/// A title as everything that shows it reads it (the lookup, the pill, the row): on one line, each
/// run of whitespace, newlines included, folded into a space; nil when that leaves nothing, so a
/// blank title is no title.
func oneLine(_ title: String?) -> String? {
    guard let folded = title?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !folded.isEmpty else { return nil }
    return folded
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar {
    /// Gives this kind a title that Titles keeps: its shapes hold one (`TitleProperty`, nil until
    /// they're named), and its schema gains it, bounds and all, so a title too long draws a warning.
    /// A titled shape shows it in a pill above its top-left corner, unless `pill` is false (for a
    /// kind that draws its own), and it names the shape's row in the table of contents, unless
    /// `contents` is false (for a kind whose row says more). To rename it in the detail panel, put
    /// a `TitleHeader` in the kind's header: `note.details(header: { $note in TitleHeader($note) }) {}`.
    public mutating func title(pill: Bool = true, contents: Bool = true) {
        optIn(to: TitleProperty.self)
        title(pill: pill, contents: contents) { $0[TitleProperty.self] }
    }

    /// Gives this kind a title derived from what it keeps itself: what `make` says a shape is
    /// called, if anything (nil or blank is none), as `label.title { $0.props.text }`. It follows
    /// what it's made from, and isn't in the kind's schema; one that someone names is `title()`.
    /// The pill and the row are as there.
    public mutating func title(pill: Bool = true, contents: Bool = true,
                               _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute(TitleContribution(Definition.Props.self, showsPill: pill, make), to: ShapeTitles.self)
        if contents { contentsTitle { oneLine(make($0)) } }
    }
}

extension PluginRegistrar {
    /// A title Titles keeps, for a kind another plugin registers (bridges), as `title()` on a kind's
    /// own registrar.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true) {
        optIn(P.self, to: TitleProperty.self)
        title(P.self, pill: pill, contents: contents) { $0[TitleProperty.self] }
    }

    /// A derived title for a kind another plugin registers (bridges), as `title { ... }` on a kind's
    /// own registrar.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true,
                                              _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute(TitleContribution(P.self, showsPill: pill, make), to: ShapeTitles.self, for: .kind(P.kind))
        if contents { contentsTitle(P.self) { oneLine(make($0)) } }
    }
}

extension Registry {
    /// What a shape is called, on one line; nil if its kind has no title, or its title is blank.
    public func title(of shape: AnyShapeRecord) -> String? {
        contributions(to: ShapeTitles.self, for: shape.kind).first?.title(shape)
    }
}

/// Per editor: the kinds whose titles show in a pill, found once (the registry is frozen), so the
/// overlay doesn't ask the registry for every kind on every frame.
@MainActor
final class TitleState {
    let pills: [ShapeKind: TitleContribution]

    init(editor: CanvasEditor) {
        let registry = editor.registry
        var pills: [ShapeKind: TitleContribution] = [:]
        for kind in registry.kinds {
            if let title = registry.contributions(to: ShapeTitles.self, for: kind).first, title.showsPill { pills[kind] = title }
        }
        self.pills = pills
    }
}

extension TitleState: EditorService {}

/// A horizontal any kind can opt into: a title, kept in the property this plugin adds to the kind or
/// derived from the kind's own, in a pill on the canvas and naming the shape's row in the table of
/// contents. This plugin shows it, and `TitleHeader` renames it.
public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TitleProperty.self)
        registrar.service { TitleState(editor: $0) }
        registrar.overlay(TitleOverlay())
    }
}
