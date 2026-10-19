import Canvas
import CanvasRPC
import Queries

// What `canvas draw` needs from concerns it doesn't own, each an extension point with at most one
// contribution, from the plugins that own the concerns (AutomationTests bind them to fixtures of
// their own): what a shape is called (DrawNames, Titles'), what an edge is (DrawEdges,
// Connections'), what tells two edges of one pair apart (DrawEdgeIdentities, one for each property,
// Types' `is`), what's wrong with a shape drawn and which other shapes a run's writes reach (DrawChecks,
// Validation's), how text of a
// media type is written (DrawTextFormats, one for each media type, Mentions' for mention text),
// how a value a script writes joins what a shape holds (DrawValueWriters, one for each property),
// what a shape with no title is called for the pill that stands for it (DrawLabels, Mentions'), what
// each row of a run reports (DrawReports, Types') and how shapes are grouped (DrawGroups, Grouping's).
// Without one, `draw` does without: no titles (a titled statement is `no_names`), no edges
// (`no_edges`), no groups (`group` and `ungroup` are `no_groups`), only the schemas' bounds checked,
// text kept as written and a value replacing what the shape holds.

// MARK: Names

/// What shapes are called, for `canvas draw`, which names shapes by their titles: how a shape's
/// name is read, which of its kind's properties a title is written to, whether its kind works one
/// out by itself, and how a title is folded (as the plugin that owns titles folds them). Only the
/// sugar makes one (`registrar.drawNames`).
@MainActor
public struct DrawNaming {
    public let name: @MainActor (AnyShapeRecord, Registry) -> String?
    let namingProperty: @MainActor (ShapeKind, Registry) -> String?
    let isDerived: @MainActor (ShapeKind, Registry) -> Bool
    public let fold: @Sendable (String) -> String?
}

/// What names shapes for `canvas draw`: at most one plugin.
public enum DrawNames {}

extension DrawNames: KeyedExtensionPoint {
    public typealias Contribution = DrawNaming
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of _: DrawNaming, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawNaming, for _: ShapeTarget) -> String { label }
    static let label = "draw names"
}

// MARK: Labels

/// What a shape with no title is called where a pill stands for it, as `canvas draw` makes one for a far note an edge ends at:
/// the name the plugin that names shapes in words gives it (Mentions': its first line, else its values), which a title
/// would be, if it had one. Only the sugar makes one (`registrar.drawLabels`).
@MainActor
public struct DrawLabeling {
    let label: @MainActor (AnyShapeRecord, Registry) -> String?
}

/// What names a shape that has no title for the pill that stands for it: at most one plugin.
public enum DrawLabels {}

extension DrawLabels: KeyedExtensionPoint {
    public typealias Contribution = DrawLabeling
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of _: DrawLabeling, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawLabeling, for _: ShapeTarget) -> String { label }
    static let label = "draw labels"
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
    /// The connections already joining the pair, for a maker that draws a second apart from the first
    /// (`registry.drawConnection(beside:)`); nil: the maker reads them.
    public var beside: [ShapeID]?

    public init(from: ShapeID, to: ShapeID, fromSide: Side? = nil, toSide: Side? = nil, bothHeads: Bool = false,
                attributes: [String: String] = [:], fromName: String = "", toName: String = "", written: String = "",
                fromStandsFor: [ShapeKind] = [], toStandsFor: [ShapeKind] = [], beside: [ShapeID]? = nil) {
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
        self.beside = beside
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
    let make: @MainActor (EdgeRequest, AnyShapeRecord?, ShapeContext) throws(DrawError) -> AnyShapeRecord
}

/// What makes edges for `canvas draw`: at most one plugin.
public enum DrawEdges {}

