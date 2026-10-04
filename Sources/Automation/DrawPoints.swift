import Canvas

// What `canvas draw` needs from concerns it doesn't own, each an extension point with at most one
// contribution, from the bridge that joins this plugin to the plugin that owns the concern: what a
// shape is called (DrawNames, Titles'), what an edge is (DrawEdges, Connections'), and what's
// wrong with a shape drawn (DrawChecks, Validation's). Without one, `draw` does without: no titles
// (a titled statement is `no_names`), no edges (`no_edges`), and only the schemas' bounds checked.

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

    public init(from: ShapeID, to: ShapeID, fromSide: Side? = nil, toSide: Side? = nil, bothHeads: Bool = false,
                attributes: [String: String] = [:], fromName: String = "", toName: String = "", written: String = "") {
        self.from = from
        self.to = to
        self.fromSide = fromSide
        self.toSide = toSide
        self.bothHeads = bothHeads
        self.attributes = attributes
        self.fromName = fromName
        self.toName = toName
        self.written = written
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

/// The one key each draw point's contribution claims: "draw names" in a conflict.
struct DrawPointKey: Hashable, CustomStringConvertible {
    let name: String
    var description: String { name }
}

// MARK: Sugar (what bridges write)

extension PluginRegistrar {
    /// Names shapes for `canvas draw`: `name` is what a shape is called (folded, as `fold` folds a
    /// title; nil for none, or blank), `namingProperty` the property of a kind's schema a title is
    /// written to (nil: its shapes can't be given one), `isDerived` whether the kind works a name out
    /// by itself (a schema card's, from its schema's `"title"`), and `fold` how a title a script writes
    /// is folded before it's matched (nil: it's blank). At most one plugin names shapes.
    public mutating func drawNames(name: @escaping @MainActor (AnyShapeRecord, Registry) -> String?,
                                   namingProperty: @escaping @MainActor (ShapeKind, Registry) -> String?,
                                   isDerived: @escaping @MainActor (ShapeKind, Registry) -> Bool,
                                   fold: @escaping @Sendable (String) -> String?) {
        contribute(DrawNaming(name: name, namingProperty: namingProperty, isDerived: isDerived, fold: fold), to: DrawNames.self)
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
}

// MARK: Reading them

extension Registry {
    var drawNaming: DrawNaming? { contributions(to: DrawNames.self).first?.value }
    var drawEdging: DrawEdging? { contributions(to: DrawEdges.self).first?.value }
    var drawCheck: DrawCheck? { contributions(to: DrawChecks.self).first?.value }
}
