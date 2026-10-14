import CoreGraphics

// Modified from reladraw's src/ast.ts (Apache-2.0; THIRD_PARTY_NOTICES.md).

/// A script, read: its statements in order, with the styles they use merged in, and the styles as
/// defined (a style's line, for what the caller finds wrong with it once kinds are known).
public struct Script: Sendable, Equatable {
    public var statements: [Statement]
    public var styles: [StyleDefinition]

    public init(statements: [Statement], styles: [StyleDefinition]) {
        self.statements = statements
        self.styles = styles
    }
}

/// One line that says something: what it says, where, and as written (its comment stripped).
public struct Statement: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        case shape(ShapeStatement)
        case edge(EdgeStatement)
        case delete(DeleteStatement)
    }

    /// Its line in the script, from 1.
    public var line: Int
    /// The line as written, its comment stripped, trimmed: what an error quotes.
    public var text: String
    public var body: Body

    public init(line: Int, text: String, body: Body) {
        self.line = line
        self.text = text
        self.body = body
    }
}

/// `<kind> ["<title>"] { attribute | placement }`: make a shape, or update the one with that title.
public struct ShapeStatement: Sendable, Equatable {
    /// The first word: a kind, for the caller to find.
    public var word: String
    /// What it is called as written: a title (escapes undone, never blank), or, for a shape that has none, an id (`#7C1E…`) that
    /// names a shape the file already has; nil for an untitled shape.
    public var name: ShapeName?
    /// `size:`, from the statement or a style: both sides, or a width alone.
    public var size: Size?
    /// `gap:`, from the statement or a style.
    public var gap: Gap?
    /// `overlap: allow`, from the statement or a style.
    public var overlapAllowed: Bool
    /// `title: "New"`, a rename (the caller refuses it on a shape it makes).
    public var newTitle: String?
    /// The styles it names, in order.
    public var styles: [String]
    /// Every other attribute, its own in the order written and then what its styles give it
    /// (`fromStyle`), a key once: the kind's properties, for the caller to check.
    public var attributes: [Attribute]
    /// Where it goes, in the order written.
    public var clauses: [Clause]
    /// `in "X"`: the name of the shape it goes in (a subboard, whose board it's drawn on), as
    /// written. Not a placement: it says which shape holds it, not where it sits.
    public var container: ShapeName?

    public init(word: String, title: String? = nil, name: ShapeName? = nil, size: Size? = nil, gap: Gap? = nil, overlapAllowed: Bool = false,
                newTitle: String? = nil, styles: [String] = [], attributes: [Attribute] = [], clauses: [Clause] = [], container: ShapeName? = nil) {
        self.word = word
        self.name = name ?? title.map { .title($0) }
        self.size = size
        self.gap = gap
        self.overlapAllowed = overlapAllowed
        self.newTitle = newTitle
        self.styles = styles
        self.attributes = attributes
        self.clauses = clauses
        self.container = container
    }

    /// Its title as written, if it is named by one (nil for an untitled shape, and for one named by its id).
    public var title: String? { name?.title }
}

/// How a statement names a shape the file has: by its title, in quotes, or, for a shape that has none, by its id, in the
/// query language's spelling (`#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11`). The language keeps an id as text and checks only its
/// shape (8-4-4-4-12 hex digits); what it names, and whether any shape has it, is for the caller.
public enum ShapeName: Sendable, Hashable, ExpressibleByStringLiteral {
    /// The shape called this, as written (escapes undone).
    case title(String)
    /// The shape with this id, as written after the `#`.
    case id(String)

    public init(stringLiteral title: String) { self = .title(title) }

    public var title: String? { if case .title(let title) = self { title } else { nil } }
    public var id: String? { if case .id(let id) = self { id } else { nil } }

    /// As a script writes it: `"Hub"`, `#7C1E2A04-4B9E-4E0C-9D8C-5B0E7F3A2C11`.
    public var written: String {
        switch self {
        case .title(let title): quote(title)
        case .id(let id): "\(Self.idMark)\(id)"
        }
    }

    /// The character an id starts with.
    public static let idMark: Character = "#"

    /// Whether `text` (without the `#`) is an id's shape: 36 characters, hex digits in groups of 8, 4, 4, 4 and 12.
    public static func isID(_ text: some StringProtocol) -> Bool {
        guard text.count == 36 else { return false }
        return text.enumerated().allSatisfy { index, character in
            [8, 13, 18, 23].contains(index) ? character == "-" : character.isASCII && character.isHexDigit
        }
    }
}