extension DrawEdges: KeyedExtensionPoint {
    public typealias Contribution = DrawEdging
    public static var owner: PluginID { .drawEngine }
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
                guard isScriptKey(key) else {
                    throw refuse("a key is a word a script can write before a colon")
                }
                guard !languageEdgeKeys.contains(key) else { throw refuse("the language keeps \(key): for itself") }
                guard !rowKeys.contains(key) else { throw refuse("a draw result's row has \(key) of its own") }
                guard seen.insert(key).inserted else { throw refuse("it's declared twice") }
            }
        }
    }
}

// MARK: Edge identities

/// A property of the edge kind that tells two edges of one pair apart (an arrow's `is`): an edge is its
/// pair and, for a statement that writes some of these, what it writes of them. The plugin that owns the
/// property names it, so whatever makes edges names none; one the edge kind lacks (no plugin gave it the
/// property) tells nothing apart. Only the sugar makes one (`registrar.drawEdgeIdentity`).
public struct DrawEdgeIdentifying {
    let key: String
}

/// What tells the edges of one pair apart for `canvas draw`: at most one plugin for each property key,
/// read in plugin order.
public enum DrawEdgeIdentities {}

extension DrawEdgeIdentities: KeyedExtensionPoint {
    public typealias Contribution = DrawEdgeIdentifying
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of identity: DrawEdgeIdentifying, for _: ShapeTarget) -> [AnyHashable] {
        [DrawPointKey(name: "draw edge identity \(identity.key)")]
    }
    public static func summary(of identity: DrawEdgeIdentifying, for _: ShapeTarget) -> String { "draw edge identity \(identity.key)" }

    /// A key a script can write before a colon, none of the language's own, and none of the maker's
    /// attributes: an identity key is a property of the edge kind's schema (checked per run, against its
    /// vocabulary).
    public static func check(_ registry: Registry) throws(RegistryError) {
        let attributes = Set(registry.contributions(to: DrawEdges.self).flatMap(\.value.attributes))
        for key in registry.contributions(to: DrawEdgeIdentities.self).map(\.value.key) {
            func refuse(_ reason: String) -> RegistryError { .invalid(point: "DrawEdgeIdentities", reason: "identity \(key): \(reason)") }
            guard isScriptKey(key) else {
                throw refuse("a key is a word a script can write before a colon")
            }
            guard !languageEdgeKeys.contains(key) else { throw refuse("the language keeps \(key): for itself") }
            guard !attributes.contains(key) else { throw refuse("it's one of the maker's attributes, and an identity key is a property of the kind's schema") }
        }
    }
}

// MARK: Checks

/// Something wrong with a shape a script drew (an error: it's invalid; or a warning), or something it still
/// needs, and the property it's about, if one. `canvas draw` reports it with the statement's line, and draws
/// anyway. What a shape still needs is no warning of a shape the script wrote (its row's `problems` say it);
/// of one the script did not write, a run says it as it says any other issue it brings.
public struct DrawIssue: Hashable, Sendable {
    /// How much it matters.
    public enum Level: Hashable, Sendable {
        /// The shape is flagged, and as valid as it was.
        case warning
        /// The shape is invalid.
        case error
        /// The shape still needs something: not flagged, not invalid.
        case incomplete
    }

    public var message: String
    public var level: Level
    /// The property it's about (`title`), if it's about one.
    public var field: String?

    public init(_ message: String, level: Level, field: String? = nil) {
        self.message = message
        self.level = level
        self.field = field
    }

    /// A warning, or (`isError`) an error.
    public init(_ message: String, isError: Bool = false, field: String? = nil) {
        self.init(message, level: isError ? .error : .warning, field: field)
    }

    public var isError: Bool { level == .error }
    public var isIncomplete: Bool { level == .incomplete }
}

