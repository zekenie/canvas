import AppKit
import Canvas
import CoreGraphics
import Selection

/// Adornments, as a plugin: the small things shown on a shape, just outside it or on its corner,
/// from what the shape knows (a title's pill, a lock). Any plugin puts one on
/// any kind: its own, another plugin's, or the kinds a scope reaches (those that can be locked). This
/// plugin lays them out, so none on a
/// shape overlaps another, and draws them; a point on one is a point on its shape, for the select
/// tool, hover and the context menu (Selection's `DecorationHits`), but a clickable one (the lock)
/// is a canvas button, its shape's only for the context menu. Zoomed out, on a shape the canvas
/// draws as a skeleton (`editor.drawsSkeleton(of:)`: every shape but the one being edited), none is
/// drawn or pointed at but a tab (`AdornmentPlacement.onTopEdge`, a frame's title): a skeleton is the
/// shape alone, and what it's called is said on it (Titles' cover) or on its edge. An adornment is never a shape or a record: it's made from its shape's data, so it
/// moves, copies, deletes and saves with the shape. The core never learns what an adornment is.
extension PluginID {
    public static let adornments: PluginID = "adornments"
}

/// An adornment. The type is the adornment, as a tab's type is the tab: every contribution that
/// names it puts the same thing in the same place, and a typo doesn't compile. Any plugin may
/// declare one. Conform in an extension.
///
///     public enum LockChip {}
///     extension LockChip: Adornment {
///         public static var placement: AdornmentPlacement { .aboveTopRight }
///         public static var order: Order<Self> { .last }
///     }
public protocol Adornment: SendableMetatype {
    /// Where it goes on its shape. Adornments sets out every place, so nothing in one overlaps
    /// anything else.
    static var placement: AdornmentPlacement { get }
    /// Where it goes among the adornments in its place (`Order`), the first nearest the place's
    /// start, as the detail panel's tabs and the context menu's groups do: by default where it first
    /// appears (the kind's own, then every kind's, each in plugin order). One that says the shape's
    /// state, which comes and goes (a lock), is last, farthest out, so the others keep their places;
    /// one that goes with another is right after it (a type's chips after the title's pill).
    static var order: Order<Self> { get }
}

extension Adornment {
    public static var order: Order<Self> { .natural }

    /// How another adornment names this one, to be placed beside it.
    static var orderAnchor: OrderAnchor { OrderAnchor(Self.self, name: "\(Self.self)") { order.rule } }
}

extension Order where Subject: Adornment {
    /// Right before `adornment`, in its place.
    public static func before<A: Adornment>(_: A.Type) -> Self { Self(.before(A.orderAnchor)) }
    /// Right after `adornment`, in its place.
    public static func after<A: Adornment>(_: A.Type) -> Self { Self(.after(A.orderAnchor)) }
}

/// An adornment a click does something with: a canvas button (Selection's), which the select tool
/// clicks before anything else under the pointer. It draws lighter hovered and darker pressed, and
/// the pointing hand shows over it; a right-click on it is on its shape, as on any adornment. The
/// lock chip: a click unlocks its shape. Each one shown is also a part of its shape (Selection's
/// `ShapeParts`), on the kinds it is on, with no code of its own: ⌥Tab reaches it, and Return and Space
/// click it, named by its label's text (else `partTitle`) and `partRole`. One showing for a moment
/// (`ChipFade`: an open lock, "Private") is not one: what its click does has a command.
public protocol ClickableAdornment: Adornment {
    @MainActor static func click(_ click: AdornmentClick, in editor: CanvasEditor)
    /// What VoiceOver calls a label of it with no text (a symbol alone): by default its type's name in words,
    /// "Lock Chip".
    static var partTitle: String { get }
    /// What its click is to VoiceOver: `.button` by default, `.menuButton` for one whose click pops a menu.
    static var partRole: PartRole { get }
}

extension ClickableAdornment {
    public static var partTitle: String { AdornmentID.of(Self.self).spokenName }
    public static var partRole: PartRole { .button }
}

/// Which of a group's labels a chip is: any plugin's own name for it (a type chip's is its type
/// note's id), kept with the label so a click and a hover go by it, and a rename or a change in the
/// others' places doesn't change which one the pointer's on.
public struct AdornmentTag: Hashable, Sendable {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(_ id: ShapeID) { raw = id.description }
}

/// A click on a clickable adornment: its shape, the label's tag (nil for an untagged label, and for
/// a group's "+N" chip, `isOverflow`), and where the chip is now, in world units, where its shape
/// is (not where a shake draws it): what a menu opened by the click goes below.
public struct AdornmentClick: Equatable, Sendable {
    public let shape: ShapeID
    public let tag: AdornmentTag?
    public let rect: CGRect
    /// The click is on a group's "+N" chip, which stands for the labels the row had no room for.
    public let isOverflow: Bool

