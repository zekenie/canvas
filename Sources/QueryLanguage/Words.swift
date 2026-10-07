/// The language's own pseudo-classes, written without the colon. Their names ignore ASCII case, as
/// CSS's do; plugins add words of their own (the caller's), and none may be one of these.
public enum Word: String, CaseIterable, Sendable {
    case not
    case `is`
    case `where`
    case has
    case inside
    case topLevel = "top-level"
    case currentBoard = "current-board"
    case edgeTo = "edge-to"
    case edgeFrom = "edge-from"
    case connectedTo = "connected-to"
    case downstreamOf = "downstream-of"
    case upstreamOf = "upstream-of"
    case componentOf = "component-of"
    case startsAt = "starts-at"
    case endsAt = "ends-at"
    case startOf = "start-of"
    case endOf = "end-of"
    case between
    case dangling
    case contains

    /// What a word's parentheses hold, which is how the parser reads them.
    public enum Signature: Sendable, Equatable {
        /// No parentheses.
        case none
        /// A selector list, commas OR.
        case selectors
        /// `:has`'s items, each a compound with an optional `>` before it, commas OR.
        case has
        /// One complex selector, the anchor; after a comma, edge types.
        case anchor
        /// Two anchors, then edge types after a comma.
        case twoAnchors
        /// Edge types joined by `|`; with `optional`, the parentheses may be left out.
        case types(optional: Bool)
        /// One string, not empty.
        case text

        /// What parentheses of this signature take, in a few words: what a refusal says (":inside
        /// takes shapes.") and what the vocabulary lists, for a plugin's word too.
        public var takes: String {
            switch self {
            case .none: "no argument"
            case .selectors: "shapes"
            case .has: "the shapes inside it"
            case .anchor: "a shape, then edge types if any"
            case .twoAnchors: "two shapes, then edge types if any"
            case .types: "edge types, or nothing"
            case .text: "the text to find, in quotes"
            }
        }
    }

    public var signature: Signature {
        switch self {
        case .not, .is, .where, .inside: .selectors
        case .has: .has
        case .topLevel, .currentBoard: .none
        case .edgeTo, .edgeFrom, .connectedTo, .downstreamOf, .upstreamOf, .componentOf, .startsAt, .endsAt, .startOf, .endOf: .anchor
        case .between: .twoAnchors
        case .dangling: .types(optional: true)
        case .contains: .text
        }
    }

    /// What its parentheses take (its signature's `takes`).
    public var takes: String { signature.takes }

    /// A query that uses it: a refusal's hint, and the vocabulary's example. By titles only (the
    /// story file's): this module knows no kind.
    public var example: String {
        switch self {
        case .not: #":not("Payments" *)"#
        case .is: #":is("Auth", "Checkout")"#
        case .where: #":where("Auth", "Checkout")"#
        case .has: #":has("Refund policy")"#
        case .inside: #":inside("Payments")"#
        case .topLevel: ":top-level"
        case .currentBoard: ":current-board"
        case .edgeTo: #":edge-to("Auth")"#
        case .edgeFrom: #":edge-from("API gateway")"#
        case .connectedTo: #":connected-to("Checkout")"#
        case .downstreamOf: #":downstream-of("Checkout")"#
        case .upstreamOf: #":upstream-of("Auth")"#
        case .componentOf: #":component-of("Warehouse")"#
        case .startsAt: #":starts-at("Warehouse")"#
        case .endsAt: #":ends-at("Auth")"#
        case .startOf: #":start-of(:ends-at("Auth"))"#
        case .endOf: #":end-of(:starts-at("Warehouse"))"#
        case .between: #":between("Auth", "API gateway")"#
        case .dangling: ":dangling"
        case .contains: #":contains("retry")"#
        }
    }
}

/// The language's words that aren't pseudo-classes, ignoring ASCII case as `Word`s do.
public enum Keyword: String, Sendable {
    /// `only T` in a type list: the type alone, without those under it.
    case only
}