/// What's wrong with a shape, as it's about to be drawn, against the shapes of the board it's
/// drawn on (with the rest of the script); and, of what a run wrote, which other shapes to look at
/// (`touched`: those whose issues the writes may change though the run did not write them, on any board,
/// given what the transaction did so far, `Transaction.pending`, and its shapes). `rest` is how to see
/// the issues a run brought to more shapes than it says (a command to ask). Only the sugar makes one
/// (`registrar.drawChecks`).
@MainActor
public struct DrawCheck {
    let check: @MainActor (AnyShapeRecord, ShapeContext) -> [DrawIssue]
    let touched: (@MainActor (ChangeSet, ShapeContext) -> Set<ShapeID>)?
    let rest: String?
}

/// What checks shapes drawn for `canvas draw`: at most one plugin. Without one, a shape is checked
/// against its kind's schema (`registry.schemaViolations(of:)`).
public enum DrawChecks {}

extension DrawChecks: KeyedExtensionPoint {
    public typealias Contribution = DrawCheck
    public static var owner: PluginID { .drawEngine }
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

    /// A service of the editor the script draws on (Types' index, say), for a text that must read what only a
    /// service knows: nil without its plugin. Read-only use: a format writes nothing but its string.
    public func service<S: EditorService>(_ type: S.Type) -> S? { lookup.editor.service(type) }

    /// The shape called `name`, as a title names one in the script, among those `admits` takes (nil:
    /// it does; a string says why it doesn't, as a clause that follows the kind: `which can't be
    /// named here`): a shape the script draws, restates or renames to it (also one drawn further
    /// down); else the one on the board the run draws on; else the one on the board the window
    /// shows; else the one anywhere else in the file the app can show. Two or more in the same
    /// place are `ambiguous_title`; shapes the script deletes don't count; and one that's called
    /// that but none `admits` is `invalid_value`, saying why. What's thrown is a refusal as the
    /// script's own are, which the run says on the statement's line.
    public func shape(called name: String, admitting admits: @MainActor (AnyShapeRecord) -> String? = { _ in nil }) throws(DrawError) -> DrawTextShape {
        try lookup.shape(called: name, admitting: { record, _ in admits(record) })
    }

    /// As above, for a rule that needs what the script writes on a shape it draws or restates: `admits`
    /// is also given the keys of the properties its statement writes, which its record, as the
    /// statement starts it, doesn't have yet (empty for a shape the script doesn't mention). A type
    /// the script draws with `schema:` is one, though its record has none until the statement is read.
    public func shape(called name: String,
                      admitting admits: @MainActor (AnyShapeRecord, _ writing: Set<String>) -> String?) throws(DrawError) -> DrawTextShape {
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
    let write: @MainActor (String, DrawTextContext) throws(DrawError) -> String
}

/// How text of each media type is written in `canvas draw`: at most one plugin for each. A string
/// a script writes is written by the format of its schema's media type, wherever it is in the
/// value: a shape's attributes (and its styles'), an edge's own, and strings inside an object or a
/// list. A schema whose media type no format handles is kept as written.
public enum DrawTextFormats {}

extension DrawTextFormats: KeyedExtensionPoint {
    public typealias Contribution = DrawTextFormatting
    public static var owner: PluginID { .drawEngine }
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

// MARK: Reports

/// What a plugin says of a shape a run made, changed or restated, beside its validation issues: warnings
/// about what its statement wrote, and the shape's `problems` (what its values still need and what is
/// wrong with them), which the shape's row carries.
public struct DrawShapeReport: Sendable {
    public var warnings: [DrawIssue]
    public var problems: [ShapeProblem]
    /// Members the shape's row carries, by key, flat beside its own (`is`, say): only the keys the plugin declared
    /// (`registrar.drawReports(members:)`); any other is left out.
    public var members: [String: JSONValue]

