import Adornments
import AppKit
import Canvas
import SlashCommands
import TableOfContents

/// Titles, as a plugin: what a shape is called, a trait any kind can opt into. A kind's title is
/// kept by Titles, in the `title` property it adds to the kinds that opt in (`TitleProperty`), where
/// someone names the shape (a note, a subboard); or derived from what the kind keeps itself (`title { … }`). Any shape of a titled kind may have none. A titled shape shows its title in a
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

/// What a kind's shapes' covers are drawn over, shape by shape (`titleCoverSurface`): for a kind
/// whose surface is each shape's own (a note's paper is its color's). At most one per kind.
public enum TitleCoverSurfaces {}

extension TitleCoverSurfaces: KeyedExtensionPoint {
    public typealias Contribution = TitleCoverSurface
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleCoverSurface, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: TitleCoverSurface, for target: ShapeTarget) -> String { "title cover surface → \(target)" }
}

/// One kind's: only the sugar makes one.
@MainActor
public struct TitleCoverSurface {
    let surface: @MainActor (AnyShapeRecord, TitleLookContext) -> NSColor?
}

extension ShapeRegistrar {
    /// What a shape of this kind's cover is drawn over, where that is the shape's own and not the
    /// kind's (`title(coverSurface:)`): a note's paper, which is its color's. Asked for every titled
    /// skeleton of the kind in view, each frame, with the editor's services, so answer from what a
    /// service keeps, at the cost of a lookup; nil is the kind's. A look's own `coverSurface`
    /// (`titlePillLook`) still wins: a type's note is white whatever its color.
    public mutating func titleCoverSurface(_ surface: @escaping @MainActor (ShapeRecord<Definition.Props>, TitleLookContext) -> NSColor?) {
        contribute(TitleCoverSurface { record, context in record.typed(as: Definition.Props.self).flatMap { surface($0, context) } },
                   to: TitleCoverSurfaces.self)
    }
}

/// The kinds whose title is a tab on the shape's top edge (`titleTab`), in place of a pill above it and a
/// cover zoomed out, and what each shape's tab looks like. At most one per kind.
public enum TitleTabs {}

extension TitleTabs: KeyedExtensionPoint {
    public typealias Contribution = TitleTabContribution
    public static var owner: PluginID { .titles }
    public static func uniqueKeys(of _: TitleTabContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: TitleTabContribution, for target: ShapeTarget) -> String { "title tab → \(target)" }
}

/// A shape's tab's colors: the surface it's filled with and the line inside its edge, the shape's own
/// (a frame's surface and border), so the tab reads as part of the shape. Its text is dark on a light
/// surface and light on a dark one, as a cover's is. Dynamic colors follow the appearance.
public struct TitleTabLook {
    public var surface: NSColor
    public var edge: NSColor

    public init(surface: NSColor, edge: NSColor) {
        self.surface = surface
        self.edge = edge
    }
}

/// One kind's: only the sugar makes one.
@MainActor
public struct TitleTabContribution {
    let look: @MainActor (AnyShapeRecord, TitleLookContext) -> TitleTabLook?
}

extension ShapeRegistrar {
    /// This kind's title is a tab on the shape's top edge (Adornments' `onTopEdge`), in the colors `look`
    /// gives each shape (nil: the pill's gray), where a pill would be above it: what names a shape that holds
    /// others, a frame. The tab is the same size on screen at every zoom, shown zoomed out too, where it takes
    /// the place of the cover; tabs give way to each other, the outermost shape's first. An untitled shape's
    /// placeholder (`placeholderInPill`) is its tab's, but zoomed out it shows none. Asked where the tab's
    /// label is made, when a commit names the shape, with the editor's services. The kind opts into a title
    /// too (`title()`); a look's tint (`titlePillLook`) wins over these colors.
    ///
    ///     frame.titleTab { shape, context in TitleTabLook(surface: …, edge: …) }
    public mutating func titleTab(_ look: @escaping @MainActor (ShapeRecord<Definition.Props>, TitleLookContext) -> TitleTabLook?) {
        contribute(TitleTabContribution { record, context in record.typed(as: Definition.Props.self).flatMap { look($0, context) } },
                   to: TitleTabs.self)
    }
}