    public init(shape: ShapeID, tag: AdornmentTag? = nil, rect: CGRect, isOverflow: Bool = false) {
        self.shape = shape
        self.tag = tag
        self.rect = rect
        self.isOverflow = isOverflow
    }
}

/// Where on its shape an adornment goes, from the shape's bounds (its geometry's, axis-aligned), in
/// view points: constant on screen down to 25% zoom, shrinking with the shapes below that.
public enum AdornmentPlacement: Hashable, Sendable, CaseIterable {
    /// The row just above the top edge (18 points tall, 9 above it), from its left end rightward,
    /// in the room its right end leaves: text gives way, ending in "…", and needs 30 points (and
    /// a symbol before it, its place), or it isn't shown. A title's pill.
    case aboveTopLeft
    /// The same row, from its right end leftward, whole: past the shape's left end on a shape too
    /// narrow for it. A lock.
    case aboveTopRight
    /// The top-right corner: centered on the top edge (16 points tall), reaching 6 points past the
    /// right edge, then leftward along it; a point clear of the row. A tally, "☑ 2/5".
    case onTopRightCorner
    /// The lead of an open shape's label (an arrow's), where the shape's geometry keeps room for it
    /// (`ShapeGeometry.labelLead`): a pill that sits in the line's cut with the label's words after it, drawn
    /// and pointed at in world units, as the words are, so it follows the zoom as they do. One to a shape,
    /// the first of the contributions that shows anything, drawn in the face that fits the room the geometry
    /// gave (`AdornmentLabel.narrowing(to:)`). The geometry asks how wide it is (`AdornmentLead.faces`, a layout
    /// input Adornments provides) and leaves that room; a shape whose geometry leaves none shows none.
    case inLabelLead
    /// A tab on the top edge of a closed shape, half above it and half below (18 points tall), from 10
    /// points in from its left end, as long as its text and no longer than the edge leaves it, ending in
    /// "…" (it needs 30 points, as text in the row does); turned down the left edge, reading downward, on
    /// a shape at least twice as tall as it is wide where that shows more of its text. The one place
    /// shown zoomed out too, on a shape drawn as a skeleton, and the same size on screen at every zoom:
    /// what names a shape that holds others (a frame). Tabs on different shapes give way to each other,
    /// the outermost shape's first, then the larger's: one that meets a tab already placed slides along
    /// its edge past it, and is left out where its edge has no room left. One to a shape, the first
    /// contribution that shows anything; zoomed out, a placeholder's (`AdornmentLabel(placeholder:)`)
    /// isn't shown, since it names nothing.
    case onTopEdge
}

/// An adornment's identity: its type. Equal when the types are.
public struct AdornmentID: Hashable, Sendable, CustomStringConvertible {
    let type: ObjectIdentifier
    /// Module-qualified (`Titles.TitlePill`): in conflict keys.
    public let name: String
    public let placement: AdornmentPlacement
    /// Where it goes among the adornments in its place, and how another names it.
    let order: OrderRule
    let anchor: OrderAnchor
    let shortName: String

    init<A: Adornment>(_: A.Type) {
        type = ObjectIdentifier(A.self)
        name = String(reflecting: A.self)
        placement = A.placement
        order = A.order.rule
        anchor = A.orderAnchor
        shortName = String(describing: A.self)
    }

    public static func of<A: Adornment>(_ adornment: A.Type) -> AdornmentID { AdornmentID(adornment) }

    public static func == (a: Self, b: Self) -> Bool { a.type == b.type }
    public func hash(into hasher: inout Hasher) { hasher.combine(type) }

    /// The type's own name, as the report shows it: "TitlePill".
    public var description: String { shortName }

    /// The type's own name in words: "Lock Chip".
    var spokenName: String {
        var words = ""
        for character in shortName {
            if character.isUppercase, !words.isEmpty, words.last?.isUppercase == false { words.append(" ") }
            words.append(character)
        }
        return words
    }
}

/// A clickable adornment on one shape: what `editor.hoveredButton` and `editor.pressedButton` hold
/// while the pointer's on it.
public struct AdornmentButton: Hashable, Sendable {
    public let adornment: AdornmentID
    public let shape: ShapeID
    /// Which of a group's labels (nil for an untagged label, and for the "+N" chip).
    public let tag: AdornmentTag?
    /// The group's "+N" chip, which stands for the labels the row had no room for.
    public let isOverflow: Bool

    public init<A: ClickableAdornment>(_: A.Type, on shape: ShapeID, tag: AdornmentTag? = nil) {
        self.init(.of(A.self), on: shape, tag: tag)
    }

    /// The "+N" chip of `A`'s group on a shape.
    public static func overflow<A: ClickableAdornment>(of _: A.Type, on shape: ShapeID) -> AdornmentButton {
        AdornmentButton(.of(A.self), on: shape, tag: nil, isOverflow: true)
    }

