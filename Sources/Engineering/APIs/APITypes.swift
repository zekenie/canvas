import Adornments
import AppKit
import Canvas
import LineRows
import Mentions
import Palette
import TextEditing
import Types

// An endpoint's body and responses are typed notes, the app's own types (Types'): a `TypeRef`, the words as typed and the type
// note they name once one matches. What those words bind to (the run a line carries, else a type of that name nearest the API),
// how they look (the type's live name in its color's pill, dashed while they name none), what a line offers where a type goes
// (the file's types, and "New type X" last, an action), and the note it makes: in one step with the words that name it, beside
// the types the API names already (else beside the API), put down settled, so the caret stays where it is. Naming a type makes
// a pill, never an arrow (decided 24).

@MainActor
enum APITypes {
    /// The type note words name: the run's reference, where the line carries one that is a type; else the type called so nearest
    /// `shape` (on its board, else anywhere in the file). Nil without Types, or where none is called so.
    static func bound(_ words: String, at range: NSRange, in line: LineText, near shape: ShapeID, _ editor: CanvasEditor) -> ShapeID? {
        guard let types = editor.types, !words.isEmpty else { return nil }
        if let target = line.reference(at: range), types.isType(target.shape) { return target.shape }
        return named(words, near: shape, editor)
    }

    /// The type called `words` nearest `shape`: on its board, else the first of the file's in a fixed order.
    static func named(_ words: String, near shape: ShapeID, _ editor: CanvasEditor) -> ShapeID? {
        guard let types = editor.types else { return nil }
        let found = types.types(named: words)
        guard !found.isEmpty else { return nil }
        let board = editor.file.board(containing: shape)
        return found.first { editor.file.board(containing: $0) == board } ?? found.min { $0.description < $1.description }
    }

    /// How a type's words look in a line: in the type's pill (its color faint behind its name, in its ink) once they name one,
    /// else a dashed grey pill. `onPaper`: on an API's paper, light in both appearances (else a card's bubble, which follows it).
    static func look(of shape: ShapeID?, _ editor: CanvasEditor, onPaper: Bool) -> LineLook {
        guard let shape, let types = editor.types, types.isType(shape) else {
            return .dashedPill(onPaper ? NSColor(KitStyle.secondaryInk) : .secondaryLabelColor, ink: onPaper ? NSColor(KitStyle.secondaryInk) : .secondaryLabelColor)
        }
        let tint = TypeChips.tint(of: shape, in: types, onPaper: onPaper)
        return .pill(tint.color.withAlphaComponent(APIStyle.pillFill), ink: tint.ink)
    }

    /// A type's pill at rest, on the paper: its name now in its color, or the words in a dashed pill while they name none.
    static func pill(_ ref: TypeRef, _ editor: CanvasEditor?, types: TypeIndex?) -> AdornmentLabel {
        TypeChips.label(forType: ref.shape, named: ref.words, in: types, onPaper: true)
    }

    /// A type's name as it's called now, where its words name one; else the words.
    static func printed(_ ref: TypeRef, _ editor: CanvasEditor) -> String {
        guard let shape = ref.shape, let types = editor.types, types.isType(shape), let name = types.name(of: shape) else { return ref.words }
        return name
    }

    /// What fits where a type goes, `typed` so far over `range`: the file's types (each in its color's chip, its board said
    /// when it's on another, lit while highlighted), then, while what's typed names none, "New type X", an action that makes it.
    static func offers(_ typed: String, range: NSRange, _ context: LineContext) -> LineOffers? {
        let editor = context.editor
        guard let types = editor.types else { return nil }
        let board = editor.file.board(containing: context.shape)
        var items: [LineOffer] = []
        var names: Set<String> = []
        let sorted = types.types.compactMap { id in types.name(of: id).map { (id: id, name: $0) } }
            .sorted { a, b in
                let near = (editor.file.board(containing: a.id) == board, editor.file.board(containing: b.id) == board)
                if near.0 != near.1 { return near.0 }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        for type in sorted where names.insert(type.name).inserted {
            let elsewhere = editor.file.board(containing: type.id) != board
            let detail = elsewhere ? editor.mentions?.boardName(ofShape: type.id) ?? "" : ""
            items.append(LineOffer(CaretCompletion(label: type.name, detail: detail, insert: type.name, chip: TypeChips.tint(of: type.id, in: types).color),
                                   light: PartAddress(type.id)))
        }
        let name = typed.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !names.contains(name) {
            let api = context.shape
            items.append(.action(APIStyle.newTypeOffer(name), LineAction(step: APIStyle.newTypeStep) { context in
                make(named: name, for: api, in: context.editor).map { PartAddress($0) }
            }))
        }
        return items.isEmpty ? nil : LineOffers(range: range, query: typed, items: items)
    }

    /// A type note called `name`, made for the API `api`: beside the types it names already that are on the board shown (else
    /// beside it), made an instance of nothing and edited by no one (put down settled), in Types' step, "New Type", which the
    /// words that name it then join. Nil where none could be made.
    static func make(named name: String, for api: ShapeID, in editor: CanvasEditor) -> ShapeID? {
        let board = editor.board
        var named: [ShapeID] = []
        if let record = editor.document[api]?.typed(as: API.self), let types = editor.types {
            for row in record.props.endpoints {
                guard let endpoint = row.endpoint else { continue }
                for ref in [endpoint.body] + endpoint.responses.map(\.type) {
                    guard let shape = ref?.shape, types.isType(shape), editor.file.board(containing: shape) == board, !named.contains(shape) else { continue }
                    named.append(shape)
                }
            }
        }
        return editor.newType(named: name, besides: named.isEmpty ? [api] : named, givingType: false, editing: false)
    }
}

// MARK: A type's words, in a card

/// A body's type, in an endpoint's card: the type's words in its pill (dashed while they name none); the file's types offered,
/// "New type X" last.
struct TypeNameGrammar: LineGrammar {
    /// On the paper (a line of the API) or on a card's bubble.
    var onPaper = false

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<TypeRef> {
        let words = ColumnGrammar.placedWords(of: line.string)
        guard let first = words.first else { return LineReading(row: nil) }
        let shape = APITypes.bound(first.text, at: first.range, in: line, near: context.shape, context.editor)
        var spans = [LineSpan(first.range, APITypes.look(of: shape, context.editor, onPaper: onPaper))]
        spans += words.dropFirst().map { LineSpan($0.range, .plain) }
        return LineReading(row: TypeRef(words.map(\.text).joined(separator: " "), shape: shape), spans: spans)
    }

