import Canvas

// What `canvas draw` needs from concerns it doesn't own, each an extension point with at most one
// contribution, from DrawLexicon, which binds them to the plugins that own the concerns
// (AutomationTests bind them to fixtures of their own): what a
// shape is called (DrawNames, Titles'), what an edge is (DrawEdges, Connections'), what's
// wrong with a shape drawn (DrawChecks, Validation's), and how text of a media type is written
// (DrawTextFormats, one for each media type). Without one, `draw` does without: no
// titles (a titled statement is `no_names`), no edges (`no_edges`), only the schemas' bounds
// checked, and text kept as written.

// MARK: Names

/// What shapes are called, for `canvas draw`, which names shapes by their titles: how a shape's
/// name is read, which of its kind's properties a title is written to, whether its kind works one
/// out by itself, and how a title is folded (as the plugin that owns titles folds them). Only the
/// sugar makes one (`registrar.drawNames`).
@MainActor
public struct DrawNaming {
    let name: @MainActor (AnyShapeRecord, Registry) -> String?
    let namingProperty: @MainActor (ShapeKind, Registry) -> String?
    let isDerived: @MainActor (ShapeKind, Registry) -> Bool
    let fold: @Sendable (String) -> String?
}

/// What names shapes for `canvas draw`: at most one plugin.
public enum DrawNames {}

extension DrawNames: KeyedExtensionPoint {
    public typealias Contribution = DrawNaming
    public static var owner: PluginID { .automation }
    public static func uniqueKeys(of _: DrawNaming, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawNaming, for _: ShapeTarget) -> String { label }
    static let label = "draw names"
}

// MARK: Edges

/// A connection a script asks for (`edge "A" -> "B"`), as the plugin that makes connections gets
/// it: between which shapes (either may be new in the script), aimed at which of their sides (none:
/// where the connection aims by itself), with a head at its start too (`<->`), and the attributes
/// the statement gives it, by key, as written (only keys the plugin declares). Its ends' names and
/// the edge as written are for messages.
///
/// An end may be a stand-in (Topology's: a shape that stands for another, which the script put beside
/// the shape it connects, because what the edge names is on another board): `fromStandsFor` and
/// `toStandsFor` are the kinds of what it stands for, none for an end that's the shape itself. A
/// connection to a stand-in is made as one to what it stands for would be, on the stand-in's own
/// sides.
public struct EdgeRequest: Hashable, Sendable {
    /// A side of a shape an end aims at.
    public enum Side: String, Hashable, Sendable, CaseIterable {
        case top, right, bottom, left
    }

    public var from: ShapeID
    public var to: ShapeID
    public var fromSide: Side?
    public var toSide: Side?
    public var bothHeads: Bool
    /// Each attribute the statement gives, by key: a word or a quoted string's text, or a JSON
    /// value's text, as written.
    public var attributes: [String: String]
    /// How a message names where it starts: `"Web"`, in quotes.
    public var fromName: String
    /// How a message names where it ends.
    public var toName: String
    /// The edge as written, ends and arrow: `"Web" -> "API"`.
    public var written: String
    /// The kinds of what its start stands for, when it's a stand-in; none otherwise.
    public var fromStandsFor: [ShapeKind]
    /// The kinds of what its end stands for, when it's a stand-in; none otherwise.
    public var toStandsFor: [ShapeKind]

    public init(from: ShapeID, to: ShapeID, fromSide: Side? = nil, toSide: Side? = nil, bothHeads: Bool = false,
                attributes: [String: String] = [:], fromName: String = "", toName: String = "", written: String = "",
                fromStandsFor: [ShapeKind] = [], toStandsFor: [ShapeKind] = []) {
        self.from = from
        self.to = to
        self.fromSide = fromSide
        self.toSide = toSide
        self.bothHeads = bothHeads
        self.attributes = attributes
        self.fromName = fromName
        self.toName = toName
        self.written = written
        self.fromStandsFor = fromStandsFor
        self.toStandsFor = toStandsFor
    }
}

/// What edges are, for `canvas draw`: the kind connections are (nil while nothing draws them), the
/// attribute keys an edge takes beside `from:` and `to:`, the sides of a kind an edge may leave by
/// and what it may carry from each (for `canvas kinds`), which shapes a connection joins, and how
/// one is made or changed. Only the sugar makes one (`registrar.drawEdges`).
@MainActor
public struct DrawEdging {
    let kind: @MainActor (Registry) -> ShapeKind?
    let attributes: [String]
    let sides: @MainActor (ShapeKind, Registry) -> [EdgeRequest.Side: [String]]
    let ends: @MainActor (AnyShapeRecord, Registry) -> (from: ShapeID, to: ShapeID)?
    let make: @MainActor (EdgeRequest, AnyShapeRecord?, ShapeContext) throws(AutomationError) -> AnyShapeRecord
}

