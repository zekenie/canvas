import Canvas
import CoreGraphics
import Foundation

// What a schema card's description says of its schema, a few words at a time. The model links words
// of the description to the parts of the schema they say (`SchemaPrompts.toHighlights`, asked by
// `SchemaHighlighter` once the two are in step), so the card can color them, a field's one way and a
// rule's another, and show each part of the schema on its words. A highlight holds its words as the
// description wrote them, found again in the text as it is now (`SchemaHighlights.place`: in order,
// never overlapping), so words typed around them keep theirs, and a JSON Pointer, followed in the
// schema as it is now, so a part renamed or taken out loses its words' color. None of it is in the
// document: it's what the model said of a description and a schema, kept by their text
// (`SchemaHighlightAnswers`), never saved and never an undo step, since the two texts are what it
// follows from.

/// Words of a schema card's description, and the part of its schema they say.
public struct SchemaHighlight: Hashable, Sendable {
    /// The words as the description writes them.
    public var words: String
    /// Where the part is in the schema: a JSON Pointer (RFC 6901), "" for the whole schema,
    /// "/properties/key" for a field, "/properties/summary/maxLength" for a rule.
    public var pointer: String

    public init(words: String, pointer: String) {
        self.words = words
        self.pointer = pointer
    }

    /// What words say of the data: a field it has (the thing itself, a property, a list's items, a
    /// shape defined once), or a rule it keeps (a bound, a pattern, choices, what's required, an
    /// either-or, a condition).
    public enum Kind: Hashable, Sendable {
        case field, validation
    }
}

/// A highlight found in a description as it is, and its part in the schema as it is.
public struct PlacedHighlight: Equatable, Sendable {
    /// Where its words are in the description, in UTF-16, as AppKit's text ranges are.
    public var range: NSRange
    public var kind: SchemaHighlight.Kind
    public var pointer: JSONPointer
    /// Where its part is in the schema's text, in UTF-8 offsets (`JSONPointer.Target.range`).
    public var part: Range<Int>
}

/// Placing highlights in a description and a schema: pure, and nonisolated.
public enum SchemaHighlights {
    /// What words pointing there say: a field when the pointer leads, through places that hold the
    /// data (a property, a list's items, a definition), to a schema, or to what names one (its
    /// title, its description); a rule when it leads to any other keyword (a bound, a pattern,
    /// choices, `required`, `default`), or goes through one that combines schemas or conditions on
    /// them (`anyOf`, `if`, `not`).
    public static func kind(of pointer: JSONPointer) -> SchemaHighlight.Kind {
        enum Place { case schema, names, list, value }
        var place = Place.schema
        var rule = false
        for token in pointer.tokens {
            switch place {
            case .names, .list:
                place = .schema
            case .value:
                break
            case .schema:
                if namesSchemas.contains(token) {
                    place = .names
                } else if holdsData.contains(token) {
                    place = .schema
                } else if token == "prefixItems" {
                    place = .list
                } else if combines.contains(token) {
                    rule = true
                    place = .list
                } else if conditions.contains(token) {
                    rule = true
                } else {
                    if !namesIt.contains(token) { rule = true }
                    place = .value
                }
            }
        }
        return rule ? .validation : .field
    }