    init(_ adornment: AdornmentID, on shape: ShapeID, tag: AdornmentTag? = nil, isOverflow: Bool = false) {
        self.adornment = adornment
        self.shape = shape
        self.tag = tag
        self.isOverflow = isOverflow
    }
}

/// A color a label is drawn in, in place of its tone's: a type's, in Types. A color may follow the
/// appearance (a dynamic `NSColor`), and Adornments makes its fills for the appearance drawn, once
/// each. Solid, the capsule is the color and its text and symbol are its `ink`, white by default;
/// light, the capsule is the color faint, with a thin line of it, and the text and symbol are its
/// `ink`, the color itself by default. An ink may follow the appearance too (a color that reads on
/// the capsule whichever it is). An `edge` is a 1-point line of its own inside the capsule's edge, in
/// place of a light tint's: a frame's tab, in its surface and its border.
///
/// A dynamic color is equal to itself only: a caller that makes a tint again and again for one
/// color keeps the tint (or the `NSColor`s it is made of), or what Adornments keeps per tint grows.
public struct AdornmentTint: Hashable, @unchecked Sendable {
    public enum Style: Hashable, Sendable { case solid, light }

    public let color: NSColor
    public let ink: NSColor
    public let style: Style
    public let edge: NSColor?

    /// `ink` is white for a solid tint and the color itself for a light one, by default.
    public init(_ color: NSColor, ink: NSColor? = nil, edge: NSColor? = nil, style: Style) {
        self.color = color
        self.ink = ink ?? (style == .solid ? .white : color)
        self.edge = edge
        self.style = style
    }
}