/// What makes edges for `canvas draw`: at most one plugin.
public enum DrawEdges {}

extension DrawEdges: KeyedExtensionPoint {
    public typealias Contribution = DrawEdging
    public static var owner: PluginID { .automation }
    public static func uniqueKeys(of _: DrawEdging, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawEdging, for _: ShapeTarget) -> String { label }
    static let label = "draw edges"

    /// Attribute keys a script can write on an edge: none of the language's own (`from:`, `to:`,
    /// `style:`), none a draw result's row has of its own (`line`, `did`, `kind`: the row carries an
    /// edge's attributes beside them), and none twice.
    public static func check(_ registry: Registry) throws(RegistryError) {
        let rowKeys = Set(DrawChange.CodingKeys.allCases.map(\.stringValue))
        for edging in registry.contributions(to: DrawEdges.self).map(\.value) {
            var seen: Set<String> = []
            for key in edging.attributes {
                func refuse(_ reason: String) -> RegistryError { .invalid(point: "DrawEdges", reason: "attribute \(key): \(reason)") }
                guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "\"" }) else {
                    throw refuse("a key is a word a script can write before a colon")
                }
                guard !languageEdgeKeys.contains(key) else { throw refuse("the language keeps \(key): for itself") }
                guard !rowKeys.contains(key) else { throw refuse("a draw result's row has \(key) of its own") }
                guard seen.insert(key).inserted else { throw refuse("it's declared twice") }
            }
        }
    }
}

// MARK: Implications

/// What a script's attributes on a shape imply it also sets, for `canvas draw`: given the kind, the
/// shape as it is before the script (nil for a new one) and the settings the script writes, by
/// property key (what it changes, as JSON), the settings that go with them, which the script's own
/// win over. A concern's rule that one change comes with another in the same step (a note given a
/// schema becomes public), so what a person's one action does an agent's does. Only the sugar makes
/// one (`registrar.drawImplies`).
@MainActor
public struct DrawImplication {
    let implied: @MainActor (ShapeKind, AnyShapeRecord?, JSONObject, Registry) -> JSONObject
}

/// What attributes imply for `canvas draw`: any number of plugins, each asked in turn.
public enum DrawImplications {}

extension DrawImplications: ExtensionPoint {
    public typealias Contribution = DrawImplication
    public static var owner: PluginID { .automation }
    public static func summary(of _: DrawImplication, for _: ShapeTarget) -> String { "draw implies" }
}

// MARK: Checks

/// Something wrong with a shape a script drew (an error: it's invalid; or a warning), and the
/// property it's about, if one. `canvas draw` reports it with the statement's line, and draws
/// anyway.
public struct DrawIssue: Hashable, Sendable {
    public var message: String
    public var isError: Bool
    /// The property it's about (`title`), if it's about one.
    public var field: String?

    public init(_ message: String, isError: Bool = false, field: String? = nil) {
        self.message = message
        self.isError = isError
        self.field = field
    }
}

/// What's wrong with a shape, as it's about to be drawn, against the shapes of the board it's
/// drawn on (with the rest of the script). Only the sugar makes one (`registrar.drawChecks`).
@MainActor
public struct DrawCheck {
    let check: @MainActor (AnyShapeRecord, ShapeContext) -> [DrawIssue]
}

/// What checks shapes drawn for `canvas draw`: at most one plugin. Without one, a shape is checked
/// against its kind's schema (`registry.schemaViolations(of:)`).
public enum DrawChecks {}

extension DrawChecks: KeyedExtensionPoint {
    public typealias Contribution = DrawCheck
    public static var owner: PluginID { .automation }
    public static func uniqueKeys(of _: DrawCheck, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawCheck, for _: ShapeTarget) -> String { label }
    static let label = "draw checks"
}

// MARK: Text formats

/// A shape a text names: what to write for it.
public struct DrawTextShape: Hashable, Sendable {
    public let id: ShapeID
    /// What it's called (folded): its title, or, for a shape the script renames, the title it will have.
    public let title: String
}

/// What a text format may ask while it writes one string: the registry, the string's schema where it
/// is, and which shape a name stands for, found as the rest of the script finds one.
@MainActor
public struct DrawTextContext {
    public let registry: Registry
    /// The string's schema at its place, as its kind's schema declares it: its own members, and a
    /// `$ref` left unfollowed, so what's written beside the reference (an annotation a kind adds to
    /// a shared definition) is there to read.
    public let schema: JSONObject
    /// The shape whose attribute the string is, if it is a shape's: a new one has its id already, so
    /// a text that names a shape can refuse the shape itself (a type that is its own type).
    public let owner: ShapeID?
    let lookup: DrawTextLookup

