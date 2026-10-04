import Adornments
import AppKit
import Canvas
import SlashCommands
import TableOfContents

/// Titles, as a plugin: what a shape is called, a trait any kind can opt into. A kind's title is
/// kept by Titles, in the `title` property it adds to the kinds that opt in (`TitleProperty`), where
/// someone names the shape (a note, a subboard); or derived from what the kind keeps itself (a
/// schema card's, its schema's `"title"`). Any shape of a titled kind may have none. A titled shape shows its title in a
/// pill just outside its top-left corner (`TitlePill`, an adornment), an untitled one there its
/// kind's placeholder, dimmed, where the kind gives one to grab, and its row in the table of
/// contents is called by its title; `TitleHeader` renames it in the detail panel, and `/title` from
/// a line of its text. Zoomed out, where shapes are skeletons and adornments aren't shown, a titled
/// shape says its title on itself, large (`TitleCoverStyle`). The core never learns what a title is.
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
        guard let title else { return nil }
        if isFoldedASCII(title) { return title }
        let folded = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : folded
    }

    /// Whether a title is ASCII and reads as it's written already, as most do: not empty, and no
    /// whitespace but single spaces between words. Read a byte at a time, since splitting and
    /// joining would cost every title read (a query reads every one in the file) a few allocations.
    /// ASCII's whitespace is a space and tab to carriage return, as `isWhitespace` reads it.
    private static func isFoldedASCII(_ title: String) -> Bool {
        title.utf8.withContiguousStorageIfAvailable { bytes in
            guard let first = bytes.first, let last = bytes.last, first != 0x20, last != 0x20 else { return false }
            var previous: UInt8 = 0
            for byte in bytes {
                if byte >= 0x80 || (0x09...0x0D).contains(byte) || (byte == 0x20 && previous == 0x20) { return false }
                previous = byte
            }
            return true
        } ?? false
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
/// whether they're derived from what the kind keeps, whether its shapes show `TitlePill`, whether
/// the pill starts with the kind's symbol, and what it says, dimmed, on a shape without a title.
/// Only the sugar below makes one.
@MainActor
public struct TitleContribution {
    let title: @MainActor (AnyShapeRecord) -> String?
    let showsPill: Bool
    let symbolInPill: Bool
    /// What the pill says on an untitled shape (`placeholderInPill`), dimmed; nil for no pill there.
    let pillPlaceholder: String?
    /// Made by what `make` says (`title { … }`), not only read from `TitleProperty` (`title()`).
    let isDerived: Bool
    /// What the kind's skeleton is mostly drawn on, which a cover's ink is chosen to read on; nil
    /// for the default skeleton's gray.
    let coverSurface: NSColor?

    init<P: ShapeProps>(_: P.Type, showsPill: Bool, symbolInPill: Bool, pillPlaceholder: String?, isDerived: Bool, coverSurface: NSColor?,
                        _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        title = { TitleProperty.folded($0.typed(as: P.self).flatMap(make)) }
        self.showsPill = showsPill
        self.symbolInPill = symbolInPill
        self.pillPlaceholder = TitleProperty.folded(pillPlaceholder)
        self.isDerived = isDerived
        self.coverSurface = coverSurface
    }
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar {
    /// Gives this kind a title that Titles keeps: its shapes hold one (`TitleProperty`, nil until
    /// they're named), and its schema gains it, bounds and all, so a title too long draws a warning.
    /// A titled shape shows it in a pill above its top-left corner, unless `pill` is false (for a
    /// kind that draws its own), after the kind's symbol (`registry.label(of:)`) if `symbolInPill`
    /// (for a kind whose look doesn't say what it is: a schema card's `{}`), and it names the
    /// shape's row in the table of contents, unless `contents` is false (for a kind whose row says
    /// more). An untitled shape shows no pill, unless the kind gives one to grab:
    /// `placeholderInPill`, what the pill says there, dimmed ("Frame"), laid out as a title is. Zoomed
    /// out, where a skeleton has no pill, the title is said on the shape, in an ink that reads on
    /// what the kind's skeleton is drawn on: `coverSurface`, a note's yellow (a dynamic color follows
    /// the appearance); the default skeleton's gray without one. To rename it in the detail panel,
    /// put a `TitleHeader` in the kind's header: `note.details(header: { $note in TitleHeader($note) }) {}`.
    public mutating func title(pill: Bool = true, symbolInPill: Bool = false, placeholderInPill: String? = nil, contents: Bool = true,
                               coverSurface: NSColor? = nil) {
        optIn(to: TitleProperty.self)
        title(pill: pill, symbolInPill: symbolInPill, placeholderInPill: placeholderInPill, contents: contents, isDerived: false,
              coverSurface: coverSurface) {
            $0[TitleProperty.self]
        }
    }

    /// Gives this kind a title derived from what it keeps itself: what `make` says a shape is
    /// called, if anything (nil or blank is none), as `label.title { $0.props.text }`. It follows
    /// what it's made from, and isn't in the kind's schema; one that someone names is `title()`.
    /// The pill and the row are as there.
    public mutating func title(pill: Bool = true, symbolInPill: Bool = false, placeholderInPill: String? = nil, contents: Bool = true,
                               coverSurface: NSColor? = nil, _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        title(pill: pill, symbolInPill: symbolInPill, placeholderInPill: placeholderInPill, contents: contents, isDerived: true,
              coverSurface: coverSurface, make)
    }

    private mutating func title(pill: Bool, symbolInPill: Bool, placeholderInPill: String?, contents: Bool, isDerived: Bool,
                                coverSurface: NSColor?, _ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute(TitleContribution(Definition.Props.self, showsPill: pill, symbolInPill: symbolInPill, pillPlaceholder: placeholderInPill,
                                     isDerived: isDerived, coverSurface: coverSurface, make),
                   to: ShapeTitles.self)
        if contents { contentsTitle { TitleProperty.folded(make($0)) } }
    }
}

extension PluginRegistrar {
    /// A title Titles keeps, for a kind another plugin registers, as `title()` on a kind's
    /// own registrar.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, symbolInPill: Bool = false, placeholderInPill: String? = nil,
                                              contents: Bool = true, coverSurface: NSColor? = nil) {
        optIn(P.self, to: TitleProperty.self)
        title(P.self, pill: pill, symbolInPill: symbolInPill, placeholderInPill: placeholderInPill, contents: contents, isDerived: false,
              coverSurface: coverSurface) {
            $0[TitleProperty.self]
        }
    }

    /// A derived title for a kind another plugin registers, as `title { ... }` on a kind's
    /// own registrar. A plugin that also opts the kind into `TitleProperty` (`optIn(_:to:)`) can
    /// derive a title for the shapes nobody named: `TitleProperty.folded(shape[TitleProperty.self])
    /// ?? what it derives`.
    public mutating func title<P: ShapeProps>(_: P.Type, pill: Bool = true, symbolInPill: Bool = false, placeholderInPill: String? = nil,
                                              contents: Bool = true, coverSurface: NSColor? = nil,
                                              _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        title(P.self, pill: pill, symbolInPill: symbolInPill, placeholderInPill: placeholderInPill, contents: contents, isDerived: true,
              coverSurface: coverSurface, make)
    }

    private mutating func title<P: ShapeProps>(_: P.Type, pill: Bool, symbolInPill: Bool, placeholderInPill: String?, contents: Bool,
                                               isDerived: Bool, coverSurface: NSColor?, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute(TitleContribution(P.self, showsPill: pill, symbolInPill: symbolInPill, pillPlaceholder: placeholderInPill,
                                     isDerived: isDerived, coverSurface: coverSurface, make),
                   to: ShapeTitles.self, for: .kind(P.kind))
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
/// shape whose kind shows one (`pill: true`, the default), after the kind's symbol where the kind
/// asks (`symbolInPill`), and on an untitled one where the kind gives a placeholder
/// (`placeholderInPill`), the placeholder, dimmed (`AdornmentLabel(placeholder:)`), so the shape has
/// something to grab. Titles places it, though it defines no shape; Adornments lays it out: as
/// long as the title, no longer than the row leaves it (the shape's width, less whatever is at the
/// row's right end, a lock, and 4 points), ending in "…". Zoomed out, a shape drawn as a skeleton
/// shows no pill (no adornment is): its title is said on the shape itself, large (`TitleCoverStyle`,
/// its cover); the shape being edited, drawn in full, keeps its pill.
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

    /// What a shape's title pill says: its title, after its kind's symbol (`label(of:)`) where the
    /// kind asks for it (`symbolInPill`); on an untitled shape, the kind's placeholder, dimmed, where
    /// it gives one (`placeholderInPill`); else nothing.
    func titlePill(of shape: AnyShapeRecord) -> AdornmentLabel? {
        guard let titles = contributions(to: ShapeTitles.self, for: shape.kind).first, titles.showsPill else { return nil }
        let symbol = titles.symbolInPill ? label(of: shape.kind).systemImage : nil
        if let title = titles.title(shape) { return AdornmentLabel(title, systemImage: symbol) }
        return titles.pillPlaceholder.map { AdornmentLabel(placeholder: $0, systemImage: symbol) }
    }

    /// What a shape's cover says (`TitleCoverStyle`) and what its kind's skeleton is drawn on: its
    /// title, for a kind that shows one in a pill; nil for an untitled shape (a placeholder is its
    /// pill's alone), and a kind with no pill.
    func titleCover(of shape: AnyShapeRecord) -> (title: String, surface: NSColor?)? {
        guard let titles = contributions(to: ShapeTitles.self, for: shape.kind).first, titles.showsPill,
              let title = titles.title(shape) else { return nil }
        return (title, titles.coverSurface)
    }
}

/// A horizontal any kind can opt into: a title, kept in the property this plugin adds to the kind or
/// derived from the kind's own, in a pill on the canvas and naming the shape's row in the table of
/// contents. This plugin places the pill and offers `/title`, and `TitleHeader` renames it.
public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TitleProperty.self)
        // The pill, on every shape whose kind's title shows one: Titles places it, and defines no kind.
        registrar.adornmentForEveryShape(TitlePill.self, where: { $0.registry.showsTitlePill($0.kind) }) { shape, context in
            context.registry.titlePill(of: shape)
        }
        // `/title Groceries` typed on a line of a shape's text: names the shape, on the kinds that can
        // be named. A derived title (a schema card's) isn't Titles' to set, and is renamed where it's
        // derived from; a pill in the line is its name, "@Label", as the argument's text reads it.
        registrar.slashCommandsForEveryShape(where: { $0.holds(TitleProperty.self) }) {
            SlashCommand("title", argument: "title") { shape, arguments in shape[TitleProperty.self] = arguments.text }
        }
        // Zoomed out, where a skeleton has no pill, the title is said on the shape.
        registrar.overlay(TitleCoverOverlay())
    }
}