    public init(warnings: [DrawIssue] = [], problems: [ShapeProblem] = [], members: [String: JSONValue] = [:]) {
        self.warnings = warnings
        self.problems = problems
        self.members = members
    }
}

/// How a plugin reports on a shape: `written` is what the statement wrote for each of its properties, by
/// key, after the value writers wrote them and before they joined what the shape held (nil for a shape
/// whose statement changed nothing: a restated one is reported on, never warned about), and `shapes` the
/// board as the script leaves it; `bothHeads` is whether the statement of a connection wrote `<->` (false for any
/// other shape). Only the sugar makes one (`registrar.drawReports`).
@MainActor
public struct DrawReporting {
    /// The keys of the members the report may add to a row.
    let members: [String]
    let report: @MainActor (AnyShapeRecord, _ written: JSONObject?, ShapeContext, _ bothHeads: Bool) -> DrawShapeReport
}

/// What reports on each shape and edge a run made, changed or restated, as the script leaves the board:
/// at most one plugin.
public enum DrawReports {}

extension DrawReports: KeyedExtensionPoint {
    public typealias Contribution = DrawReporting
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of _: DrawReporting, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of reporting: DrawReporting, for _: ShapeTarget) -> String {
        reporting.members.isEmpty ? label : label + " members " + reporting.members.joined(separator: ", ")
    }
    static let label = "draw reports"

    /// The members a report adds to a row are words a script reads beside the row's own: none blank, none twice,
    /// none the row's own (`line`, `did`, `kind`, `problems`), none an attribute an edge's row carries
    /// (`DrawEdges`), so a clash is a registry error and not a value lost.
    public static func check(_ registry: Registry) throws(RegistryError) {
        let rowKeys = Set(DrawChange.CodingKeys.allCases.map(\.stringValue))
        let attributes = Set(registry.contributions(to: DrawEdges.self).flatMap { $0.value.attributes })
        for reporting in registry.contributions(to: DrawReports.self).map(\.value) {
            var seen: Set<String> = []
            for key in reporting.members {
                func refuse(_ reason: String) -> RegistryError { .invalid(point: "DrawReports", reason: "member \(key): \(reason)") }
                guard isScriptKey(key) else {
                    throw refuse("a key is a word a row can carry")
                }
                guard !rowKeys.contains(key) else { throw refuse("a draw result's row has \(key) of its own") }
                guard !attributes.contains(key) else { throw refuse("an edge's row carries \(key) as an attribute") }
                guard seen.insert(key).inserted else { throw refuse("it's declared twice") }
            }
        }
    }
}

// MARK: Value writers

/// How a property's value a script writes is made what the shape keeps, for a property whose owner
/// says so: `write` turns the value as written into what it stores (names into ids: it may ask
/// `context.shape(called:)`, as a text format does), and `merge` joins it with what the shape holds
/// now (nil for a new shape, or one without it). Only the sugar makes one (`registrar.drawValueWriter`).
@MainActor
public struct DrawValueWriting {
    let key: String
    let write: @MainActor (JSONValue, DrawTextContext) throws(DrawError) -> JSONValue
    let merge: @MainActor (_ written: JSONValue, _ held: JSONValue?) -> JSONValue
}

/// What writes a property's values in `canvas draw`: at most one plugin for each property key.
public enum DrawValueWriters {}

extension DrawValueWriters: KeyedExtensionPoint {
    public typealias Contribution = DrawValueWriting
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of writer: DrawValueWriting, for _: ShapeTarget) -> [AnyHashable] {
        [DrawPointKey(name: "draw value \(writer.key)")]
    }
    public static func summary(of writer: DrawValueWriting, for _: ShapeTarget) -> String { "draw value \(writer.key)" }

    /// A key a script can write: not blank.
    public static func check(_ registry: Registry) throws(RegistryError) {
        for writer in registry.contributions(to: DrawValueWriters.self).map(\.value) where writer.key.isEmpty {
            throw .invalid(point: "DrawValueWriters", reason: "a property key can't be blank")
        }
    }
}

// MARK: Groups