/// What an adornment shows on one shape. Adornments draws it, so every plugin's look alike (as
/// `ContentsLabel` does for rows): a capsule in the title pill's dark gray (green for something
/// done), white text on one line (dimmed for a placeholder's), a small symbol before it if it has
/// one (a kind's mark: a subboard's title's `rectangle.stack`), or a symbol alone in a disc. Its height, font
/// and padding are its place's: 18 points, 11-point text, 7 in, in the row; 16 points, 10-point
/// semibold figures, 5 in, on the corner. On a shape drawn as a skeleton, zoomed out
/// (`editor.drawsSkeleton(of:)`), it isn't drawn, unless it's a tab (`onTopEdge`).
public struct AdornmentLabel: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        case neutral
        /// Something finished: a tally with every item done.
        case success
    }

    /// The inks of plain text (`line(_:ink:)`), each following the appearance: the canvas's label color, and the
    /// softer one (secondary text).
    public enum LineInk: Hashable, Sendable {
        case primary, secondary
    }

    /// On one line: each run of whitespace, newlines included, folds into a space. Blank shows nothing.
    public private(set) var text: String?
    /// An SF Symbol: with text, drawn small before it, in a place as wide as the text is tall;
    /// alone, in a disc as tall as its place.
    public let systemImage: String?
    public var tone: Tone
    /// How opaque it's drawn: 1, but for one fading away (an open lock).
    public var opacity: CGFloat
    /// Whether the symbol before its text is drawn in full white, as the text is, where it is by
    /// default a little softer (a kind's mark, which marks the title rather than reading as part of
    /// it); for a symbol that is itself the news, as the Public chip's globe.
    public var hasBrightSymbol: Bool
    /// Its text stands in for what isn't there (an untitled shape's pill, `init(placeholder:)`):
    /// drawn dimmed, as secondary text is.
    public let isPlaceholder: Bool
    /// Which of its adornment's labels this is (`tagged(_:)`): a group's chips are told apart by it,
    /// for hover, press and click.
    public private(set) var tag: AdornmentTag?
    /// What it names is gone (`missing()`): no fill, a dashed stroke, the text in italic.
    public private(set) var isMissing: Bool
    /// It says something is wrong (`wrong()`): a chip in red with a wavy underline.
    public private(set) var isWrong: Bool
    /// Plain text with no capsule, in this ink (`line(_:ink:)`); nil for a chip.
    public private(set) var lineInk: LineInk?
    /// A number after the text, in a softer ink (`counted(_:)`): how many of something the chip stands for. Kept whole
    /// where the text gives way. Nil for none.
    public private(set) var count: Int?
    /// The smaller face this label may be drawn in (`compact(_:)`): at most one, held in an array
    /// since a label can't hold itself.
    private var compactFaces: [AdornmentLabel]
    /// The color it is drawn in (`tinted(_:)`), in place of its tone's; nil for none. Part of what
    /// makes two labels equal, so a shape whose tint changes is laid out again.
    public private(set) var tint: AdornmentTint?
    /// A word after the text in the ink of the number (`noted(_:)`): what a relationship's pill says of its
    /// first filled value. Kept whole where the text gives way, as a number is.
    public private(set) var note: String? = nil
    /// No text: a dot or a dashed outline (`mark(_:)`), the lead's narrowest face and its offer.
    public private(set) var mark: Mark? = nil
    /// The faces the label's place may take instead, widest first (`narrowing(to:)`): at the lead of an
    /// open shape's label, where the room may be less than the whole. Never a face's own.
    private var narrower: [AdornmentLabel] = []

    /// What a label with no text is.
    public enum Mark: Hashable, Sendable {
        /// A filled disc, `AdornmentStyle.dotSize` across, in the tint: a pill where there is no room for one.
        case dot
        /// A dashed outline of a pill with nothing in it, in the canvas's label color: where a pill could be.
        case ghost
    }

    /// Text, after a small symbol if `systemImage` names one (a kind's mark: a subboard's `rectangle.stack`).
    public init(_ text: String, systemImage: String? = nil, tone: Tone = .neutral) {
        self.init(text: text, systemImage: systemImage, tone: tone, isPlaceholder: false)
    }

    /// Text standing in for what isn't there, as an untitled shape's pill says "Frame": laid out as
    /// `init(_:systemImage:tone:)` lays it out, its text dimmed.
    public init(placeholder: String, systemImage: String? = nil) {
        self.init(text: placeholder, systemImage: systemImage, tone: .neutral, isPlaceholder: true)
    }

    private init(text: String, systemImage: String?, tone: Tone, isPlaceholder: Bool) {
        self.text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.systemImage = systemImage
        self.tone = tone
        opacity = 1
        hasBrightSymbol = false
        self.isPlaceholder = isPlaceholder
        tag = nil
        isMissing = false
        isWrong = false
        lineInk = nil
        count = nil
        compactFaces = []
        tint = nil
    }

    public init(systemImage: String, tone: Tone = .neutral) {
        text = nil
        self.systemImage = systemImage
        self.tone = tone
        opacity = 1
        hasBrightSymbol = false
        isPlaceholder = false
        tag = nil
        isMissing = false
        isWrong = false
        lineInk = nil
        count = nil
        compactFaces = []
        tint = nil
    }

    /// A label with no text: a dot or a ghost (`Mark`), drawn in the tint it is given.
    public static func mark(_ mark: Mark) -> AdornmentLabel {
        var label = AdornmentLabel(text: "", systemImage: nil, tone: .neutral, isPlaceholder: false)
        label.text = nil
        label.mark = mark
        return label
    }

    /// Plain text with no capsule, in `ink`, which follows the appearance: a word in the row where a name would be (an
    /// arrow's `from`), laid out there as a chip of its width is. Blank shows nothing.
    public static func line(_ text: String, ink: LineInk = .primary) -> AdornmentLabel {
        var label = AdornmentLabel(text)
        label.lineInk = ink
        return label
    }

    /// Whether it is plain text (`line(_:ink:)`).
    public var isLine: Bool { lineInk != nil }

    /// What is wrong is red, in either appearance.
    static var wrongColor: NSColor { .systemRed }

    /// The same label, saying something is wrong: a chip is a red fill at 14%, its text and symbol red and a
    /// wavy line under the text, whatever its tint. A missing label stays as it is.
    public func wrong() -> AdornmentLabel {
        var label = self
        label.isWrong = true
        label.tint = AdornmentTint(Self.wrongColor, style: .light)
        return label
    }

    /// The same label with a number after its text, in its ink at `AdornmentStyle.countStrength`: how many of something
    /// the chip stands for (a relationship's fields). The text gives way before the number does. None for a label with
    /// no text or a plain line (`line(_:ink:)`), and a negative number is none.
    public func counted(_ count: Int?) -> AdornmentLabel {
        var label = self
        label.count = text == nil || lineInk != nil ? nil : count.flatMap { $0 < 0 ? nil : $0 }
        return label
    }

    /// The same label with a word after its text, in the number's ink: `owner · 2021`. Blank is none, and a
    /// label with no text or a plain line has none.
    public func noted(_ note: String?) -> AdornmentLabel {
        var label = self
        let words = note.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        label.note = text == nil || lineInk != nil || words?.isEmpty != false ? nil : words
        return label
    }

    /// The same label with the narrower faces its place may take when it has less room than the whole (the
    /// lead of an open shape's label), widest first: the geometry takes the first that fits. A face is no
    /// label's own narrower; one that shows nothing is left out.
    public func narrowing(to faces: [AdornmentLabel]) -> AdornmentLabel {
        var label = self
        label.narrower = faces.filter(\.showsSomething).map { face in
            var face = face
            face.narrower = []
            return face
        }
        return label
    }

    /// The narrower faces (`narrowing(to:)`), widest first.
    public var narrowerFaces: [AdornmentLabel] { narrower }

    /// The same label, drawn this opaque (0 to 1), its compact face too.
    public func opacity(_ opacity: CGFloat) -> AdornmentLabel {
        var label = self
        label.opacity = min(1, max(0, opacity))
        if let face = compactFace { label = label.compact(face.opacity(opacity)) }
        return label
    }

    /// The same label as the one `tag` names, among its adornment's: a click on it, and the hover and
    /// press on it, say which.
    public func tagged(_ tag: AdornmentTag) -> AdornmentLabel {
        var label = self
        label.tag = tag
        return label
    }

    /// The same label drawn in `tint`'s color (a missing label ignores it, and keeps its dashes): a
    /// tint wins over the tone, and a wrong label (`wrong()`) keeps its red. Its compact face is its own label, tinted if whoever made it did.
    public func tinted(_ tint: AdornmentTint) -> AdornmentLabel {
        var label = self
        if !isWrong { label.tint = tint }
        return label
    }

    /// The same label drawn as naming what is gone, as a mention's pill does (Mentions): no fill, a
    /// dashed stroke and its text in italic, in the canvas's own label colors; its symbol before the
    /// text is left off, since it is white. Text, and a symbol alone in a dashed ring.
    public func missing() -> AdornmentLabel {
        var label = self
        label.isMissing = true
        return label
    }

    /// The same label with its symbol before the text drawn in full white, its compact face's too.
    public func brightSymbol() -> AdornmentLabel {
        var label = self
        label.hasBrightSymbol = true
        if let face = compactFace { label = label.compact(face.brightSymbol()) }
        return label
    }

    /// The same label with a smaller face to fall back on: Adornments draws `face` in its place
    /// whenever the full label would make the row's left end's text (a title's pill) truncate or
    /// vanish and `face` gives it more room (showing it whole, or some of it where it would show
    /// none; while none shows at all, as on a shape too small for a title, it stays compact), and goes
    /// back to the full label once the shape has room for both. Laid out in the
    /// same place as the label, in its own look (a symbol alone, say, where the label is text with
    /// a figure), and never a compact face's own: a face that shows nothing is no face. Only a
    /// label at the row's right end (`aboveTopRight`) gives way this way.
    public func compact(_ face: AdornmentLabel) -> AdornmentLabel {
        var label = self
        var face = face
        face.compactFaces = []
        label.compactFaces = face.showsSomething ? [face] : []
        return label
    }

    /// The face this label falls back on when the row's left end needs the room, if it has one.
    public var compactFace: AdornmentLabel? { compactFaces.first }

    /// Whether it says anything: text that isn't blank, or a symbol.
    var showsSomething: Bool { mark != nil || (text.map { !$0.isEmpty } ?? (systemImage != nil)) }
}

