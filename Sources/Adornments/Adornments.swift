import Canvas
import CoreGraphics
import Selection

/// Adornments, as a plugin: the small things shown on a shape, just outside it or on its corner,
/// from what the shape knows (a title's pill, a lock). Any plugin puts one on
/// any kind: its own, another plugin's, or every shape. This plugin lays them out, so none on a
/// shape overlaps another, and draws them; a point on one is a point on its shape, for the select
/// tool, hover and the context menu (Selection's `DecorationHits`), but a clickable one (the lock)
/// is a canvas button, its shape's only for the context menu. Zoomed out, on a shape the canvas
/// draws as a skeleton (`editor.drawsSkeleton(of:)`: every shape but the one being edited), none is
/// drawn or pointed at: a skeleton is the shape alone, and what it's called is said on it (Titles'
/// cover). An adornment is never a shape or a record: it's made from its shape's data, so it
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
///         public static var order: Int { 300 }
///     }
public protocol Adornment {
    /// Where it goes on its shape. Adornments sets out every place, so nothing in one overlaps
    /// anything else.
    static var placement: AdornmentPlacement { get }
    /// Adornments in one place sort by this, then by first appearance (the kind's own, then every
    /// kind's, each in plugin order); the first is nearest the place's start. The bands, as the
    /// detail panel's tabs and the context menu's groups: 0 for a kind's own (the default), 50 for
    /// one a horizontal's feature brings (a title's pill), 300 for a state of
    /// the shape that comes and goes (a lock), farthest out, so the others keep their places.
    static var order: Int { get }
}

extension Adornment {
    public static var order: Int { 0 }
}

/// An adornment a click does something with: a canvas button (Selection's), which the select tool
/// clicks before anything else under the pointer. It draws lighter hovered and darker pressed, and
/// the pointing hand shows over it; a right-click on it is on its shape, as on any adornment. The
/// lock chip: a click unlocks its shape.
public protocol ClickableAdornment: Adornment {
    @MainActor static func click(on shape: ShapeID, in editor: CanvasEditor)
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
}

/// An adornment's identity: its type. Equal when the types are.
public struct AdornmentID: Hashable, Sendable, CustomStringConvertible {
    let type: ObjectIdentifier
    /// Module-qualified (`Titles.TitlePill`): in conflict keys.
    public let name: String
    public let placement: AdornmentPlacement
    let order: Int
    let shortName: String

    init<A: Adornment>(_: A.Type) {
        type = ObjectIdentifier(A.self)
        name = String(reflecting: A.self)
        placement = A.placement
        order = A.order
        shortName = String(describing: A.self)
    }

    public static func of<A: Adornment>(_ adornment: A.Type) -> AdornmentID { AdornmentID(adornment) }

    public static func == (a: Self, b: Self) -> Bool { a.type == b.type }
    public func hash(into hasher: inout Hasher) { hasher.combine(type) }

    /// The type's own name, as the report shows it: "TitlePill".
    public var description: String { shortName }
}

/// A clickable adornment on one shape: what `editor.hoveredButton` and `editor.pressedButton` hold
/// while the pointer's on it.
public struct AdornmentButton: Hashable, Sendable {
    public let adornment: AdornmentID
    public let shape: ShapeID

    public init<A: ClickableAdornment>(_: A.Type, on shape: ShapeID) { self.init(.of(A.self), on: shape) }

    init(_ adornment: AdornmentID, on shape: ShapeID) {
        self.adornment = adornment
        self.shape = shape
    }
}

/// What an adornment shows on one shape. Adornments draws it, so every plugin's look alike (as
/// `ContentsLabel` does for rows): a capsule in the title pill's dark gray (green for something
/// done), white text on one line (dimmed for a placeholder's), a small symbol before it if it has
/// one (a kind's mark: a schema card's title's `{}`), or a symbol alone in a disc. Its height, font
/// and padding are its place's: 18 points, 11-point text, 7 in, in the row; 16 points, 10-point
/// semibold figures, 5 in, on the corner. On a shape drawn as a skeleton, zoomed out
/// (`editor.drawsSkeleton(of:)`), it isn't drawn.
public struct AdornmentLabel: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        case neutral
        /// Something finished: a tally with every item done.
        case success
    }

    /// On one line: each run of whitespace, newlines included, folds into a space. Blank shows nothing.
    public let text: String?
    /// An SF Symbol: with text, drawn small before it, in a place as wide as the text is tall;
    /// alone, in a disc as tall as its place.
    public let systemImage: String?
    public var tone: Tone
    /// How opaque it's drawn: 1, but for one fading away (an open lock).
    public var opacity: CGFloat
    /// Its text stands in for what isn't there (an untitled shape's pill, `init(placeholder:)`):
    /// drawn dimmed, as secondary text is.
    public let isPlaceholder: Bool

    /// Text, after a small symbol if `systemImage` names one (a kind's mark: a schema card's `{}`).
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
        self.isPlaceholder = isPlaceholder
    }

    public init(systemImage: String, tone: Tone = .neutral) {
        text = nil
        self.systemImage = systemImage
        self.tone = tone
        opacity = 1
        isPlaceholder = false
    }

    /// The same label, drawn this opaque (0 to 1).
    public func opacity(_ opacity: CGFloat) -> AdornmentLabel {
        var label = self
        label.opacity = min(1, max(0, opacity))
        return label
    }
}

/// What an every-shape adornment's label may read besides its shape. The registry never changes.
/// A service's state is read only by one that tells Adornments when it changes
/// (`editor.adornmentsDidChange(for:)`): a shape's labels are made again only then, or when a
/// commit names the shape.
@MainActor
public struct AdornmentContext {
    let editor: CanvasEditor
    public var registry: Registry { editor.registry }
    public func service<S: EditorService>(_: S.Type) -> S? { editor.service(S.self) }
}