/// How shapes are grouped, for `canvas draw`'s `group` and `ungroup`. The plugin that owns what a group is writes them: `group` is
/// handed the shapes a statement names (two or more, each once, all on the board the run draws on, in the order written) and the
/// run's transaction, and puts exactly those shapes in one group of their own; `ungroup`, the shapes it names (one or more, each
/// once), and leaves each in no group. Each writes through the transaction, a read-only shape refusing the write as it refuses any
/// (the run says which, `read_only`), and says whether it changed anything: a group already as asked, or shapes already in none,
/// are no change, and the statement's row says `unchanged`. A run applies the statements in script order, once every shape and
/// edge it draws is in the transaction, so a shape the script draws can be named. Draw knows no meaning of a group: not what holds
/// one, nor which of the shapes are in one. Only the sugar makes one (`registrar.drawGroups`).
@MainActor
public struct DrawGrouping {
    let group: @MainActor (_ shapes: [ShapeID], _ transaction: inout Transaction) -> Bool
    let ungroup: @MainActor (_ shapes: [ShapeID], _ transaction: inout Transaction) -> Bool
}

/// What groups shapes for `canvas draw`: at most one plugin.
public enum DrawGroups {}

extension DrawGroups: KeyedExtensionPoint {
    public typealias Contribution = DrawGrouping
    public static var owner: PluginID { .drawEngine }
    public static func uniqueKeys(of _: DrawGrouping, for _: ShapeTarget) -> [AnyHashable] { [DrawPointKey(name: label)] }
    public static func summary(of _: DrawGrouping, for _: ShapeTarget) -> String { label }
    static let label = "draw groups"
}

/// The one key each draw point's contribution claims: "draw names" in a conflict.
struct DrawPointKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { name }
}

/// Whether a key is a word a script can write before a colon: what every point that takes keys a script
/// writes (an edge's attributes and identity, a report's members) checks.
func isScriptKey(_ key: String) -> Bool {
    !key.isEmpty && !key.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "\"" })
}

// MARK: Sugar (what the concerns write)

extension PluginRegistrar {
    /// Reports on each shape and edge `canvas draw` makes, changes or restates, once the script's shapes
    /// are all in the transaction (so a type drawn further down is read): `problems` go on the shape's
    /// row, `warnings` among the run's, with the statement's line, and `members` (the keys declared here)
    /// beside the row's own. It is also asked of each connection a run deletes, with the record as it was,
    /// which the transaction no longer has: for its members and warnings only. At most one plugin reports.
    public mutating func drawReports(members: [String] = [],
                                     _ report: @escaping @MainActor (AnyShapeRecord, _ written: JSONObject?, ShapeContext, _ bothHeads: Bool) -> DrawShapeReport) {
        contribute(DrawReporting(members: members, report: report), to: DrawReports.self)
    }

    /// Writes the values of the property `key` in `canvas draw`: `write` gets the value as the script
    /// wrote it (JSON) and what it may ask (`DrawTextContext`), and returns what the property stores,
    /// or throws a refusal, which `draw` says on the statement's line; `merge` joins that with what the
    /// shape holds now (`held`: nil for a new shape, or one without a value), and its result is what
    /// the shape is set to, so a script run again changes nothing. Without a writer a value replaces
    /// what the shape holds. At most one plugin writes each property.
    public mutating func drawValueWriter(for key: PropertyKey,
                                         write: @escaping @MainActor (JSONValue, DrawTextContext) throws(DrawError) -> JSONValue = { value, _ in value },
                                         merge: @escaping @MainActor (_ written: JSONValue, _ held: JSONValue?) -> JSONValue) {
        contribute(DrawValueWriting(key: key.rawValue, write: write, merge: merge), to: DrawValueWriters.self)
    }

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

    /// Names a shape that has no title for the pill `canvas draw` puts beside the shape an edge ends at on another board:
    /// `label` is what the shape is called where it is named in words (nil for none). At most one plugin names them.
    public mutating func drawLabels(_ label: @escaping @MainActor (AnyShapeRecord, Registry) -> String?) {
        contribute(DrawLabeling(label: label), to: DrawLabels.self)
    }