/// What an open shape's geometry reads to leave room for the pill that leads its label (`AdornmentPlacement.inLabelLead`):
/// how big each face the pill may take is, widest first, and the tint it is drawn in (so a skeleton can draw its
/// capsule). Adornments provides it, from the contributions placed there; nil for a shape with none. Nothing is stored:
/// when what the pill says changes with no commit to the shape, Adornments says the layout changed
/// (`adornmentsDidChange(for:)`).
public enum AdornmentLead {
    public struct Faces: Hashable, Sendable {
        /// Each face's size in world units, at one to one: widest first, the first the pill in full.
        public let sizes: [CGSize]
        /// The color it is drawn in.
        public let tint: AdornmentTint?

        public init(sizes: [CGSize], tint: AdornmentTint?) {
            self.sizes = sizes
            self.tint = tint
        }
    }

    public static let faces = LayoutInputKey<Faces>("adornment-lead")
}

/// What a scoped adornment's label may read besides its shape. The registry never changes.
/// A service's state is read only by one that tells Adornments when it changes
/// (`editor.adornmentsDidChange(for:)`): a shape's labels are made again only then, or when a
/// commit names the shape.
@MainActor
public struct AdornmentContext {
    let editor: CanvasEditor
    public var registry: Registry { editor.registry }
    public func service<S: EditorService>(_: S.Type) -> S? { editor.service(S.self) }
    /// A layout input of the shape, as the editor lays it out now: read only by one whose provider tells Adornments when it
    /// changes (a connection's bundle: `editor.adornmentsDidChange(for:)`).
    public func layoutInput<V>(_ key: LayoutInputKey<V>, of record: AnyShapeRecord) -> V? { editor.shapeContext.layoutInput(key, of: record) }
}

// MARK: The extension point

/// The adornments on each kind's shapes: a kind's own (or another plugin's for it), and those for the
/// kinds a scope reaches (`registrar.forShapes(holding:) { $0.adornment(…) }`). Keyed: one of each
/// adornment per kind, so two plugins putting one adornment on a kind is `RegistryError.conflict`. A
/// kind's own takes the place of a scoped one of the same type, as a kind's own menu item does.
public enum ShapeAdornments {}