    /// Keywords whose members are schemas by name.
    private static let namesSchemas: Set<String> = ["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]
    /// Keywords whose value is a schema of the data's own.
    private static let holdsData: Set<String> = ["items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "additionalItems"]
    /// Keywords whose value is a list of schemas the data matches some of.
    private static let combines: Set<String> = ["allOf", "anyOf", "oneOf"]
    /// Keywords whose value is a schema the data is tested against.
    private static let conditions: Set<String> = ["not", "if", "then", "else", "contains", "propertyNames"]
    /// Keywords that name or describe the schema they're in.
    private static let namesIt: Set<String> = ["title", "description", "$comment"]

    /// Where each of `words` is in `text`, in order: the first place no earlier one holds, looked for
    /// from where the last one found ends, then from the start; at word boundaries (neither end
    /// inside a word) before anywhere; as written before ignoring case. Nil for words that aren't
    /// there (or are empty). The model lists them in the text's order, so words written twice go to
    /// their places in turn.
    public static func anchor(_ words: [String], in text: String) -> [Range<String.Index>?] {
        var placed: [Range<String.Index>] = []
        var cursor = text.startIndex
        return words.map { words in
            guard !words.isEmpty else { return nil }
            for options in [String.CompareOptions.literal, [.literal, .caseInsensitive]] {
                for start in [cursor, text.startIndex] {
                    for bounded in [true, false] {
                        var from = start
                        while from < text.endIndex, let found = text.range(of: words, options: options, range: from..<text.endIndex) {
                            if !placed.contains(where: { $0.overlaps(found) }), !bounded || isWhole(found, in: text) {
                                placed.append(found)
                                cursor = found.upperBound
                                return found
                            }
                            from = text.index(after: found.lowerBound)
                        }
                    }
                }
            }
            return nil
        }
    }

    /// Whether neither end of `range` is inside a word: at each end, the characters either side
    /// aren't both letters, digits or underscores.
    private static func isWhole(_ range: Range<String.Index>, in text: String) -> Bool {
        func wordy(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        if range.lowerBound > text.startIndex, wordy(text[text.index(before: range.lowerBound)]), wordy(text[range.lowerBound]) { return false }
        if range.upperBound < text.endIndex, wordy(text[range.upperBound]), wordy(text[text.index(before: range.upperBound)]) { return false }
        return true
    }

    /// The highlights whose words are in `description` (`anchor`) and whose pointers lead somewhere
    /// in the schema `root`, in the description's order.
    public static func place(_ highlights: [SchemaHighlight], in description: String, schema root: JSONNode) -> [PlacedHighlight] {
        let ranges = anchor(highlights.map(\.words), in: description)
        var placed: [PlacedHighlight] = []
        for (highlight, range) in zip(highlights, ranges) {
            guard let range, let pointer = JSONPointer(highlight.pointer), let target = pointer.resolve(in: root) else { continue }
            placed.append(PlacedHighlight(range: NSRange(range, in: description), kind: kind(of: pointer), pointer: pointer, part: target.range))
        }
        return placed.sorted { $0.range.location < $1.range.location }
    }

    /// A part of `schema` as a person reads it (a highlight's, `PlacedHighlight.part`): its text as
    /// written, each line after the first less the indent of the line it starts on, so it reads as
    /// though written at the left margin. Empty for a range outside the text.
    public static func fragment(_ part: Range<Int>, of schema: String) -> String {
        let bytes = Array(schema.utf8)
        guard part.lowerBound >= 0, part.upperBound <= bytes.count else { return "" }
        var lineStart = part.lowerBound
        while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
        let indent = bytes[lineStart..<part.lowerBound].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }.count
        let text = String(decoding: bytes[part], as: UTF8.self)
        guard indent > 0 else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            guard index > 0 else { return String(line) }
            return String(line.dropFirst(min(line.prefix { $0 == " " || $0 == "\t" }.count, indent)))
        }.joined(separator: "\n")
    }
}

/// What the model said each description and schema's words link to, process-wide, as a card's
/// readings are kept (`SchemaReadings`): by the pair's text (the description trimmed, as the sync
/// compares it), so undo, a copy or a file opened twice finds what it said; and each card's last
/// answer, whatever pair it was for, so a description being typed keeps the words still there.
///
/// What a card shows (`placed(for:)`, which its render and its editor read) is its pair's answer,
/// else its last, placed in its text as it is; kept per card while nothing it goes by changes
/// (its two texts, what's been said), since the canvas reads it every frame. A card read that has
/// no answer for its pair is wanted: the frame's end hands the cards wanted to the editor's
/// highlighter (`SchemaHighlightFrames`), which asks once a card is in step, so a card is asked
/// about only once it's drawn in full, not while it's out of view or drawn as a skeleton.
@MainActor
public enum SchemaHighlightAnswers {
    /// A description and its schema, as an answer is kept by.
    public struct Pair: Hashable, Sendable {
        public var prompt: String
        public var schema: String

        public init(prompt: String, schema: String) {
            self.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            self.schema = schema
        }
    }

    /// At most this many answers are kept: past it, the quarter kept longest goes.
    public static let capacity = 1024

    private static var answers: [Pair: (highlights: [SchemaHighlight], number: Int)] = [:]
    private static var latest: [ShapeID: (highlights: [SchemaHighlight], number: Int)] = [:]
    private static var answered = 0
    /// What each card read last shows, while its texts are the same and nothing's been said since.
    private struct Shown {
        let prompt: String
        let schema: String
        let answered: Int
        let placed: [PlacedHighlight]
        /// Its pair has no answer.
        let wants: Bool
        /// Where `placed` is drawn in a text box of this size, once asked (`lines(of:)`).
        var lines: (size: CGSize, rects: [[CGRect]])?
    }
    private static var shown: [ShapeID: Shown] = [:]
    private static var wanted: Set<ShapeID> = []

    /// What the model said of the pair, if it was asked this session.
    public static func answer(for pair: Pair) -> [SchemaHighlight]? { answers[pair]?.highlights }

