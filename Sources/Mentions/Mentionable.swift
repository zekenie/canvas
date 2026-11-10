import AppKit
import Canvas
import Titles

/// How a kind's shapes are mentioned: one per kind, plus one for every kind
/// (`mentionableEveryShape`), which a kind's own takes the place of. A kind with none can't be
/// mentioned: text that names one of its shapes shows the name it holds, grayed.
public enum ShapeMentions {}

extension ShapeMentions: KeyedExtensionPoint {
    public typealias Contribution = MentionContribution
    public static var owner: PluginID { .mentions }
    public static func uniqueKeys(of _: MentionContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: MentionContribution, for target: ShapeTarget) -> String {
        "mentionable → " + (target == .any ? "every shape" : "\(target)")
    }

    /// No mention text takes a length or a pattern (`MentionTextFormat.checkBounds`).
    public static func check(_ registry: Registry) throws { try MentionTextFormat.checkBounds(in: registry) }
}

/// What following a mention of a kind's shape does: a double-click on its pill, on the canvas or in
/// the text, and Go to in the text's menu.
public enum MentionFollowing: Sendable {
    /// Goes to the shape: shows its board, selects it and brings it into view (`goTo`).
    case goesTo
    /// Goes into it: goes to it, then opens it, as a double-click on it would (`goInto`): a
    /// subboard shows its board. One step back either way.
    case opens
}

/// What `ShapeMentions` keeps for a kind: how its shapes are called, and with what symbol, detail
/// and tint, and what following a mention of one does; for every kind, which kinds (`where`). Only
/// the sugar below makes one.
@MainActor
public struct MentionContribution {
    let applies: (@MainActor (any ShapeDefinition) -> Bool)?
    let label: (@MainActor (AnyShapeRecord) -> String?)?
    let untitled: (@MainActor (AnyShapeRecord) -> String?)?
    let symbol: (@MainActor (AnyShapeRecord) -> String?)?
    let detail: (@MainActor (AnyShapeRecord) -> String?)?
    let tint: (@MainActor (AnyShapeRecord) -> NSColor?)?
    let following: MentionFollowing

    init<P: ShapeProps>(_: P.Type, label: (@MainActor (ShapeRecord<P>) -> String?)?, untitled: (@MainActor (ShapeRecord<P>) -> String?)?,
                        symbol: (@MainActor (ShapeRecord<P>) -> String?)?, detail: (@MainActor (ShapeRecord<P>) -> String?)?,
                        tint: (@MainActor (ShapeRecord<P>) -> NSColor?)?, following: MentionFollowing) {
        applies = nil
        self.following = following
        self.label = Self.erased(label)
        self.untitled = Self.erased(untitled)
        self.symbol = Self.erased(symbol)
        self.detail = Self.erased(detail)
        self.tint = Self.erased(tint)
    }

    /// A closure over a kind's typed shapes, over any shape: nil for another kind's.
    private static func erased<P: ShapeProps, T>(_ make: (@MainActor (ShapeRecord<P>) -> T?)?) -> (@MainActor (AnyShapeRecord) -> T?)? {
        guard let make else { return nil }
        return { record in record.typed(as: P.self).flatMap { make($0) } }
    }

    init(everyShape applies: @escaping @MainActor (any ShapeDefinition) -> Bool) {
        self.applies = applies
        label = nil
        untitled = nil
        symbol = nil
        detail = nil
        tint = nil
        following = .goesTo
    }
}

/// How a shape looks where it's mentioned: its pill, its row in the picker. Derived from the shape
/// alone, never stored.
public struct MentionAppearance: Hashable, Sendable {
    /// One line, never blank: the kind's `label`, else the shape's title, else the kind's
    /// `untitled`, else "Untitled" and the kind's name.
    public var label: String
    /// Whether `label` is "Untitled" and the kind's name, which says nothing of the shape.
    public var isPlaceholder: Bool
    /// An SF Symbol: the kind's `symbol`, else its label's (`registry.label(of:)`).
    public var systemImage: String
    /// What the kind is called: its label ("Note", `registry.label(of:)`).
    public var kindName: String
    /// Said beside the label in the picker: the kind's `detail`, else its name.
    public var detail: String
    /// The symbol's color on neutral surfaces; nil for none. A dynamic color follows light and dark.
    public var tint: NSColor?
    /// For a row's (`PartName`), what leads it as the row draws it (an endpoint's method in its chip, `POST`), which a pill for
    /// the row draws before its name; none for a shape's.
    public var lead: PartLead