    /// Makes edges for `canvas draw`: `kind` is what connections are (nil: nothing draws them now,
    /// and an edge is `no_edges`), `attributes` the keys an edge takes beside `from:` and `to:`,
    /// `sides` which sides of a kind an edge may leave by and what it carries from each (what
    /// `canvas kinds` lists), `ends` which shapes a connection starts and ends on (nil: not two), and
    /// `make` a connection as a request asks, not inserted: new (`existing` nil), or `existing`
    /// changed (only what the request names; itself when nothing would change). It throws what it
    /// can't do, with a reason (`no_channel`, `cannot_connect`, `invalid_value`); `draw` says which
    /// line. Its closure says so, `{ request, existing, shapes throws(DrawError) in … }`, as a
    /// command's does. `shapes` is the board as the script leaves it, so either end may be new. At
    /// most one plugin makes edges.
    public mutating func drawEdges(kind: @escaping @MainActor (Registry) -> ShapeKind?, attributes: [String] = [],
                                   sides: @escaping @MainActor (ShapeKind, Registry) -> [EdgeRequest.Side: [String]],
                                   ends: @escaping @MainActor (AnyShapeRecord, Registry) -> (from: ShapeID, to: ShapeID)?,
                                   make: @escaping @MainActor (EdgeRequest, AnyShapeRecord?, ShapeContext) throws(DrawError) -> AnyShapeRecord) {
        contribute(DrawEdging(kind: kind, attributes: attributes, sides: sides, ends: ends, make: make), to: DrawEdges.self)
    }

    /// Says that the property `key` of the edge kind tells two edges of one pair apart in `canvas draw`
    /// (an arrow's `is`): a statement that writes it addresses the edge of the pair that holds that value,
    /// and one that writes none of these keys any edge of the pair (two are `ambiguous_edge`). The plugin
    /// that owns the property says so; a property the edge kind lacks tells nothing apart. At most one
    /// plugin names each key.
    public mutating func drawEdgeIdentity(_ key: PropertyKey) {
        contribute(DrawEdgeIdentifying(key: key.rawValue), to: DrawEdgeIdentities.self)
    }

    /// Checks each shape `canvas draw` makes or changes, as the script leaves the board: what it
    /// finds is reported as warnings (an error too: the shape is drawn, invalid). `touched` says, of
    /// what a run wrote (the transaction's `pending`, and its shapes), which other shapes to look at,
    /// on any board of the file: the run checks each as it found it and as it leaves it, by `check`,
    /// and warns of each issue it brought to one (at most `Drawing.broughtLimit` shapes, then a count
    /// and `rest`, a command that lists them all). It may name more shapes than change, never fewer.
    /// Without it a run says only what is wrong with the shapes it wrote. At most one plugin checks shapes.
    public mutating func drawChecks(touched: (@MainActor (ChangeSet, ShapeContext) -> Set<ShapeID>)? = nil, rest: String? = nil,
                                    _ check: @escaping @MainActor (AnyShapeRecord, ShapeContext) -> [DrawIssue]) {
        contribute(DrawCheck(check: check, touched: touched, rest: rest), to: DrawChecks.self)
    }

    /// Groups shapes for `canvas draw`'s `group "A" and "B"` and `ungroup "A"`: `group` puts the shapes it is handed (two or more,
    /// each once, on the board the run draws on, in the order the statement names them) in one group of their own, `ungroup` takes
    /// the shapes it is handed (one or more, each once) out of every group; each writes through the transaction the run applies
    /// everything in, once every shape and edge the script draws is in it, and says whether it changed anything (a group already as
    /// asked, or shapes already in none, change nothing). A shape that is read-only refuses the write as any change is refused, and
    /// the run says so (`read_only`). Without this, a script with either statement is `no_groups`. At most one plugin groups shapes.
    public mutating func drawGroups(group: @escaping @MainActor (_ shapes: [ShapeID], _ transaction: inout Transaction) -> Bool,
                                    ungroup: @escaping @MainActor (_ shapes: [ShapeID], _ transaction: inout Transaction) -> Bool) {
        contribute(DrawGrouping(group: group, ungroup: ungroup), to: DrawGroups.self)
    }

