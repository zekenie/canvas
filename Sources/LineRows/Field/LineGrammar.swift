import AppKit
import Canvas
import TextEditing

// What a kind's rows are written in: a grammar a role (a table's column, an enum's value), which reads a line into a
// row, prints a row back into its line, says what its words are (spans the field draws, a mark in the gutter) and what
// fits at the caret (offers, the one caret list's). A row is kept as the kind's value and printed as a line only while
// it has the caret, so a rename that names it follows on its own; the same `read` serves a pasted block and `canvas
// draw`'s words. A word that stands for a shape (an enum's name) is a reference: printed or picked, the line carries
// what it stands for, so a line left as it was keeps naming the same shape when two share a name.

/// What kind of row a line is, in the kind's words: "column", "value", "endpoint", "prefix".
public struct LineRole: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

/// A run of a line that stands for a shape or a part of one, by id: an enum's name in a column's line. UTF-16, as
/// `NSRange` is.
public struct LineReference: Hashable, Sendable {
    public var range: NSRange
    public var target: PartAddress

    public init(range: NSRange, target: PartAddress) {
        self.range = range
        self.target = target
    }
}

/// A line as the field holds it: its text, and the runs of it that stand for something by id.
public struct LineText: Equatable, Sendable {
    public var string: String
    public var references: [LineReference]

    public init(_ string: String, references: [LineReference] = []) {
        self.string = string
        self.references = references
    }

    /// What the run at exactly `range` stands for; nil where no reference is that run (typed over, or never one).
    public func reference(at range: NSRange) -> PartAddress? {
        references.first { NSEqualRanges($0.range, range) }?.target
    }
}

/// How a span of a line looks while it's typed: the kind says what each is drawn in (`LineStyle`). Recognized words stay
/// characters, so the caret goes into them; a pill or a chip is drawn under them (a highlight), never an attachment.
public enum LineLook: Equatable {
    /// A row's name, in the line's own font.
    case name
    /// Code: a type, a path. Monospaced.
    case code
    /// A word of the grammar's own (`null`, `default`): monospaced, in the secondary ink.
    case keyword
    /// Words the grammar can't place: as typed, never marked.
    case plain
    /// A name that stands for a shape, in a pill of its color (an enum's purple), its text in `ink`, monospaced.
    case pill(NSColor, ink: NSColor)
    /// A name that stands for nothing yet, in a dashed pill's line of the color it would be.
    case dashedPill(NSColor, ink: NSColor)
    /// A word in a chip of its color, its text in `ink` (a method, white).
    case chip(NSColor, ink: NSColor)
    /// Text in a color of its own.
    case tinted(NSColor)
}

/// A span of a line and how it looks.
public struct LineSpan: Equatable {
    public var range: NSRange
    public var look: LineLook

    public init(_ range: NSRange, _ look: LineLook) {
        self.range = range
        self.look = look
    }
}

/// What the gutter shows for a line: an SF Symbol in a color (a primary key's key, a unique column's "1").
public struct LineMark: Equatable {
    public var symbol: String
    public var color: NSColor

    public init(symbol: String, color: NSColor) {
        self.symbol = symbol
        self.color = color
    }
}

/// What a line says: its row (nil for a line with nothing on it), the spans of its words, its gutter's mark.
public struct LineReading<Row> {
    public var row: Row?
    public var spans: [LineSpan]
    public var mark: LineMark?

    public init(row: Row?, spans: [LineSpan] = [], mark: LineMark? = nil) {
        self.row = row
        self.spans = spans
        self.mark = mark
    }
}

/// One thing that fits at the caret: what the list shows and a pick puts in, and the shape or row it stands for, which
/// is lit on the board while it's highlighted (an enum offered by name). Or an action ("New type Problem"), done by Return
/// or a click (and Tab, which picks either) (`action(_:_:)`).
public struct LineOffer: Equatable {
    public var completion: CaretCompletion
    public var light: PartAddress?
    /// What the row does, for an action row; nil for words a pick puts in.
    public var action: LineAction?

    public init(_ completion: CaretCompletion, light: PartAddress? = nil) {
        self.completion = completion
        self.light = light
    }

    /// An action row, listed last by the grammar that offers it: `label` what it says ("New type Problem"), `action` what it does.
    /// Done, the words it was offered for (the offers' range) stand for what it made, and the line is written with them in the
    /// action's step, the caret staying where it is.
    public static func action(_ label: String, _ action: LineAction) -> LineOffer {
        var offer = LineOffer(CaretCompletion(label: label, insert: "", isRelevant: false, isAction: true))
        offer.action = action
        return offer
    }
}