/// `edge "<a>" -> "<b>" { attribute }`: a connection from one shape to another.
public struct EdgeStatement: Sendable, Equatable {
    /// The name of the shape it starts from (for `"B" <- "A"`, "A").
    public var from: ShapeName
    /// The name of the shape it ends on.
    public var to: ShapeName
    /// As written: `->`, `<-` (the ends written the other way round), or `<->` (heads at both ends).
    public var arrow: EdgeArrow
    /// `from:`, the side its start aims at.
    public var fromSide: EdgeSide?
    /// `to:`, the side its end aims at.
    public var toSide: EdgeSide?
    /// `via:`, the kind of shape it goes through, a word for the caller to find (the kind of
    /// stand-in that stands for its end, put beside the other: `via: reference`).
    public var via: String?
    /// `share:`, which reference an edge through one goes to: any already beside the start's container
    /// (`share: true`), or the one beside a named shape (`share: "A"`); nil to make its own.
    public var share: EdgeShare?
    /// Every other attribute, for the caller to check (the channel it's on, from Connections'
    /// `PortEdgesPlugin`).
    public var attributes: [Attribute]

    public init(from: ShapeName, to: ShapeName, arrow: EdgeArrow = .forward, fromSide: EdgeSide? = nil, toSide: EdgeSide? = nil,
                via: String? = nil, share: EdgeShare? = nil, attributes: [Attribute] = []) {
        self.from = from
        self.to = to
        self.arrow = arrow
        self.fromSide = fromSide
        self.toSide = toSide
        self.via = via
        self.share = share
        self.attributes = attributes
    }

    /// Whether it has heads at both ends (`<->`).
    public var bothHeads: Bool { arrow == .both }

    /// Its ends as written: `"A" -> "B"`, `"B" <- "A"`.
    public var written: String {
        arrow == .backward ? "\(to.written) \(arrow.rawValue) \(from.written)" : "\(from.written) \(arrow.rawValue) \(to.written)"
    }
}

/// What `share:` says: which reference an edge that goes through one is drawn to.
public enum EdgeShare: Sendable, Equatable {
    /// `share: true`: one already there for the same end, in the start's container.
    case any
    /// `share: "A"`: the one beside the shape named A (a title as written, or an id), whose own arrow goes into it.
    case beside(ShapeName)
}

/// `delete "<title>"`, or `delete edge "<a>" -> "<b>"`.
public enum DeleteStatement: Sendable, Equatable {
    /// The shape with this name, and every connection with an end on it.
    case shape(ShapeName)
    /// The connections from one shape to another; either way round for `<->`. `attributes` are the
    /// keys that tell two connections of one pair apart (`delete edge "A" -> "B" is: "T"`), as
    /// written, for the caller to check: the language knows no kind.
    case edges(from: ShapeName, to: ShapeName, eitherWay: Bool, attributes: [Attribute] = [])
}

/// `style <name> attribute { attribute }`: attributes to give any shape that names it.
public struct StyleDefinition: Sendable, Equatable {
    public var name: String
    public var line: Int
    /// The line as written, its comment stripped, trimmed.
    public var text: String
    /// What it gives, as written, the language's `size:`, `gap:` and `overlap:` among them.
    public var attributes: [Attribute]

    public init(name: String, line: Int, text: String, attributes: [Attribute]) {
        self.name = name
        self.line = line
        self.text = text
        self.attributes = attributes
    }
}

/// `key: value`, a key the language leaves to the caller.
public struct Attribute: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        /// A bare word: `high`, `12`, `true`, `null`.
        case word(String)
        /// A quoted string, its escapes undone.
        case quoted(String)
        /// A JSON array or object, as written: `[{"text": "Eggs"}]`.
        case json(String)

        /// As a script writes it.
        public var written: String {
            switch self {
            case .word(let word): word
            case .quoted(let text): quote(text)
            case .json(let json): json
            }
        }
    }

    public var key: String
    public var value: Value
    /// The style it came from, nil if the statement wrote it.
    public var fromStyle: String?

    public init(key: String, value: Value, fromStyle: String? = nil) {
        self.key = key
        self.value = value
        self.fromStyle = fromStyle
    }

    /// As a script writes it: `priority: high`.
    public var written: String { "\(key): \(value.written)" }
}