extension PluginRegistrar {
    /// A title tab for a kind another plugin registers, as `titleTab` on a kind's own registrar.
    public mutating func titleTab<P: ShapeProps>(_: P.Type, _ look: @escaping @MainActor (ShapeRecord<P>, TitleLookContext) -> TitleTabLook?) {
        contribute(TitleTabContribution { record, context in record.typed(as: P.self).flatMap { look($0, context) } },
                   to: TitleTabs.self, for: .kind(P.kind))
    }
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

/// How one shape's pill looks, where its kind's own look (`title(symbolInPill:placeholderInPill:)`)
/// is not the whole of it: a plugin gives the pill of the shapes that hold its property a look, so a
/// concern changes how a kind's pill reads without knowing the kind. Each field is nil (or false)
/// for "as the kind has it".
public struct TitlePillLook {
    /// An SF Symbol first in the pill, in place of the kind's.
    public var symbol: String?
    /// The pill's color (Adornments').
    public var tint: AdornmentTint?
    /// What an untitled shape's pill says, dimmed; the pill then shows where the kind gave none.
    public var placeholder: String?
    /// What the shape's skeleton is drawn on, for its cover's ink, in place of the kind's.
    public var coverSurface: NSColor?
    /// No pill at all.
    public var hidesPill: Bool

    public init(symbol: String? = nil, tint: AdornmentTint? = nil, placeholder: String? = nil, coverSurface: NSColor? = nil, hidesPill: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.placeholder = placeholder
        self.coverSurface = coverSurface
        self.hidesPill = hidesPill
    }
}

/// The extension point for pill looks: any number of plugins contribute, and the fields merge (the
/// first non-nil of each, in plugin order, a kind's own before the concerns'; `hidesPill` if any
/// says so). Not keyed.
public enum TitlePillLooks {}

extension TitlePillLooks: ExtensionPoint {
    public typealias Contribution = TitlePillLookContribution
    public static var owner: PluginID { .titles }
    /// A concern's look on other kinds' pills says which: the kinds that hold its property.
    public static var scope: PointScope { .scoped }

    /// "title pill look → every shape holding schema", "title pill look → note".
    public static func summary(of contribution: TitlePillLookContribution, for target: ShapeTarget) -> String {
        "title pill look → \(target)"
    }
}

/// What a pill look may read besides the shape and its title: the editor's services, where an editor is
/// asking (the pill's label, Find's texts). None for a cover, which is asked for every titled skeleton in
/// view each frame, so a look that needs a service answers nil there and a cover wants only its
/// `coverSurface`.
@MainActor
public struct TitleLookContext {
    private enum Source {
        case adornment(AdornmentContext), editor(CanvasEditor), none
    }

    private let source: Source

    /// The service where an editor is asking; nil for a cover, and for a service the editor has none of.
    public func service<S: EditorService>(_ type: S.Type) -> S? {
        switch source {
        case .adornment(let context): context.service(type)
        case .editor(let editor): editor.service(type)
        case .none: nil
        }
    }