    public init(label: String, isPlaceholder: Bool = false, systemImage: String, kindName: String, detail: String, tint: NSColor? = nil,
                lead: PartLead = .none) {
        self.label = label
        self.isPlaceholder = isPlaceholder
        self.systemImage = systemImage
        self.kindName = kindName
        self.detail = detail
        self.tint = tint
        self.lead = lead
    }
}

/// What a mention of a shape shows now.
public enum MentionResolution: Hashable, Sendable {
    /// The shape is on the board, and can be mentioned: as it looks.
    case live(MentionAppearance)
    /// No shape has that id on the board (deleted, or never here): the name the mention holds, dashed.
    case missing
    /// The shape is in the file but can't be mentioned (kept aside, its kind isn't mentionable, or
    /// it's on a board the app can't show): as missing.
    case unavailable

    /// The appearance of a live one.
    public var appearance: MentionAppearance? {
        if case .live(let appearance) = self { appearance } else { nil }
    }

    public var isLive: Bool { appearance != nil }

    /// What a mention shows: a live target's label, else the name it holds, else, holding none, what
    /// its tooltip says ("Deleted", "Not available").
    @MainActor public func shownLabel(stored: String) -> String {
        if let appearance { return appearance.label }
        return stored.isEmpty ? help ?? "" : stored
    }

    /// Why a mention isn't live, for a tooltip: nil while it is.
    @MainActor var help: String? {
        switch self {
        case .live: nil
        case .missing: MentionStyle.missingHelp
        case .unavailable: MentionStyle.unavailableHelp
        }
    }
}

// MARK: Sugar

extension ShapeRegistrar {
    /// Its shapes can be mentioned. Each closure reads only the shape, as a title does, so a pill
    /// changes only when its shape does. The label is `label`, else the shape's title (Titles'
    /// `registry.title(of:)`, named or derived), else `untitled`, else "Untitled" and the kind's
    /// label ("Untitled Note"), each on one line, blank counting as none. `symbol` and `tint` default
    /// to the kind's label's (`registry.label(of:)`), `detail` to the kind's name; a `tint` that
    /// answers nil for a shape leaves it its kind's, so it can't untint one (a color the shape has of
    /// its own, `editor.tint(of:)`, comes before it). `following` says what
    /// following a mention does: go to the shape, or into it (`.opens`: a subboard enters its
    /// board). An `untitled` that reads the shape's own mention text leaves every other shape's
    /// name out of it (`firstLine`, where each mention is "@…"): a mention holds its target's name
    /// as written, so names made of names would take each other in and grow.
    ///
    ///     note.mentionable(untitled: { $0.props.text.firstLine })
    ///     sub.mentionable(following: .opens)
    public mutating func mentionable(label: (@MainActor (ShapeRecord<Definition.Props>) -> String?)? = nil,
                                     untitled: (@MainActor (ShapeRecord<Definition.Props>) -> String?)? = nil,
                                     symbol: (@MainActor (ShapeRecord<Definition.Props>) -> String?)? = nil,
                                     detail: (@MainActor (ShapeRecord<Definition.Props>) -> String?)? = nil,
                                     tint: (@MainActor (ShapeRecord<Definition.Props>) -> NSColor?)? = nil,
                                     following: MentionFollowing = .goesTo) {
        contribute(MentionContribution(Definition.Props.self, label: label, untitled: untitled, symbol: symbol, detail: detail, tint: tint,
                                       following: following),
                   to: ShapeMentions.self)
    }
}

extension PluginRegistrar {
    /// Another plugin's kind can be mentioned, with the same options as `mentionable` on
    /// a kind's own registrar.
    public mutating func mentionable<P: ShapeProps>(_: P.Type, label: (@MainActor (ShapeRecord<P>) -> String?)? = nil,
                                                    untitled: (@MainActor (ShapeRecord<P>) -> String?)? = nil,
                                                    symbol: (@MainActor (ShapeRecord<P>) -> String?)? = nil,
                                                    detail: (@MainActor (ShapeRecord<P>) -> String?)? = nil,
                                                    tint: (@MainActor (ShapeRecord<P>) -> NSColor?)? = nil,
                                                    following: MentionFollowing = .goesTo) {
        contribute(MentionContribution(P.self, label: label, untitled: untitled, symbol: symbol, detail: detail, tint: tint,
                                       following: following),
                   to: ShapeMentions.self, for: .kind(P.kind))
    }