    /// The shape called `name`, as a title names one in the script, among those `admits` takes (nil:
    /// it does; a string says why it doesn't, as a clause that follows the kind: `which can't be
    /// named here`): a shape the script draws, restates or renames to it (also one drawn further
    /// down); else the one on the board the run draws on; else the one on the board the window
    /// shows; else the one anywhere else in the file the app can show. Two or more in the same
    /// place are `ambiguous_title`; shapes the script deletes don't count; and one that's called
    /// that but none `admits` is `invalid_value`, saying why. What's thrown is a refusal as the
    /// script's own are, which the run says on the statement's line.
    public func shape(called name: String, admitting admits: @MainActor (AnyShapeRecord) -> String? = { _ in nil }) throws(AutomationError) -> DrawTextShape {
        try lookup.shape(called: name, admitting: { record, _ in admits(record) })
    }

    /// As above, for a rule that needs what the script writes on a shape it draws or restates: `admits`
    /// is also given the keys of the properties its statement writes, which its record, as the
    /// statement starts it, doesn't have yet (empty for a shape the script doesn't mention). A type
    /// the script draws with `schema:` is one, though its record has none until the statement is read.
    public func shape(called name: String,
                      admitting admits: @MainActor (AnyShapeRecord, _ writing: Set<String>) -> String?) throws(AutomationError) -> DrawTextShape {
        try lookup.shape(called: name, admitting: admits)
    }
}

/// How strings whose schema says `contentMediaType: mediaType` are written by a script: `write`
/// turns the text as the script wrote it into what the property keeps, or refuses it; `describes`
/// says in `canvas kinds` what the text takes (`<Title> names`, in brackets after the attribute's type). Only
/// the sugar makes one (`registrar.drawTextFormat`).
@MainActor
public struct DrawTextFormatting {
    let mediaType: String
    let describes: String
    let write: @MainActor (String, DrawTextContext) throws(AutomationError) -> String
}

/// How text of each media type is written in `canvas draw`: at most one plugin for each. A string
/// a script writes is written by the format of its schema's media type, wherever it is in the
/// value: a shape's attributes (and its styles'), an edge's own, and strings inside an object or a
/// list. A schema whose media type no format handles is kept as written.
public enum DrawTextFormats {}

extension DrawTextFormats: KeyedExtensionPoint {
    public typealias Contribution = DrawTextFormatting
    public static var owner: PluginID { .automation }
    public static func uniqueKeys(of format: DrawTextFormatting, for _: ShapeTarget) -> [AnyHashable] {
        [DrawPointKey(name: "draw text \(format.mediaType)")]
    }
    public static func summary(of format: DrawTextFormatting, for _: ShapeTarget) -> String { "draw text \(format.mediaType)" }

    /// A media type a schema can say, and words `canvas kinds` can show after it.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for format in registry.contributions(to: DrawTextFormats.self).map(\.value) {
            guard !format.mediaType.isEmpty else { throw .invalid(point: "DrawTextFormats", reason: "a media type can't be blank") }
            guard !format.describes.isEmpty else {
                throw .invalid(point: "DrawTextFormats", reason: "\(format.mediaType) says nothing of what it describes, which canvas kinds shows after the type")
            }
        }
    }
}

/// The one key each draw point's contribution claims: "draw names" in a conflict.
struct DrawPointKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { name }
}

// MARK: Sugar (what DrawLexicon writes)

extension PluginRegistrar {
    /// Names shapes for `canvas draw`: `name` is what a shape is called (folded, as `fold` folds a
    /// title; nil for none, or blank), `namingProperty` the property of a kind's schema a title is
    /// written to (nil: its shapes can't be given one), `isDerived` whether the kind works a name out
    /// by itself (`title { … }`; no shipped kind's), and `fold` how a title a script writes
    /// is folded before it's matched (nil: it's blank). At most one plugin names shapes.
    public mutating func drawNames(name: @escaping @MainActor (AnyShapeRecord, Registry) -> String?,
                                   namingProperty: @escaping @MainActor (ShapeKind, Registry) -> String?,
                                   isDerived: @escaping @MainActor (ShapeKind, Registry) -> Bool,
                                   fold: @escaping @Sendable (String) -> String?) {
        contribute(DrawNaming(name: name, namingProperty: namingProperty, isDerived: isDerived, fold: fold), to: DrawNames.self)
    }