extension ShapeAdornments: KeyedExtensionPoint {
    public typealias Contribution = AdornmentContribution
    public static var owner: PluginID { .adornments }
    /// An adornment on other kinds' shapes says which: the kinds that hold a property, or have a capability.
    public static var scope: PointScope { .scoped }

    public static func uniqueKeys(of contribution: AdornmentContribution, for target: ShapeTarget) -> [AnyHashable] {
        [AdornmentKey(target: target, adornment: contribution.adornment)]
    }

    /// Several labels are for the row's left end only: at the right end a run is cut where it
    /// reaches `maxRun`, and everything after it with it (the lock), and the corner is a tally's.
    /// Adornments placed beside each other in a circle have no order.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for c in registry.contributions(to: ShapeAdornments.self) where c.value.isGroup && c.value.adornment.placement != .aboveTopLeft {
            throw .invalid(point: "ShapeAdornments", reason: "\(c.value.adornment.name) (from \(c.pluginID)) shows several labels, which only aboveTopLeft allows, not \(c.value.adornment.placement)")
        }
        if let cycle = OrderRule.cycle(from: registry.contributions(to: ShapeAdornments.self).map(\.value.adornment.anchor)) {
            throw .invalid(point: "ShapeAdornments", reason: "adornments placed beside each other in a circle: \(cycle)")
        }
    }

    /// "adornment LockChip last → every shape holding locked", "adornment Flag → box": its order if
    /// it says one.
    public static func summary(of contribution: AdornmentContribution, for target: ShapeTarget) -> String {
        let order = contribution.adornment.order
        return "adornment \(contribution.adornment)" + (order == .natural ? "" : " \(order)") + " → \(target)"
    }
}

/// What a contribution claims: "box AdornmentsTests.Flag", "* Titles.TitlePill".
struct AdornmentKey: Hashable, CustomStringConvertible {
    let target: ShapeTarget
    let adornment: AdornmentID
    var description: String { "\(target) \(adornment.name)" }
}

/// What `ShapeAdornments` stores. Only the sugar makes one.
@MainActor
public struct AdornmentContribution {
    let adornment: AdornmentID
    let labels: @MainActor (AnyShapeRecord, AdornmentContext) -> [AdornmentLabel]
    /// Several labels, in order, each its own chip, each shown whole or folded into a "+N" chip:
    /// only at `aboveTopLeft`.
    let isGroup: Bool
    /// From the type's `ClickableAdornment` conformance, if it has one.
    let click: (@MainActor (AdornmentClick, CanvasEditor) -> Void)?

    init<A: Adornment>(_: A.Type, label: @escaping @MainActor (AnyShapeRecord, AdornmentContext) -> AdornmentLabel?) {
        self.init(A.self, isGroup: false) { shape, context in label(shape, context).map { [$0] } ?? [] }
    }

    init<A: Adornment>(_: A.Type, isGroup: Bool, labels: @escaping @MainActor (AnyShapeRecord, AdornmentContext) -> [AdornmentLabel]) {
        adornment = .of(A.self)
        self.isGroup = isGroup
        self.labels = labels
        if let clickable = A.self as? any ClickableAdornment.Type {
            click = { click, editor in clickable.click(click, in: editor) }
        } else {
            click = nil
        }
    }
}

// MARK: Sugar

extension ShapeRegistrar {
    /// `A` on this kind's shapes, showing what `label` says of each: nil for nothing, on that shape.
    /// It reads only the shape, and is asked again only when a commit changes it. A horizontal's
    /// opt-in sugar may call this, so opting in brings its adornment.
    ///
    ///     note.adornment(SizeBadge.self) { AdornmentLabel("\(Int($0.frame.width)) pt") }
    public mutating func adornment<A: Adornment>(_: A.Type, _ label: @escaping @MainActor (ShapeRecord<Definition.Props>) -> AdornmentLabel?) {
        contribute(AdornmentContribution(A.self) { shape, _ in shape.typed(as: Definition.Props.self).flatMap(label) },
                   to: ShapeAdornments.self)
        if AdornmentParts.isClickable(A.self) { shapeParts(named: "\(A.self)") { editor, shape in AdornmentParts.parts(of: A.self, on: shape.id, in: editor) } }
    }
}

extension ShapeRegistrar {
    /// `A` on this kind's shapes as several chips, one per label, in order, each tagged
    /// (`AdornmentLabel.tagged(_:)`): at `aboveTopLeft` only (the registry refuses it elsewhere). A
    /// chip is shown whole or not at all: the first the row has no room for and those after it fold
    /// into one "+N" chip, which is shown if it fits.
    public mutating func adornments<A: Adornment>(_: A.Type, _ labels: @escaping @MainActor (ShapeRecord<Definition.Props>) -> [AdornmentLabel]) {
        contribute(AdornmentContribution(A.self, isGroup: true) { shape, _ in shape.typed(as: Definition.Props.self).map(labels) ?? [] },
                   to: ShapeAdornments.self)
        if AdornmentParts.isClickable(A.self) { shapeParts(named: "\(A.self)") { editor, shape in AdornmentParts.parts(of: A.self, on: shape.id, in: editor) } }
    }
}