    /// Every kind `where` picks by its definition can be mentioned, as the defaults have it: a
    /// composition that wants every kind mentionable. A kind's own `mentionable` takes its place.
    public mutating func mentionableEveryShape(where applies: @escaping @MainActor (any ShapeDefinition) -> Bool = { _ in true }) {
        contribute(MentionContribution(everyShape: applies), to: ShapeMentions.self, for: .any)
    }
}

// MARK: Reading it

/// How a kind is mentioned: its contribution (nil for a kind that isn't mentionable), and what its
/// shapes default to, its kind's label, symbol and tint. Worked out once per kind by whoever asks
/// often (`MentionState`).
struct MentionKindDefaults {
    let contribution: MentionContribution?
    let name: String
    let symbol: String
    let tint: NSColor?

    @MainActor
    init(_ kind: ShapeKind, in registry: Registry) {
        contribution = registry.mentionContribution(for: kind)
        let label = contribution == nil ? nil : registry.label(of: kind)
        name = label?.name ?? kind.rawValue
        symbol = label?.systemImage ?? "square.dashed"
        tint = label?.tint
    }
}

extension Registry {
    /// Whether a kind's shapes can be mentioned.
    public func isMentionable(_ kind: ShapeKind) -> Bool { mentionContribution(for: kind) != nil }

    /// The contribution that says how a kind is mentioned: its own, else every kind's if it picks
    /// this kind.
    func mentionContribution(for kind: ShapeKind) -> MentionContribution? {
        let contributions = contributions(to: ShapeMentions.self, for: kind)
        guard let first = contributions.first else { return nil }
        guard let applies = first.applies else { return first }
        guard let definition = definition(for: kind), applies(definition) else { return nil }
        return first
    }

    /// How a shape is mentioned now; nil if it's kept aside, or its kind isn't mentionable. Reads
    /// only the record, so it works on a record from any board. Its tint is the kind's (or the one
    /// the kind says for the shape): the editor's `mentionAppearance(of:)` adds the shape's own.
    public func mentionAppearance(of shape: AnyShapeRecord) -> MentionAppearance? {
        guard !shape.isOpaque else { return nil }
        return mentionAppearance(of: shape, defaults: MentionKindDefaults(shape.kind, in: self))
    }

    /// The same, with the kind's contribution and defaults worked out already, and the tint a plugin
    /// gave the shape (`editor.ownTint(of:)`), if the caller has the editor: a color the shape has of
    /// its own comes first, then a `tint` the kind says for the shape, then the kind's.
    func mentionAppearance(of shape: AnyShapeRecord, defaults: MentionKindDefaults, shapeTint: NSColor? = nil) -> MentionAppearance? {
        guard !shape.isOpaque, let contribution = defaults.contribution else { return nil }
        let label: String, isPlaceholder: Bool
        if let own = oneLine(contribution.label?(shape)) {
            (label, isPlaceholder) = (own, false)
        } else if let title = oneLine(title(of: shape)) {
            (label, isPlaceholder) = (title, false)
        } else if let untitled = oneLine(contribution.untitled?(shape)) {
            (label, isPlaceholder) = (untitled, false)
        } else {
            (label, isPlaceholder) = ("Untitled " + defaults.name, true)
        }
        return MentionAppearance(label: label, isPlaceholder: isPlaceholder,
                                 systemImage: oneLine(contribution.symbol?(shape)) ?? defaults.symbol,
                                 kindName: defaults.name,
                                 detail: oneLine(contribution.detail?(shape)) ?? defaults.name,
                                 tint: shapeTint ?? contribution.tint?(shape) ?? defaults.tint)
    }

    /// What a mention of `target` shows now: live, with its appearance (a shape that is all its one row as that row:
    /// `MentionResolution.whole`), when `lookup` finds it and it can be mentioned; unavailable when it finds it and it can't
    /// (kept aside, or of a kind that isn't mentionable); missing when it doesn't.
    public func mentionResolution(of target: ShapeID, lookup: (ShapeID) -> AnyShapeRecord?) -> MentionResolution {
        guard let record = lookup(target) else { return .missing }
        return MentionResolution.whole(record, shape: mentionAppearance(of: record), in: self)
    }