/// A kind, as an every-shape adornment's `where` sees it: its definition (so its capabilities) and
/// the registry (so what else it takes part in: Titles asks whether its title shows a pill).
@MainActor
public struct AdornableKind {
    public let kind: ShapeKind
    public let definition: any ShapeDefinition
    public let registry: Registry

    /// Whether this kind's shapes hold an added property: opted into it, however (Locking's lock
    /// goes on the kinds that can be locked, `$0.holds(LockedProperty.self)`).
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool { registry.properties(for: kind).contains(P.key) }
}

// MARK: The extension point

/// The adornments on each kind's shapes: a kind's own (or another plugin's for it), and every shape's that
/// `where` lets in. Keyed: one of each adornment per kind, and one for every kind, so two plugins
/// putting one adornment on a kind is `RegistryError.conflict`. A kind's own takes the place of an
/// every-shape one of the same type, as a kind's own menu item does.
public enum ShapeAdornments {}

extension ShapeAdornments: KeyedExtensionPoint {
    public typealias Contribution = AdornmentContribution
    public static var owner: PluginID { .adornments }

    public static func uniqueKeys(of contribution: AdornmentContribution, for target: ShapeTarget) -> [AnyHashable] {
        [AdornmentKey(target: target, adornment: contribution.adornment)]
    }

    /// "adornment TitlePill → every shape", "adornment Flag → box".
    public static func summary(of contribution: AdornmentContribution, for target: ShapeTarget) -> String {
        "adornment \(contribution.adornment) → \(target == .any ? "every shape" : "\(target)")"
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
    /// Every-shape ones: which kinds. Always true for a kind's own.
    let appliesTo: @MainActor (AdornableKind) -> Bool
    let label: @MainActor (AnyShapeRecord, AdornmentContext) -> AdornmentLabel?
    /// From the type's `ClickableAdornment` conformance, if it has one.
    let click: (@MainActor (ShapeID, CanvasEditor) -> Void)?

    init<A: Adornment>(_: A.Type, appliesTo: @escaping @MainActor (AdornableKind) -> Bool = { _ in true },
                       label: @escaping @MainActor (AnyShapeRecord, AdornmentContext) -> AdornmentLabel?) {
        adornment = .of(A.self)
        self.appliesTo = appliesTo
        self.label = label
        if let clickable = A.self as? any ClickableAdornment.Type {
            click = { id, editor in clickable.click(on: id, in: editor) }
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
    }
}

extension PluginRegistrar {
    /// `A` on the shapes of a kind another plugin registers, as `adornment` does on a
    /// kind's own registrar.
    public mutating func adornment<A: Adornment, P: ShapeProps>(_: A.Type, on _: P.Type,
                                                                _ label: @escaping @MainActor (ShapeRecord<P>) -> AdornmentLabel?) {
        contribute(AdornmentContribution(A.self) { shape, _ in shape.typed(as: P.self).flatMap(label) },
                   to: ShapeAdornments.self, for: .kind(P.kind))
    }

    /// `A` on every shape of the kinds `where` picks (every kind by default), showing what `label`
    /// says: what a horizontal places on shapes it doesn't define. `where` picks kinds by their
    /// definition, so by capability, or by what the registry says of them (Titles: the kinds whose
    /// title shows a pill); it's asked once per kind.
    ///
    ///     registrar.adornmentForEveryShape(LockChip.self) { shape, _ in
    ///         shape.isLocked ? AdornmentLabel(systemImage: "lock.fill") : nil
    ///     }
    public mutating func adornmentForEveryShape<A: Adornment>(
        _: A.Type,
        where appliesTo: @escaping @MainActor (AdornableKind) -> Bool = { _ in true },
        _ label: @escaping @MainActor (AnyShapeRecord, AdornmentContext) -> AdornmentLabel?
    ) {
        contribute(AdornmentContribution(A.self, appliesTo: appliesTo, label: label), to: ShapeAdornments.self, for: .any)
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
}

extension CanvasEditor {
    /// A shape's adornments as they're laid out now, in the order they're claimed; those left out
    /// for want of room aren't listed. Empty for a shape with none, without bounds, or not there,
    /// and while the canvas draws the shape as a skeleton (`drawsSkeleton(of:)`), which shows none.
    public func adornmentFrames(of id: ShapeID) -> [AdornmentFrame] {
        guard let state = adornmentState, let record = document[id] else { return [] }
        return state.frames(of: record)
    }

    /// What these shapes' adornments show changed other than through the document (an open lock
    /// fading): they're made again, the canvas redraws, and the select tool looks for a button
    /// under a still pointer (`canvasButtonsDidChange`).
    public func adornmentsDidChange(for ids: Set<ShapeID>) {
        guard let state = adornmentState else { return }
        state.forget(ids)
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
public struct AdornmentsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .adornments }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { AdornmentState(editor: $0) }
        registrar.overlay(AdornmentOverlay())
        // A clickable adornment is a canvas button: the select tool clicks it before anything else.
        registrar.canvasButtons(at: { editor, point in editor.adornmentState?.button(atViewPoint: point) },
                                click: { button, editor in editor.adornmentState?.click(button) })
        // Any other adornment is its shape's: a press, a hover or a double-click on it is on the
        // shape. Every one, a button too, is its shape's for a right-click.
        registrar.decorationHits { editor, point, include in editor.adornmentState?.shape(at: point, where: include) }
    }
}