    /// Writes the strings of a script whose schema says `contentMediaType: mediaType`: `write` gets
    /// the text as the script wrote it (its string's escapes undone) and what it may ask
    /// (`DrawTextContext`), and returns the text to keep, or throws a refusal, which `draw` says on
    /// the statement's line (its closure says so, `{ text, context throws(DrawError) in … }`).
    /// `describes` is said after the attribute's type in `canvas kinds`, as `text (<Title> names)`.
    /// At most one plugin writes each media type.
    public mutating func drawTextFormat(mediaType: String, describes: String,
                                        write: @escaping @MainActor (String, DrawTextContext) throws(DrawError) -> String) {
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

    /// Whether something makes connections for `canvas draw`, and so `drawConnection` can.
    @MainActor public var drawsConnections: Bool { drawEdging?.kind(self) != nil }

    /// A new connection from one shape to another, by id: the maker `canvas draw` makes `edge "A" -> "B"`
    /// with, on the channel policy it picks (the first channel the start has a dot on that the end
    /// takes; a plain connection when neither has ports), not inserted. Nil when nothing makes
    /// connections or the maker refuses the pair (an end that can't be connected, no channel they
    /// share), which `draw` would say with a reason. `shapes` is the board the connection is made
    /// in, either end in it. `standingFor` is what an end stands for when it is a stand-in
    /// (`EdgeRequest.fromStandsFor`, `toStandsFor`): the ends are then connected as what they stand for
    /// is. `beside` names the connections already joining the pair, for a maker that draws a second
    /// apart from the first; nil: the maker reads them.
    @MainActor public func drawConnection(from: ShapeID, to: ShapeID, in shapes: ShapeContext,
                                          standingFor: (from: [ShapeKind], to: [ShapeKind]) = ([], []),
                                          beside: [ShapeID]? = nil) -> AnyShapeRecord? {
        guard let edging = drawEdging, let kind = edging.kind(self) else { return nil }
        let request = EdgeRequest(from: from, to: to, fromStandsFor: standingFor.from, toStandsFor: standingFor.to, beside: beside)
        guard let made = try? edging.make(request, nil, shapes), made.kind == kind else { return nil }
        return made
    }

    /// What names shapes, if something does.
    public var drawNaming: DrawNaming? { contributions(to: DrawNames.self).first?.value }
    var drawEdging: DrawEdging? { contributions(to: DrawEdges.self).first?.value }
    /// The property keys that tell the edges of one pair apart, in plugin order.
    var drawEdgeIdentityKeys: [String] { contributions(to: DrawEdgeIdentities.self).map(\.value.key) }
    var drawCheck: DrawCheck? { contributions(to: DrawChecks.self).first?.value }

    /// What a shape with no title is called for a pill, if something says.
    @MainActor func drawLabel(of record: AnyShapeRecord) -> String? {
        contributions(to: DrawLabels.self).first?.value.label(record, self)
    }

    /// What groups shapes for `group` and `ungroup`, if something does.
    var drawGrouping: DrawGrouping? { contributions(to: DrawGroups.self).first?.value }

    var drawReporting: DrawReporting? { contributions(to: DrawReports.self).first?.value }

    /// The writers of values, by property key.
    var drawValueWriters: [String: DrawValueWriting] {
        Dictionary(contributions(to: DrawValueWriters.self).map { ($0.value.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// The formats that write text, by media type.
    var drawTextFormats: [String: DrawTextFormatting] {
        Dictionary(contributions(to: DrawTextFormats.self).map { ($0.value.mediaType, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