extension PluginRegistrar {
    /// `adornments` on the shapes of a kind another plugin registers.
    public mutating func adornments<A: Adornment, P: ShapeProps>(_: A.Type, on _: P.Type,
                                                                 _ labels: @escaping @MainActor (ShapeRecord<P>) -> [AdornmentLabel]) {
        contribute(AdornmentContribution(A.self, isGroup: true) { shape, _ in shape.typed(as: P.self).map(labels) ?? [] },
                   to: ShapeAdornments.self, for: .kind(P.kind))
        if AdornmentParts.isClickable(A.self) { shapeParts(on: P.self, named: "\(A.self)") { editor, shape in AdornmentParts.parts(of: A.self, on: shape.id, in: editor) } }
    }

    /// `A` on the shapes of a kind another plugin registers, as `adornment` does on a
    /// kind's own registrar.
    public mutating func adornment<A: Adornment, P: ShapeProps>(_: A.Type, on _: P.Type,
                                                                _ label: @escaping @MainActor (ShapeRecord<P>) -> AdornmentLabel?) {
        contribute(AdornmentContribution(A.self) { shape, _ in shape.typed(as: P.self).flatMap(label) },
                   to: ShapeAdornments.self, for: .kind(P.kind))
        if AdornmentParts.isClickable(A.self) { shapeParts(on: P.self, named: "\(A.self)") { editor, shape in AdornmentParts.parts(of: A.self, on: shape.id, in: editor) } }
    }
}

extension ScopedRegistrar {
    /// `A` on the shapes of every kind the scope reaches, showing what `label` says: what a horizontal
    /// places on shapes it doesn't define, only where its feature is (Locking's lock on the kinds that
    /// can be locked). A kind's own `A` takes its place.
    ///
    ///     registrar.forShapes(holding: LockedProperty.self) { lock in
    ///         lock.adornment(LockChip.self) { shape, _ in shape.isLocked ? AdornmentLabel(systemImage: "lock.fill") : nil }
    ///     }
    public mutating func adornment<A: Adornment>(_: A.Type, _ label: @escaping @MainActor (AnyShapeRecord, AdornmentContext) -> AdornmentLabel?) {
        contribute(AdornmentContribution(A.self, label: label), to: ShapeAdornments.self)
        if AdornmentParts.isClickable(A.self) { shapeParts(named: "\(A.self)") { editor, shape in AdornmentParts.parts(of: A.self, on: shape.id, in: editor) } }
    }

    /// `adornments` on the shapes of every kind the scope reaches, as `adornment` does for one label.
    public mutating func adornments<A: Adornment>(_: A.Type, _ labels: @escaping @MainActor (AnyShapeRecord, AdornmentContext) -> [AdornmentLabel]) {
        contribute(AdornmentContribution(A.self, isGroup: true, labels: labels), to: ShapeAdornments.self)
        if AdornmentParts.isClickable(A.self) { shapeParts(named: "\(A.self)") { editor, shape in AdornmentParts.parts(of: A.self, on: shape.id, in: editor) } }
    }
}

// MARK: Reading

/// One of a shape's adornments as the canvas lays it out now.
public struct AdornmentFrame: Equatable {
    public let adornment: AdornmentID
    public let label: AdornmentLabel
    /// In world units, at the current zoom, where the shape is (not where a shake draws it), as
    /// hit testing goes.
    public let rect: CGRect
    /// It is a group's "+N" chip, its `label` the "+N" itself.
    public let isOverflow: Bool

    /// Which of its adornment's labels: nil for an untagged one, and for the "+N" chip.
    public var tag: AdornmentTag? { isOverflow ? nil : label.tag }
}

extension CanvasEditor {
    /// A shape's adornments as they're laid out now, in the order they're claimed; those left out
    /// for want of room aren't listed. Empty for a shape with none, without bounds, or not there,
    /// and while the canvas draws the shape as a skeleton (`drawsSkeleton(of:)`), which shows none.
    public func adornmentFrames(of id: ShapeID) -> [AdornmentFrame] {
        guard let state = adornmentState, let record = document[id] else { return [] }
        return state.frames(of: record)
    }

    /// How far right of a closed shape's left edge its row above the top-left starts, at the earliest, in world units at
    /// the zoom now, to keep clear of a container's tab (a table's pill, or its bar zoomed out, at a database's top-left
    /// inset): 0 where no container's tab meets the row. What Titles' bars zoomed out go by, as the row does.
    public func adornmentRowStart(of id: ShapeID) -> CGFloat {
        guard let state = adornmentState, state.hasTabs, document[id] != nil else { return 0 }
        return state.rowStart(of: id)
    }