    /// Adds settings to those a script writes on a shape (`DrawImplication`): `implied` gets the
    /// kind, the shape before the script (nil: new), the settings it writes (property key to value)
    /// and the registry, and returns the settings that go with them; a key the script wrote itself
    /// is its own. Any number of plugins.
    public mutating func drawImplies(_ implied: @escaping @MainActor (ShapeKind, AnyShapeRecord?, JSONObject, Registry) -> JSONObject) {
        contribute(DrawImplication(implied: implied), to: DrawImplications.self)
    }

    /// Makes edges for `canvas draw`: `kind` is what connections are (nil: nothing draws them now,
    /// and an edge is `no_edges`), `attributes` the keys an edge takes beside `from:` and `to:`,
    /// `sides` which sides of a kind an edge may leave by and what it carries from each (what
    /// `canvas kinds` lists), `ends` which shapes a connection starts and ends on (nil: not two), and
    /// `make` a connection as a request asks, not inserted: new (`existing` nil), or `existing`
    /// changed (only what the request names; itself when nothing would change). It throws what it
    /// can't do, with a reason (`no_channel`, `cannot_connect`, `invalid_value`); `draw` says which
    /// line. Its closure says so, `{ request, existing, shapes throws(AutomationError) in … }`, as a
    /// command's does. `shapes` is the board as the script leaves it, so either end may be new. At
    /// most one plugin makes edges.
    public mutating func drawEdges(kind: @escaping @MainActor (Registry) -> ShapeKind?, attributes: [String] = [],
                                   sides: @escaping @MainActor (ShapeKind, Registry) -> [EdgeRequest.Side: [String]],
                                   ends: @escaping @MainActor (AnyShapeRecord, Registry) -> (from: ShapeID, to: ShapeID)?,
                                   make: @escaping @MainActor (EdgeRequest, AnyShapeRecord?, ShapeContext) throws(AutomationError) -> AnyShapeRecord) {
        contribute(DrawEdging(kind: kind, attributes: attributes, sides: sides, ends: ends, make: make), to: DrawEdges.self)
    }

    /// Checks each shape `canvas draw` makes or changes, as the script leaves the board: what it
    /// finds is reported as warnings (an error too: the shape is drawn, invalid). At most one plugin
    /// checks shapes.
    public mutating func drawChecks(_ check: @escaping @MainActor (AnyShapeRecord, ShapeContext) -> [DrawIssue]) {
        contribute(DrawCheck(check: check), to: DrawChecks.self)
    }

    /// Writes the strings of a script whose schema says `contentMediaType: mediaType`: `write` gets
    /// the text as the script wrote it (its string's escapes undone) and what it may ask
    /// (`DrawTextContext`), and returns the text to keep, or throws a refusal, which `draw` says on
    /// the statement's line (its closure says so, `{ text, context throws(AutomationError) in … }`).
    /// `describes` is said after the attribute's type in `canvas kinds`, as `text (<Title> names)`.
    /// At most one plugin writes each media type.
    public mutating func drawTextFormat(mediaType: String, describes: String,
                                        write: @escaping @MainActor (String, DrawTextContext) throws(AutomationError) -> String) {
        contribute(DrawTextFormatting(mediaType: mediaType, describes: describes, write: write), to: DrawTextFormats.self)
    }
}

// MARK: Reading them

extension Registry {
    /// Whether a script can name a shape of `kind` at all: it has a property a title is written to,
    /// or a title worked out from what it is. A kind that can't be named can't be an end of an edge.
    @MainActor public func drawCanName(_ kind: ShapeKind) -> Bool {
        guard let naming = drawNaming else { return false }
        return naming.namingProperty(kind, self) != nil || naming.isDerived(kind, self)
    }

    /// What `settings` on a shape of `kind` imply (`drawImplies`), those a script wrote itself left alone.
    @MainActor func drawImplied(for kind: ShapeKind, before: AnyShapeRecord?, settings: JSONObject) -> JSONObject {
        var implied: JSONObject = [:]
        for implication in contributions(to: DrawImplications.self).map(\.value) {
            for (key, value) in implication.implied(kind, before, settings, self) where settings[key] == nil { implied[key] = value }
        }
        return implied
    }

    var drawNaming: DrawNaming? { contributions(to: DrawNames.self).first?.value }
    var drawEdging: DrawEdging? { contributions(to: DrawEdges.self).first?.value }
    var drawCheck: DrawCheck? { contributions(to: DrawChecks.self).first?.value }

    /// The formats that write text, by media type.
    var drawTextFormats: [String: DrawTextFormatting] {
        Dictionary(contributions(to: DrawTextFormats.self).map { ($0.value.mediaType, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
