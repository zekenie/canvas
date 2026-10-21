import Canvas
import Mentions
import Publishing
import Queries

/// What a reference stands for now, as the pill, the panel's header, the table of contents' row and
/// the menu read it: derived from the reference's props and the file, never stored. One place works
/// it out (`ReferenceCondition.of`), and `ReferenceState.state(of:)` is the one place the panel, the
/// list and the menu ask it.
public enum ReferenceCondition: Equatable {
    /// Nothing yet: a pill placed and not typed into.
    case empty
    /// A direct reference whose shape is there, public and showable: as it looks.
    case live(MentionAppearance)
    /// A direct reference whose shape is in no board of the file (deleted, or never here): the name
    /// it holds.
    case missing(label: String)
    /// A direct reference whose shape is in the file but can't be shown: on a board the app can't
    /// show, kept aside, or of a kind that can't be named. The name it holds.
    case unavailable(label: String)
    /// A direct reference whose shape is there and isn't public (any longer): nothing is forwarded.
    case notPublic(MentionAppearance)
    /// A dynamic reference whose words have no query: it stands for nothing until the person asks.
    case notInterpreted(text: String)
    /// A dynamic reference whose words are being turned into a query.
    case interpreting(text: String)
    /// A dynamic reference with a query, whose matches aren't known yet.
    case finding(text: String)
    /// A dynamic reference whose query found shapes: what it stands for (the first, or all).
    case found(text: String, ReferenceFound)
    /// A dynamic reference whose query found nothing, public or not.
    case noMatches(text: String)
    /// A dynamic reference whose query found shapes, `count` of them, none public: it stands for
    /// nothing until they are.
    case privateMatches(text: String, count: Int)
    /// A dynamic reference whose query was refused: it stands for nothing, and this says why.
    case refused(text: String, message: String)
    /// A dynamic reference whose answer didn't come.
    case failed(text: String, ReferenceFailure)
    /// A dynamic reference with a query and nothing to ask it of (no query engine installed).
    case cannotFind(text: String)

    /// Whether the pill stands for nothing now (drawn dashed, with no fill).
    public var standsForNothing: Bool {
        switch self {
        case .missing, .unavailable, .notPublic, .notInterpreted, .noMatches, .privateMatches, .refused, .failed, .cannotFind: true
        case .empty, .live, .interpreting, .finding, .found: false
        }
    }

    /// What a dynamic reference is called (its words, else its query); nil for any other.
    public var text: String? {
        switch self {
        case .notInterpreted(let text), .interpreting(let text), .finding(let text), .found(let text, _), .noMatches(let text),
             .privateMatches(let text, _), .refused(let text, _), .failed(let text, _), .cannotFind(let text): text
        case .empty, .live, .missing, .unavailable, .notPublic: nil
        }
    }

    /// Whether there is an original to go to: a shape that's there, public or not, or what a query
    /// found.
    public var hasOriginal: Bool {
        switch self {
        case .live, .notPublic, .found: true
        default: false
        }
    }

    /// The target's appearance, while it's there.
    public var appearance: MentionAppearance? {
        switch self {
        case .live(let appearance), .notPublic(let appearance): appearance
        default: nil
        }
    }
}

extension ReferenceCondition {
    /// A reference's props against what `lookup` finds (a shape on any board of the file the editor
    /// can show) and whether the file holds a shape `lookup` can't show (`isElsewhere`: on a board the
    /// app can't show). Public when `registry.isPublic` says so.
    /// A dynamic one's condition follows how its query was answered (`status`: `ReferenceState`'s,
    /// nil read as not answered yet).
    /// `appearance` says how a shape the reference stands for shows (the registry's mention
    /// appearance, the default): the service's is the editor's, with the shape's own tint.
    @MainActor
    static func of(_ props: Reference, status: ReferenceStatus?, registry: Registry, lookup: (ShapeID) -> AnyShapeRecord?,
                   isElsewhere: (ShapeID) -> Bool, appearance appearanceOf: ((AnyShapeRecord) -> MentionAppearance?)? = nil) -> ReferenceCondition {
        let appearanceOf = appearanceOf ?? { registry.mentionAppearance(of: $0) }
        switch props.mode {
        case .empty:
            return .empty
        case .dynamic:
            let text = props.text
            // No query: nothing stands for it until the person acts, unless its words are being
            // interpreted, were refused an answer (a failure), or there's nothing to interpret them with.
            guard props.query != nil else {
                switch status {
                case .interpreting?: return .interpreting(text: text)
                case .failed(let failure)?: return .failed(text: text, failure)
                case .unavailable?: return .cannotFind(text: text)
                default: return .notInterpreted(text: text)
                }
            }
            switch status ?? .finding(slow: false) {
            case .unavailable:
                return .cannotFind(text: text)
            case .interpreting:
                return .interpreting(text: text)
            case .finding:
                return .finding(text: text)
            case .answered(let matches):
                guard matches.count > 0, let first = matches.ids.first else {
                    return matches.heldBack > 0 ? .privateMatches(text: text, count: matches.heldBack) : .noMatches(text: text)
                }
                let appearance = props.all ? nil : lookup(first).flatMap(appearanceOf)
                return .found(text: text, ReferenceFound(all: props.all, count: matches.count, ids: matches.ids, first: appearance))
            case .refused(let message):
                return .refused(text: text, message: message)
            case .failed(let failure):
                return .failed(text: text, failure)
            }
        case .direct:
            guard let target = props.target else { return .empty }
            guard let record = lookup(target.id) else {
                return isElsewhere(target.id) ? .unavailable(label: target.label) : .missing(label: target.label)
            }
            guard let appearance = appearanceOf(record) else { return .unavailable(label: target.label) }
            return registry.isPublic(record) ? .live(appearance) : .notPublic(appearance)
        }
    }

    /// `of(...).standsForNothing`, without working out a name: the answer a skeleton needs, which is
    /// drawn for every pill in view when zoomed out, and has no use for a label (a title is a lookup of
    /// its own, and a derived one is asked of the editor).
    @MainActor
    static func standsForNothing(_ props: Reference, status: ReferenceStatus?, registry: Registry, lookup: (ShapeID) -> AnyShapeRecord?) -> Bool {
        switch props.mode {
        case .empty:
            return false
        case .dynamic:
            guard props.query != nil else {
                if case .interpreting? = status { return false }
                return true
            }
            switch status ?? .finding(slow: false) {
            case .finding, .interpreting: return false
            case .answered(let matches): return matches.count == 0
            case .unavailable, .refused, .failed: return true
            }
        case .direct:
            guard let target = props.target, let record = lookup(target.id) else { return true }
            return record.isOpaque || !registry.isMentionable(record.kind) || !registry.isPublic(record)
        }
    }
}

/// What a dynamic reference's query found, as its pill, row and panel show it: whether it stands for
/// every match or the first, how many there were in all, those it was given (in file order: the
/// first, and what All would add, or up to fifty), and how the first shows (for one that stands for
/// it alone: its kind's symbol and tint trail the pill).
public struct ReferenceFound: Equatable {
    public var all: Bool
    public var count: Int
    public var ids: [ShapeID]
    public var first: MentionAppearance?

    public init(all: Bool, count: Int, ids: [ShapeID], first: MentionAppearance?) {
        self.all = all
        self.count = count
        self.ids = ids
        self.first = first
    }

    /// What it stands for: the first match, or every one it was given.
    public var standsFor: [ShapeID] { all ? ids : Array(ids.prefix(1)) }
}
