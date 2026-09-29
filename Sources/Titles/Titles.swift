import Adornments
import Canvas
import TableOfContents

/// Titles, as a plugin: what a shape is called, a trait any kind can opt into. A kind's title is
/// kept by Titles, in the `title` property it adds to the kinds that opt in (`TitleProperty`), where
/// someone names the shape (a note, a subboard); or derived from what the kind keeps itself (a
/// schema card's, its schema's `"title"`). Any shape of a titled kind may have none. A titled shape shows its title in a
/// pill just outside its top-left corner (`TitlePill`, an adornment), and its row in the table of
/// contents is called by it; `TitleHeader` renames it in the detail panel. The core never learns
/// what a title is.
extension PluginID {
    public static let titles: PluginID = "titles"
}

/// What a shape is called, where Titles keeps it: the property it adds to each kind that opts in
/// with `x.title()`, and so a property of that kind's schema. A string of 1 to 80 characters (the
/// schema's `minLength` and `maxLength`, in code points); nil until the shape is named, and again
/// once its name is cleared. A blank title is none: a shape given one (empty, or only spaces and
/// line breaks) holds nil, as does one read from a board, so no shape holds one. Nothing refuses a
/// title too long: Validation checks every shape against its kind's schema, and warns about it.
public enum TitleProperty {}

extension TitleProperty: ShapeProperty {
    public static let key: PropertyKey = "title"
    public static var defaultValue: String? { nil }
    public static var keywords: PropertyKeywords<String> {
        PropertyKeywords().description("What the shape is called.").minLength(1).maxLength(maxLength)
    }
    public static func isNone(_ title: String) -> Bool { title.allSatisfy(\.isWhitespace) }
    /// The longest title that draws no warning, in characters (code points, as JSON Schema counts).
    public static let maxLength = 80

    /// A title as everything that shows it reads it (the lookup, the pill, the row): on one line,
    /// each run of whitespace, newlines included, folded into a space; nil when that leaves
    /// nothing, so a blank title is no title. For what matches titles as they read (the command
    /// line names shapes by theirs), and a derived title that falls back when a name is blank.
    public static func folded(_ title: String?) -> String? {
        guard let folded = title?.split(whereSeparator: \.isWhitespace).joined(separator: " "), !folded.isEmpty else { return nil }
        return folded
    }
}

/// The extension point: which kinds have titles, what a shape's is, and whether the canvas shows it.
/// At most one per kind: two plugins titling the same kind is `RegistryError.conflict` at startup.
public enum ShapeTitles {}

extension ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = TitleContribution
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

/// What `ShapeTitles` stores for a kind: its shapes' titles, as they read (`TitleProperty.folded`),
/// whether they're derived from what the kind keeps, and whether its shapes show `TitlePill`. Only
/// the sugar below makes one.
@MainActor
public struct TitleContribution {
    let title: @MainActor (AnyShapeRecord) -> String?
    let showsPill: Bool
    /// Made by what `make` says (`title { … }`), not only read from `TitleProperty` (`title()`).
    let isDerived: Bool

    init<P: ShapeProps>(_: P.Type, showsPill: Bool, isDerived: Bool, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        title = { TitleProperty.folded($0.typed(as: P.self).flatMap(make)) }
        self.showsPill = showsPill
        self.isDerived = isDerived
    }
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
        title(pill: pill, contents: contents, isDerived: false) { $0[TitleProperty.self] }
    }

    /// Gives this kind a title derived from what it keeps itself: what `make` says a shape is
    /// called, if anything (nil or blank is none), as `label.title { $0.props.text }`. It follows
    /// what it's made from, and isn't in the kind's schema; one that someone names is `title()`.
    /// The pill and the row are as there.
    public mutating func title(pill: Bool = true, contents: Bool = true,
                               _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        title(pill: pill, contents: contents, isDerived: true, make)
    }

    private mutating func title(pill: Bool, contents: Bool, isDerived: Bool,
                                _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute(TitleContribution(Definition.Props.self, showsPill: pill, isDerived: isDerived, make), to: ShapeTitles.self)
        if contents { contentsTitle { TitleProperty.folded(make($0)) } }
    }
}

extension PluginRegistrar {
    /// A title Titles keeps, for a kind another plugin registers (bridges), as `title()` on a kind's
    /// own registrar.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true) {
        optIn(P.self, to: TitleProperty.self)
        title(P.self, pill: pill, contents: contents, isDerived: false) { $0[TitleProperty.self] }
    }

    /// A derived title for a kind another plugin registers (bridges), as `title { ... }` on a kind's
    /// own registrar. A bridge that also opts the kind into `TitleProperty` (`optIn(_:to:)`) can
    /// derive a title for the shapes nobody named: `TitleProperty.folded(shape[TitleProperty.self])
    /// ?? what it derives`.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, contents: Bool = true,
                                              _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        title(P.self, pill: pill, contents: contents, isDerived: true, make)
    }

    private mutating func title<P: ShapeProps>(_: P.Type, pill: Bool, contents: Bool, isDerived: Bool,
                                               _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute(TitleContribution(P.self, showsPill: pill, isDerived: isDerived, make), to: ShapeTitles.self, for: .kind(P.kind))
        if contents { contentsTitle(P.self) { TitleProperty.folded(make($0)) } }
    }
}

extension Registry {
    /// What a shape is called, on one line; nil if its kind has no title, or its title is blank.
    public func title(of shape: AnyShapeRecord) -> String? {
        contributions(to: ShapeTitles.self, for: shape.kind).first?.title(shape)
    }

    /// Whether a kind's titles are derived from what the kind keeps (`title { … }`: a schema card's,
    /// from its schema), rather than only named by someone (`title()`); false for a kind without
    /// titles. A kind whose shapes can be named opts into `TitleProperty` (`properties(for:)` has its
    /// key), and may be both: named, and derived for the shapes nobody named.
    public func titleIsDerived(_ kind: ShapeKind) -> Bool {
        contributions(to: ShapeTitles.self, for: kind).first?.isDerived ?? false
    }
}

/// A title's pill: the shape's title at the left end of the row just above it, on every titled
/// shape whose kind shows one (`pill: true`, the default). Titles places it, though it defines no
/// shape; Adornments lays it out: as long as the title, no longer than the row leaves it (the
/// shape's width, less whatever is at the row's right end, a lock, and 4 points), ending in "…".
/// Zoomed out, on a shape drawn as a skeleton, it's a blank capsule, as long as the title's
/// columns (a CJK character or an emoji two); on the shape being edited, drawn in full, its title.
public enum TitlePill {}

extension TitlePill: Adornment {
    public static var placement: AdornmentPlacement { .aboveTopLeft }
    public static var order: Int { 50 }
}

extension Registry {
    /// Whether a kind's shapes show their title in a pill: it's titled, and not with `pill: false`.
    func showsTitlePill(_ kind: ShapeKind) -> Bool {
        contributions(to: ShapeTitles.self, for: kind).first?.showsPill == true
    }
}

/// A horizontal any kind can opt into: a title, kept in the property this plugin adds to the kind or
/// derived from the kind's own, in a pill on the canvas and naming the shape's row in the table of
/// contents. This plugin places the pill, and `TitleHeader` renames it.
public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TitleProperty.self)
        // The pill, on every shape whose kind's title shows one: Titles places it, and defines no kind.
        registrar.adornmentForEveryShape(TitlePill.self, where: { $0.registry.showsTitlePill($0.kind) }) { shape, context in
            context.registry.title(of: shape).map { AdornmentLabel($0) }
        }
    }
}