    /// What a mention of a row, or of a shape as a whole (part nil), shows now, as `mentionResolution(of:lookup:)` has the shape:
    /// a row of a shape `lookup` finds is live while the shape has it (`MentionResolution.row`), missing once it doesn't.
    public func mentionResolution(of target: PartAddress, lookup: (ShapeID) -> AnyShapeRecord?) -> MentionResolution {
        guard let part = target.part else { return mentionResolution(of: target.shape, lookup: lookup) }
        guard let record = lookup(target.shape) else { return .missing }
        return MentionResolution.row(part, of: record, shape: mentionAppearance(of: record), in: self)
    }
}

extension MentionResolution {
    /// What a mention of row `part` of `record` shows, given how the shape shows (`shape`, nil when it can't be mentioned): live
    /// with the row's appearance (`MentionAppearance.row`) while the shape has the row; missing once it hasn't (the row deleted,
    /// or moved away: its pill dashed, by the name it holds); unavailable with the shape.
    @MainActor
    public static func row(_ part: PartID, of record: AnyShapeRecord, shape: MentionAppearance?, in registry: Registry) -> MentionResolution {
        guard let shape else { return .unavailable }
        guard let row = registry.parts(of: record)?.first(where: { $0.id == part }) else { return .missing }
        return .live(MentionAppearance.row(row, of: shape))
    }
}

extension MentionResolution {
    /// What a mention of `record` as a whole shows, given how the shape shows (`shape`, nil when it can't be mentioned): a shape
    /// that is all its one row (`PartName.isItsShape`: an endpoint taken out of its API) as that row, as a mention of the row
    /// shows (`MentionAppearance.row`: its method in its chip and its path), so a mention of it looks one way, however it was
    /// written and wherever the endpoint is; any other as itself; unavailable with no appearance.
    @MainActor
    public static func whole(_ record: AnyShapeRecord, shape: MentionAppearance?, in registry: Registry) -> MentionResolution {
        whole(shape: shape, parts: shape != nil && registry.isAllItsOneRow(record.kind) ? registry.parts(of: record) : nil)
    }

    /// The same, given the shape's parts (its rows) read already.
    static func whole(shape: MentionAppearance?, parts: [PartName]?) -> MentionResolution {
        guard let shape else { return .unavailable }
        if let parts, parts.count == 1, parts[0].isItsShape { return .live(MentionAppearance.row(parts[0], of: shape)) }
        return .live(shape)
    }
}

extension MentionAppearance {
    /// How a row shows where it's mentioned: by its full name, an endpoint's method and full path ("POST /orders/{id}/refunds"),
    /// and a row that doesn't stand alone with its shape's name before it ("orders.customer_id", as draw names one and the picker
    /// finds one); its lead (a method's chip) before the name, else its lead's symbol, else its shape's; its kind word
    /// ("Endpoint") its kind's name; in its shape's tint.
    public static func row(_ part: PartName, of shape: MentionAppearance) -> MentionAppearance {
        let symbol: String = if case .symbol(let name) = part.lead { name } else { shape.systemImage }
        return MentionAppearance(label: part.standsAlone ? part.name : shape.label + "." + part.name, systemImage: symbol,
                                 kindName: part.kindWord, detail: part.kindWord, tint: shape.tint, lead: part.lead)
    }
}

extension CanvasEditor {
    /// How a shape is mentioned now, as `registry.mentionAppearance(of:)` has it, its symbol in the
    /// tint the shape has of its own where a plugin gives it one (`ownTint(of:)`: a note's color),
    /// else the kind's: what a list that shows the shape's symbol on a neutral surface takes.
    public func mentionAppearance(of shape: AnyShapeRecord) -> MentionAppearance? {
        guard !shape.isOpaque else { return nil }
        return registry.mentionAppearance(of: shape, defaults: MentionKindDefaults(shape.kind, in: registry), shapeTint: ownTint(of: shape))
    }
}

/// A name as everything that shows it reads it: on one line, each run of whitespace (line breaks
/// included) folded into a space; nil when that leaves nothing, so a blank name is none. A name
/// that's plain ASCII with single spaces between words, as most are, is returned as it is.
func oneLine(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    var isClean = true, afterSpace = true
    for byte in text.utf8 {
        if byte == 0x20 {
            if afterSpace {
                isClean = false
                break
            }
            afterSpace = true
        } else if byte < 0x20 || byte >= 0x80 {
            isClean = false                       // a control character, or a character whose spaces aren't ASCII's
            break
        } else {
            afterSpace = false
        }
    }
    if isClean, !afterSpace { return text }
    let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return folded.isEmpty ? nil : folded
}