    /// Where the containers' tabs that a closed shape's row above its top-left gives way to are (`adornmentRowStart`), as one
    /// rect in world units at the zoom now; nil where none meets the row. What Titles' bar zoomed out keeps below when it goes
    /// inside its shape's top edge, too narrow to start past them.
    public func adornmentRowTabs(of id: ShapeID) -> CGRect? {
        guard let state = adornmentState, state.hasTabs, document[id] != nil else { return nil }
        return state.rowTabs(of: id)
    }

    /// The rect a shape's adornment row is laid out against, in world units, at the zoom now: a closed
    /// shape's bounds (a note's top-left is the row's), an open shape's label's if it has one, else a zero-size
    /// rect at the middle of its outline, either widened about its center to what a row needs. What
    /// something that hangs from the same place (a menu under an arrow, a card at a shape's pill) goes by,
    /// so it hangs where the row does: on a slanted open shape the anchor is moved along by the row's slide clear of the
    /// body (`AdornmentLayout`), so a falling arrow's is at its chip's left. Nil for a shape that isn't there or has nothing drawn, and where no
    /// plugin places adornments.
    public func adornmentAnchor(of id: ShapeID) -> CGRect? {
        adornmentState?.rowAnchor(of: id)
    }

    /// How far above its top edge a shape reaches with the adornments it would show at 100%, in world
    /// units (`AdornmentLayout.extent(of:in:)`): the row for a titled shape's pill. A shape that isn't on
    /// the board is asked as it would be shown there, and nothing is kept for it; 0 for one with none, or
    /// without a size, or where no plugin places adornments.
    public func adornmentExtent(of record: AnyShapeRecord) -> CGFloat {
        guard let state = adornmentState, let box = record.box,
              let laidOut = state.laidOut(record, keeping: false) else { return 0 }
        return AdornmentLayout.extent(of: laidOut.items, in: box.width, height: box.height)
    }

    /// How wide a shape must be, in world units at 100% zoom, for every adornment it would show to show whole (its title's pill
    /// or tab never cut: `AdornmentLayout.leastWidth(of:)`); 0 for one with none, or where no plugin places adornments. Asked of any
    /// record, on a board or not, keeping nothing for it: what `canvas measure` says a node's title needs.
    public func adornmentLeastWidth(of record: AnyShapeRecord) -> CGFloat {
        guard let state = adornmentState, record.box != nil, let laidOut = state.laidOut(record, keeping: false) else { return 0 }
        return AdornmentLayout.leastWidth(of: laidOut.items)
    }

    /// What these shapes' adornments show changed other than through the document (an open lock
    /// fading): they're made again, the canvas redraws, and the select tool looks for a button
    /// under a still pointer (`canvasButtonsDidChange`).
    public func adornmentsDidChange(for ids: Set<ShapeID>) {
        guard let state = adornmentState else { return }
        state.forget(ids)
        state.leadsMayHaveChanged(ids)
        setNeedsDisplay()
        canvasButtonsDidChange()
    }

    #if DEBUG
    /// How many shapes' adornments are kept, their labels made (debug builds only), so tests can
    /// hold a shape that's gone to being forgotten.
    public var adornmentsKept: Int { adornmentState?.keptCount ?? 0 }
    /// How many of those show something, their faces made and measured, and how many faces have
    /// been made in all (debug builds only): zoomed out, where skeletons show no adornments, none
    /// are made and none kept, but the shape being edited's.
    public var adornmentFacesKept: Int { adornmentState?.keptShowingCount ?? 0 }
    public var adornmentFacesMade: Int { adornmentState?.facesMade ?? 0 }
    #endif

    var adornmentState: AdornmentState? { service(AdornmentState.self) }
}

// MARK: The plugin

/// Lays out and draws every adornment, and makes them pointable: the clickable ones are canvas
/// buttons, and any is its shape's. Contributes none of its own.
public struct AdornmentsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .adornments }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { AdornmentState(editor: $0) }
        registrar.service { ChipFade(editor: $0) }
        // How big the pill that leads an open shape's label is, which the geometry leaves room for.
        registrar.layoutInput(AdornmentLead.faces) { record, reading in
            reading.service(AdornmentState.self)?.leadFaces(of: record, recording: reading.isCommitted)
        }
        registrar.overlay(AdornmentOverlay())
        // A clickable adornment is a canvas button: the select tool clicks it before anything else.
        registrar.canvasButtons(at: { editor, point in editor.adornmentState?.button(atViewPoint: point) },
                                click: { button, editor in editor.adornmentState?.click(button) })
        // Any other adornment is its shape's: a press, a hover or a double-click on it is on the
        // shape. Every one, a button too, is its shape's for a right-click.
        registrar.decorationHits { editor, point, include in editor.adornmentState?.shape(at: point, where: include) }
    }
}