    /// Keeps what the model said of `pair`, which card `id` was in when it was asked (the ask's
    /// `number`, in the order asked); it's the card's last answer unless one asked after it
    /// has landed.
    static func remember(_ highlights: [SchemaHighlight], for pair: Pair, card id: ShapeID, asked number: Int) {
        answered += 1
        answers[pair] = (highlights, answered)
        if answers.count > capacity {
            let old = answers.sorted { $0.value.number < $1.value.number }.prefix(capacity / 4).map(\.key)
            for key in old { answers[key] = nil }
        }
        if (latest[id]?.number ?? -1) < number { latest[id] = (highlights, number) }
    }

    /// The card's highlights, placed in its description and schema as they are (the schema's last
    /// reading that was a JSON object while it isn't one: `SchemaReadings.shown`). A card whose pair
    /// has no answer is wanted, whatever it shows meanwhile.
    public static func placed(for card: ShapeRecord<SchemaCard>) -> [PlacedHighlight] {
        let prompt = card.props.prompt, schema = card.props.schema
        let kept: Shown
        if let last = shown[card.id], last.answered == answered, last.prompt == prompt, last.schema == schema {
            kept = last
        } else {
            kept = show(card)
            shown[card.id] = kept
        }
        if kept.wants { wanted.insert(card.id) }
        return kept.placed
    }

    private static func show(_ card: ShapeRecord<SchemaCard>) -> Shown {
        let prompt = card.props.prompt, schema = card.props.schema
        let pair = Pair(prompt: prompt, schema: schema)
        let answer = answers[pair]?.highlights
        let highlights = answer ?? latest[card.id]?.highlights ?? []
        var placed: [PlacedHighlight] = []
        if !highlights.isEmpty, let root = SchemaReadings.reading(of: schema, for: card.id).shownRoot {
            placed = SchemaHighlights.place(highlights, in: prompt, schema: root)
        }
        return Shown(prompt: prompt, schema: schema, answered: answered, placed: placed, wants: answer == nil && !pair.prompt.isEmpty)
    }

    /// Where each of the card's highlights (`placed(for:)`'s, in its order) is drawn, in world units:
    /// a rect a line, where the canvas fills behind its words (`SchemaHighlightRects`), which its
    /// editor fills too, and the pointer is found on. Kept with what the card shows, for its text
    /// box's size.
    public static func lines(of card: ShapeRecord<SchemaCard>) -> [[CGRect]] {
        let placed = placed(for: card)
        guard !placed.isEmpty else { return [] }
        let box = SchemaStyle.textBox(of: card.frame)
        let rects: [[CGRect]]
        if let kept = shown[card.id]?.lines, kept.size == box.size {
            rects = kept.rects
        } else {
            rects = SchemaHighlightRects.rects(of: placed, in: card.props.prompt, size: box.size)
            shown[card.id]?.lines = (box.size, rects)
        }
        return rects.map { lines in lines.map { $0.offsetBy(dx: box.minX, dy: box.minY) } }
    }

    /// The cards read since the last call whose pairs have no answer, and none after it.
    static func takeWanted() -> Set<ShapeID> {
        defer { wanted = [] }
        return wanted
    }

    /// The part of the card's schema a placed highlight of it shows, as a person reads it
    /// (`SchemaHighlights.fragment`), cut from the text it was placed in.
    public static func fragment(of highlight: PlacedHighlight, in card: ShapeRecord<SchemaCard>) -> String {
        SchemaHighlights.fragment(highlight.part, of: SchemaReadings.reading(of: card.props.schema, for: card.id).shownText)
    }

    /// Drops what's kept of a card that went (its answers stay, by their text).
    static func forget(_ id: ShapeID) {
        latest[id] = nil
        shown[id] = nil
        wanted.remove(id)
    }

    #if DEBUG
    /// Every answer and card forgotten, for tests that need none kept from one before.
    public static func forgetEverything() {
        answers = [:]
        latest = [:]
        shown = [:]
        wanted = []
    }
    #endif
}

/// Where a frame ends, an overlay that draws nothing: it hands the cards the frame drew with no
/// answer for their pair to the editor's highlighter, which asks for those in step.
struct SchemaHighlightFrames {}

extension SchemaHighlightFrames: CanvasOverlay {
    var space: OverlaySpace { .view }
    func draw(in context: OverlayContext) {
        let wanted = SchemaHighlightAnswers.takeWanted()
        if !wanted.isEmpty { context.editor.schemaSync?.highlighter.want(wanted) }
    }
}