/// What a placement says about the boxes it names.
public enum Relation: Sendable, Hashable {
    /// `right of`, `above`, `below-left of`, …: a gap beyond that side of the targets.
    case direction(Direction)
    /// `level with` (the vertical middle), `top level with`, …: a line shared with the targets.
    case level(AlignSide)
    /// `inside T <part>`: within T, against that part (the direction from it toward T's middle).
    case inside
    /// `outside T <part>`: wholly beyond that part (the direction from T's middle toward it).
    case outside
    /// `on T [<part>]`: centered on the part (T's middle if none).
    case on
}

/// One placement: `right of "A" and "B" (gap: wide)`.
public struct Clause: Sendable, Hashable {
    public var relation: Relation
    /// What it's placed against, in order; `inside`, `outside` and `on` name one.
    public var targets: [Target]
    /// Its bracketed gap, if any.
    public var gap: Gap?
    /// The placement quoted back, as an error names it: `right of "A" and "B" (gap: wide)`. Two
    /// placements written alike (`right "A"` and `right of "A"`) quote back alike, which is what
    /// makes a list.
    public var written: String

    public init(relation: Relation, targets: [Target], gap: Gap? = nil, written: String? = nil) {
        self.relation = relation
        self.targets = targets
        self.gap = gap
        self.written = written ?? Clause.write(relation, targets, gap: gap?.written)
    }

    /// The direction it holds its box in: a direction's own, or `inside`'s and `outside`'s from
    /// their part. Nil for alignments and `on`.
    public var direction: Direction? {
        switch relation {
        case .direction(let direction): direction
        case .inside: targets.first?.part?.inward
        case .outside: targets.first?.part?.inward?.opposite
        case .level, .on: nil
        }
    }

    static func write(_ relation: Relation, _ targets: [Target], gap: String?) -> String {
        write(relation, naming: targets.map(\.written), gap: gap)
    }

    /// A placement quoted back with its targets named as given: one a caller makes up against a shape
    /// no title names, said in words of its own (`below the reference to "Auth" (gap: 16)`).
    public static func written(_ relation: Relation, naming targets: [String], gap: Gap? = nil) -> String {
        write(relation, naming: targets, gap: gap?.written)
    }

    static func write(_ relation: Relation, naming targets: [String], gap: String?) -> String {
        let named = listed(targets)
        let bracket = gap.map { " (\(LanguageKey.gap.rawValue): \($0))" } ?? ""
        switch relation {
        case .direction(let direction):
            return "\(direction.rawValue) \(direction.takesOf ? Word.of.rawValue + " " : "")\(named)\(bracket)"
        case .level(let side):
            let level = "\(Word.level.rawValue) \(Word.with.rawValue)"
            return "\(side == .center ? "" : side.rawValue + " ")\(level) \(named)"
        case .inside: return "\(Word.inside.rawValue) \(named)\(bracket)"
        case .outside: return "\(Word.outside.rawValue) \(named)\(bracket)"
        case .on: return "\(Word.on.rawValue) \(named)"
        }
    }
}

/// A box a placement names, and the part of it, if any.
public struct Target: Sendable, Hashable {
    public enum Box: Sendable, Hashable {
        /// The shape with this title (as written; the caller folds it).
        case title(String)
        /// The shape with this id (as written, after the `#`).
        case id(String)
        /// `board`: the bounds of every shape the script doesn't move.
        case board
        /// `view`: the part of the board in the window.
        case view
    }

    public var box: Box
    public var part: Part?

    public init(_ box: Box, part: Part? = nil) {
        self.box = box
        self.part = part
    }

    /// Whether it names a shape (by its title or its id) rather than a word of the language.
    public var isName: Bool {
        switch box {
        case .title, .id: true
        case .board, .view: false
        }
    }

    /// As a script writes it: `"Hub"`, `"Hub" top-right`, `view top-right`.
    public var written: String {
        let named = switch box {
        case .title(let title): quote(title)
        case .id(let id): ShapeName.id(id).written
        case .board: PlaceWord.board.rawValue
        case .view: PlaceWord.view.rawValue
        }
        return part.map { "\(named) \($0.rawValue)" } ?? named
    }
}

/// A title or text in straight double quotes, escaped as a script writes it.
func quote(_ text: String) -> String {
    var escaped = ""
    for character in text {
        switch character {
        case "\"": escaped += "\\\""
        case "\\": escaped += "\\\\"
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        default: escaped.append(character)
        }
    }
    return "\"\(escaped)\""
}

/// `"A"`, `"A" and "B"`, `"A", "B" and "C"`.
func listed(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) \(Word.and.rawValue) \(last)"
}