    /// The pill: its label is made with an adornment's context.
    init(_ context: AdornmentContext) { source = .adornment(context) }
    /// Find: the editor it indexes.
    init(_ editor: CanvasEditor) { source = .editor(editor) }
    private init() { source = .none }
    /// A cover's.
    static var none: TitleLookContext { TitleLookContext() }
}

/// What `TitlePillLooks` stores: what a kind's own look, or a concern's on the kinds its scope reaches,
/// says of a shape, its title and the context it is asked in.
@MainActor
public struct TitlePillLookContribution {
    let look: @MainActor (AnyShapeRecord, String?, TitleLookContext) -> TitlePillLook?
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar {
    /// Gives this kind a title that Titles keeps: its shapes hold one (`TitleProperty`, nil until
    /// they're named), and its schema gains it, bounds and all, so a title too long draws a warning.
    /// A titled shape shows it in a pill above its top-left corner, unless `pill` is false (for a
    /// kind that draws its own), after the kind's symbol (`registry.label(of:)`) if `symbolInPill`
    /// (for a kind whose look doesn't say what it is: a subboard's `rectangle.stack`), and it names the
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

extension ShapeRegistrar {
    /// This kind's own pill look, asked of each of its shapes with its title (nil when untitled): see
    /// `TitlePillLook`. Asked where the pill's label is made, when a commit names the shape, where Find
    /// reads its title, and for the cover of a titled skeleton in view, never per frame otherwise.
    public mutating func titlePillLook(_ look: @escaping @MainActor (ShapeRecord<Definition.Props>, _ title: String?) -> TitlePillLook?) {
        contribute(TitlePillLookContribution { record, title, _ in record.typed(as: Definition.Props.self).flatMap { look($0, title) } },
                   to: TitlePillLooks.self)
    }
}

extension ScopedRegistrar {
    /// A concern's pill look, asked of the shapes of every kind the scope reaches and of no other kind:
    /// Types gives the notes that hold a schema the look of a type's pill.
    ///
    ///     registrar.forShapes(holding: TypeSchemaProperty.self) { types in types.titlePillLook { record, title in … } }
    public mutating func titlePillLook(_ look: @escaping @MainActor (AnyShapeRecord, _ title: String?) -> TitlePillLook?) {
        contribute(TitlePillLookContribution { record, title, _ in look(record, title) }, to: TitlePillLooks.self)
    }

    /// As `titlePillLook(_:)`, for a look that reads a service of the editor (`TitleLookContext`). Asked
    /// where the pill's label is made and where Find reads the title, with the editor's services; for a
    /// cover with none, where it answers from the shape alone.
    public mutating func titlePillLook(_ look: @escaping @MainActor (AnyShapeRecord, _ title: String?, TitleLookContext) -> TitlePillLook?) {
        contribute(TitlePillLookContribution(look: look), to: TitlePillLooks.self)
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

    /// Whether a kind's titles are derived from what the kind keeps (`title { … }`), rather than only named by someone (`title()`); false for a kind without
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
}

/// A title's tab: the pill's words on the shape's top edge, for a kind whose title is one (`titleTab`), in
/// the colors it gives, at every zoom (Adornments' `onTopEdge`: zoomed out too, where the shape has no cover,
/// and the same size on screen, giving way to other shapes' tabs, the outermost's first).
public enum TitleTab {}

extension TitleTab: Adornment {
    public static var placement: AdornmentPlacement { .onTopEdge }
}

extension CanvasEditor {
    /// The rect of a shape's title pill, or its tab, in world units, at the zoom now, where the shape is (not
    /// where a shake draws it): what something that hangs from the pill (a card to name the shape) goes by,
    /// and what Find rings. Nil where the shape shows none: a plain untitled one, a look that hides the
    /// pill, a shape drawn as a skeleton with no tab (zoomed out, its title is its cover, `titleCover(of:)`),
    /// a pill left out for want of room, one not on the board.
    public func titlePillRect(of id: ShapeID) -> CGRect? {
        adornmentFrames(of: id).first { $0.adornment == .of(TitlePill.self) || $0.adornment == .of(TitleTab.self) }?.rect
    }
}

private struct TitleKey: Hashable { let kind: ShapeKind }
private struct PillLooksKey: Hashable { let kind: ShapeKind }
private struct TabKey: Hashable { let kind: ShapeKind }

extension ShapeCapability {
    /// The kinds that took a title (`x.title()`, or one derived, `x.title { … }`): where what says a
    /// title goes (Find's texts, the check of a title two shapes share).
    public static let titled = ShapeCapability("with a title") { $0.registry.isTitled($0.kind) }

    /// The kinds whose title shows in a pill above the shape: titled, and not with `pill: false` or a tab.
    public static let titlePill = ShapeCapability("with a title pill") { $0.registry.showsTitlePill($0.kind) }

    /// The kinds whose title shows in a tab on the shape's top edge (`titleTab`): titled, and not with
    /// `pill: false`.
    public static let titleTab = ShapeCapability("with a title tab") { $0.registry.showsTitleTab($0.kind) }
}

extension Registry {
    /// Whether a kind's shapes show their title in a pill: it's titled, not with `pill: false`, and not
    /// with a tab in its place.
    func showsTitlePill(_ kind: ShapeKind) -> Bool {
        titleContribution(for: kind)?.showsPill == true && tabContribution(for: kind) == nil
    }

    /// Whether a kind's shapes show their title in a tab on their top edge: it's titled, not with `pill:
    /// false`, and gives a tab (`titleTab`).
    func showsTitleTab(_ kind: ShapeKind) -> Bool {
        titleContribution(for: kind)?.showsPill == true && tabContribution(for: kind) != nil
    }

    private func tabContribution(for kind: ShapeKind) -> TitleTabContribution? {
        memo(TabKey(kind: kind)) { contributions(to: TitleTabs.self, for: kind).first }
    }

    /// Whether a kind's shapes have titles: named (`title()`), derived (`title { … }`), or both.
    func isTitled(_ kind: ShapeKind) -> Bool { titleContribution(for: kind) != nil }

    /// What a shape's title tab says, as its pill would (`titlePill(of:in:)`), in the colors its kind gives
    /// it (`titleTab`) unless a look gives a tint: its ink by its surface, dark on light and light on dark.
    func titleTab(of shape: AnyShapeRecord, in context: TitleLookContext) -> AdornmentLabel? {
        guard let tab = tabContribution(for: shape.kind), let label = titleLabel(of: shape, in: context) else { return nil }
        guard label.tint == nil, let look = tab.look(shape, context) else { return label }
        return label.tinted(TitleTabStyle.tint(look))
    }

    /// What a shape's title pill says: its title, after its kind's symbol (`label(of:)`) where the
    /// kind asks for it (`symbolInPill`); on an untitled shape, the kind's placeholder, dimmed, where
    /// it gives one (`placeholderInPill`); else nothing.
    func titlePill(of shape: AnyShapeRecord, in context: TitleLookContext) -> AdornmentLabel? {
        guard tabContribution(for: shape.kind) == nil else { return nil }
        return titleLabel(of: shape, in: context)
    }

    /// The words of a shape's pill or tab, as `titlePill(of:in:)` says.
    private func titleLabel(of shape: AnyShapeRecord, in context: TitleLookContext) -> AdornmentLabel? {
        guard let titles = titleContribution(for: shape.kind), titles.showsPill else { return nil }
        let title = titles.title(shape)
        let look = titlePillLook(of: shape, title: title, in: context)
        if look?.hidesPill == true { return nil }
        let symbol = look?.symbol ?? (titles.symbolInPill ? label(of: shape.kind).systemImage : nil)
        var pill: AdornmentLabel
        if let title {
            pill = AdornmentLabel(title, systemImage: symbol)
        } else if let placeholder = TitleProperty.folded(look?.placeholder) ?? titles.pillPlaceholder {
            pill = AdornmentLabel(placeholder: placeholder, systemImage: symbol)
        } else {
            return nil
        }
        if let tint = look?.tint { pill = pill.tinted(tint) }
        return pill
    }

    /// The contributions that give a kind's pill a look: its own and those of the concerns whose
    /// property it holds, found once per kind, since a cover asks for every titled skeleton in view
    /// on every frame.
    private func titleContribution(for kind: ShapeKind) -> TitleContribution? {
        memo(TitleKey(kind: kind)) { contributions(to: ShapeTitles.self, for: kind).first }
    }

    private func pillLooks(for kind: ShapeKind) -> [TitlePillLookContribution] {
        memo(PillLooksKey(kind: kind)) { contributions(to: TitlePillLooks.self, for: kind) }
    }

    /// What the plugins that give a shape's pill a look say of it, merged: the first of each field
    /// in plugin order, a kind's own first; nil when none does. A concern's contribution is asked of
    /// the kinds that hold its property and no other.
    func titlePillLook(of shape: AnyShapeRecord, title: String?, in context: TitleLookContext) -> TitlePillLook? {
        var merged: TitlePillLook?
        for contribution in pillLooks(for: shape.kind) {
            guard let look = contribution.look(shape, title, context) else { continue }
            guard var result = merged else { merged = look; continue }
            result.symbol = result.symbol ?? look.symbol
            result.tint = result.tint ?? look.tint
            result.placeholder = result.placeholder ?? look.placeholder
            result.coverSurface = result.coverSurface ?? look.coverSurface
            result.hidesPill = result.hidesPill || look.hidesPill
            merged = result
        }
        return merged
    }

    /// What a shape's cover says (`TitleCoverStyle`) and what its kind's skeleton is drawn on: its
    /// title, for a kind that shows one in a pill; nil for an untitled shape (a placeholder is its
    /// pill's alone), a kind with no pill, and one whose title is a tab, which shows zoomed out itself.
    func titleCover(of shape: AnyShapeRecord, in editor: CanvasEditor) -> (title: String, surface: NSColor?)? {
        guard let titles = titleContribution(for: shape.kind), titles.showsPill, tabContribution(for: shape.kind) == nil,
              let title = titles.title(shape) else { return nil }
        // A look's surface, asked with no services; then the shape's own, which its kind answers from
        // a service; then the kind's.
        if let surface = titlePillLook(of: shape, title: title, in: .none)?.coverSurface { return (title, surface) }
        let own = memo(CoverSurfaceKey(kind: shape.kind)) { contributions(to: TitleCoverSurfaces.self, for: shape.kind).first }
        return (title, own?.surface(shape, TitleLookContext(editor)) ?? titles.coverSurface)
    }
}

private struct CoverSurfaceKey: Hashable { let kind: ShapeKind }

/// A horizontal any kind can opt into: a title, kept in the property this plugin adds to the kind or
/// derived from the kind's own, in a pill on the canvas and naming the shape's row in the table of
/// contents. This plugin places the pill and offers `/title`, and `TitleHeader` renames it.
public struct TitlesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .titles }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TitleProperty.self)
        // The pill, on the shapes of the kinds whose title shows one: Titles places it, and defines no kind.
        registrar.forShapes(adopting: .titlePill) { pilled in
            pilled.adornment(TitlePill.self) { shape, context in context.registry.titlePill(of: shape, in: TitleLookContext(context)) }
        }
        // The tab, on the shapes of the kinds whose title is one: on the top edge, at every zoom.
        registrar.forShapes(adopting: .titleTab) { tabbed in
            tabbed.adornment(TitleTab.self) { shape, context in context.registry.titleTab(of: shape, in: TitleLookContext(context)) }
        }
        // `/title Groceries` typed on a line of a shape's text: names the shape, on the kinds that can
        // be named. A derived title isn't Titles' to set, and is renamed where it's
        // derived from; a pill in the line is its name, "@Label", as the argument's text reads it. It
        // acts on one shape (`reach: .one`): a title tells a shape apart, and several shapes given one
        // would be several paths alike, which Boards warns of, so it isn't listed for a selection of
        // more than one.
        registrar.forShapes(holding: TitleProperty.self) { named in
            named.slashCommands {
                SlashCommand("title", argument: "title", reach: .one) { shape, arguments in shape[TitleProperty.self] = arguments.text }
            }
        }
        // Zoomed out, where a skeleton has no pill, the title is said on the shape.
        registrar.overlay(TitleCoverOverlay())
        // VoiceOver says a titled shape's title first, before what it is: "Checkout, Note".
        registrar.forShapes(adopting: .titled) { titled in
            titled.accessibility { record, editor in AccessibleTraits(name: editor.registry.title(of: record)) }
        }
    }
}