    func print(_ ref: TypeRef, in context: LineContext) -> LineText {
        let name = APITypes.printed(ref, context.editor)
        guard let shape = ref.shape else { return LineText(name) }
        return LineText(name, references: [LineReference(range: NSRange(location: 0, length: (name as NSString).length), target: PartAddress(shape))])
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<TypeRef>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        guard (at ?? words.filter { NSMaxRange($0.range) < caret }.count) == 0 else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        return APITypes.offers(typed, range: range, context)
    }

    func spoken(_ ref: TypeRef, in context: LineContext) -> String { APITypes.printed(ref, context.editor) }
}

/// A response, in an endpoint's card: `201 → Refund`, `404`, `409 Problem` (the arrow may be left out): its status in code, its
/// type's words in their pill; the file's types offered after the status, "New type X" last.
struct ResponseGrammar: LineGrammar {
    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<EndpointResponse> {
        let words = ColumnGrammar.placedWords(of: line.string)
        guard !words.isEmpty else { return LineReading(row: nil) }
        var response = EndpointResponse(status: "")
        var spans: [LineSpan] = []
        var index = 0
        if EndpointGrammar.isStatus(words[0].text) || words.count == 1 {
            response.status = words[0].text
            spans.append(LineSpan(words[0].range, .code))
            index = 1
        }
        if index < words.count, words[index].text == EndpointGrammar.arrow || words[index].text == EndpointGrammar.typedArrow {
            spans.append(LineSpan(words[index].range, .keyword))
            index += 1
        }
        if index < words.count {
            let rest = words[index...]
            let typeWords = rest.map(\.text).joined(separator: " ")
            let shape = APITypes.bound(rest.first!.text, at: rest.first!.range, in: line, near: context.shape, context.editor)
            response.type = TypeRef(typeWords, shape: rest.count == 1 ? shape : nil)
            spans.append(LineSpan(rest.first!.range, APITypes.look(of: rest.count == 1 ? shape : nil, context.editor, onPaper: false)))
            spans += rest.dropFirst().map { LineSpan($0.range, .plain) }
        }
        return LineReading(row: response, spans: spans)
    }

    func print(_ response: EndpointResponse, in context: LineContext) -> LineText {
        guard let type = response.type, !type.words.isEmpty else { return LineText(response.status) }
        let name = APITypes.printed(type, context.editor)
        let head = response.status.isEmpty ? "" : "\(response.status) \(EndpointGrammar.arrow) "
        let start = (head as NSString).length
        let references = type.shape.map { [LineReference(range: NSRange(location: start, length: (name as NSString).length), target: PartAddress($0))] } ?? []
        return LineText(head + name, references: references)
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<EndpointResponse>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        let at = words.firstIndex { caret >= $0.range.location && caret <= NSMaxRange($0.range) }
        let index = at ?? words.filter { NSMaxRange($0.range) < caret }.count
        // After the status (and its arrow, if typed): where a type goes.
        let before = words.prefix(index).map(\.text).filter { $0 != EndpointGrammar.arrow && $0 != EndpointGrammar.typedArrow }
        guard before.count == 1, EndpointGrammar.isStatus(before[0]) else { return nil }
        let range = at.map { words[$0].range } ?? NSRange(location: caret, length: 0)
        let typed = at.map { String(words[$0].text.utf16.prefix(caret - words[$0].range.location)) ?? "" } ?? ""
        return APITypes.offers(typed, range: range, context)
    }

    var substitutions: [LineSubstitution] { [LineSubstitution(EndpointGrammar.typedArrow, becomes: EndpointGrammar.arrow)] }

    func spoken(_ response: EndpointResponse, in context: LineContext) -> String {
        [response.status, response.type.map { APITypes.printed($0, context.editor) } ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Words as typed, one line (a name, a summary, a parameter's type, a scope): `code` for code.
struct WordsGrammar: LineGrammar {
    var code = false

    func read(_ line: LineText, id: PartID, in context: LineContext) -> LineReading<String> {
        let text = line.string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return LineReading(row: nil) }
        return LineReading(row: text, spans: code ? ColumnGrammar.placedWords(of: line.string).map { LineSpan($0.range, .code) } : [])
    }

    func print(_ text: String, in context: LineContext) -> LineText { LineText(text) }

    func spoken(_ text: String, in context: LineContext) -> String { text }
}