/// What an action row does: makes a shape (a type note named by the words typed), whose address the words then stand for, in
/// a step of its own name that the line's commit joins ("New Type"). Nil from `perform`: nothing made, nothing written.
public struct LineAction: Equatable, Sendable {
    private let id = UUID()
    /// The step it and the line's commit are, together.
    public let stepName: String
    let perform: @MainActor @Sendable (LineContext) -> PartAddress?

    public init(step: String, perform: @escaping @MainActor @Sendable (LineContext) -> PartAddress?) {
        stepName = step
        self.perform = perform
    }

    public static func == (a: LineAction, b: LineAction) -> Bool { a.id == b.id }
}

/// What fits at the caret: the range a pick replaces (UTF-16, holding the caret), what's typed of it, and the offers in
/// the order the grammar gives them, unranked (the list ranks them by what's typed).
public struct LineOffers: Equatable {
    public var range: NSRange
    public var query: String
    public var items: [LineOffer]

    public init(range: NSRange, query: String, items: [LineOffer]) {
        self.range = range
        self.query = query
        self.items = items
    }

    /// As the caret list takes them.
    public var completions: CaretCompletions { CaretCompletions(range: range, query: query, items: items.map(\.completion)) }
}

/// Characters typed that become others as they're typed: `->` becomes `→`.
public struct LineSubstitution: Equatable, Sendable {
    public var typed: String
    public var becomes: String

    public init(_ typed: String, becomes: String) {
        self.typed = typed
        self.becomes = becomes
    }
}

/// What a grammar reads a line in: the editor (its services, the file, for names that stand for shapes), the shape the
/// row is of and the row itself (nil for a line not yet a row).
@MainActor
public struct LineContext {
    public let editor: CanvasEditor
    public let shape: ShapeID
    public let row: PartID?

    public init(editor: CanvasEditor, shape: ShapeID, row: PartID? = nil) {
        self.editor = editor
        self.shape = shape
        self.row = row
    }
}

/// How rows of one role are written as lines: the reader and printer every way a row comes from text shares (typing, a
/// pasted block, `canvas draw`), and what fits at the caret. Printing what was read loses no word: a word it can't place
/// stays in the row as written, shown plain.
@MainActor
public protocol LineGrammar<Row> {
    associatedtype Row
    /// The row a line says, its id `id` (nil for a line with nothing on it), the spans of its words and its gutter mark.
    /// A run the line carries a reference for, whose words are a name, stands for that reference's shape, whatever else
    /// is called the same; a name typed afresh is found by name.
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<Row>
    /// The line a row is printed as while it has the caret, a name of a shape as that shape is called now, carrying a
    /// reference to it.
    func print(_ row: Row, in context: LineContext) -> LineText
    /// What fits at the caret (UTF-16) in `line`, which reads as `reading`: nil where nothing does.
    func offers(at caret: Int, in line: LineText, reading: LineReading<Row>, context: LineContext) -> LineOffers?
    /// The lines of a pasted block, a row each: by default split at line breaks, blank ones dropped.
    func lines(fromPasted text: String) -> [String]
    /// What's typed that becomes something else as it's typed (`->` as `→`).
    var substitutions: [LineSubstitution] { get }
    /// What VoiceOver says of a row: "customer_id, uuid, unique".
    func spoken(_ row: Row, in context: LineContext) -> String
}

extension LineGrammar {
    public func offers(at caret: Int, in line: LineText, reading: LineReading<Row>, context: LineContext) -> LineOffers? { nil }

    public func lines(fromPasted text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public var substitutions: [LineSubstitution] { [] }
}

extension LineGrammar where Row: Equatable {
    /// The law every grammar keeps, for its tests to hold over a corpus of lines: printing what was read loses nothing. The
    /// printed line reads back as the same row, and the words nothing read (`unread`: the words the row keeps as written)
    /// come out as they went in, in order. Each line that breaks it, and how; empty where every line keeps it.
    public func losses(in lines: [String], unread: (Row) -> [String], in context: LineContext) -> [(line: String, lost: String)] {
        lines.compactMap { line in
            let id = PartID()
            guard let row = read(LineText(line), id: id, in: context).row else { return nil }
            let printed = print(row, in: context)
            guard read(printed, id: id, in: context).row == row else { return (line, "\(printed.string) reads back otherwise") }
            let words = printed.string.split(whereSeparator: \.isWhitespace).map(String.init)
            var from = words.startIndex
            for word in unread(row) {
                guard let at = words[from...].firstIndex(of: word) else { return (line, "\(word), unread, isn't in \(printed.string) in order") }
                from = words.index(after: at)
            }
            return nil
        }
    }
}
