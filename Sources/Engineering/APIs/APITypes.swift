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

    /// The type note a ref stands for: the one it holds; else, where its words were written before any type of that name was made
    /// (or made by another route since), the type called so, the same one wherever it's asked (the first by id).
    static func resolved(_ ref: TypeRef, types: TypeIndex?) -> ShapeID? {
        if let shape = ref.shape { return shape }
        guard let types, !ref.words.isEmpty else { return nil }
        return types.types(named: ref.words).min { $0.description < $1.description }
    }

    /// A type's pill at rest, on the paper: its name now in its color, or the words in a dashed pill while they name none.
    static func pill(_ ref: TypeRef, types: TypeIndex?) -> AdornmentLabel {
        TypeChips.label(forType: resolved(ref, types: types), named: ref.words, in: types, onPaper: true)
    }

    /// A type's name as it's called now, where its words name one; else the words.
    static func printed(_ ref: TypeRef, _ editor: CanvasEditor) -> String {
        guard let types = editor.types, let shape = resolved(ref, types: types), types.isType(shape), let name = types.name(of: shape) else { return ref.words }
        return name
    }

    /// The words of a path's last segment that isn't a parameter, in the singular (`refunds` is `refund`): a type whose name has
    /// one in it is the likelier of the types offered, and comes first among those a typed word matches alike.
    static func stems(ofPath path: String) -> [String] {
        let segments = path.split(separator: "/").filter { !$0.hasPrefix("{") }
        guard let last = segments.last else { return [] }
        let word = last.lowercased().filter { $0.isLetter }
        return word.count > 3 && word.hasSuffix("s") ? [String(word.dropLast())] : word.isEmpty ? [] : [word]
    }

    /// What fits where a type goes, `typed` so far over `range`: the file's types (each in its color's chip, its board said
    /// when it's on another, lit while highlighted), then, while what's typed names none, "New type X", an action that makes it.
    static func offers(_ typed: String, range: NSRange, quoting: Bool = false, stems: [String] = [], _ context: LineContext) -> LineOffers? {
        let editor = context.editor
        guard let types = editor.types else { return nil }
        let named = namedByAPI(context.shape, editor, types)
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
            // What the API names already, or what its path speaks of, is likelier than the rest.
            let lowered = type.name.lowercased()
            let likely = named.contains(type.id) || stems.contains { lowered.contains($0) }
            items.append(LineOffer(CaretCompletion(label: type.name, detail: detail, insert: quoting ? EndpointGrammar.written(type.name) : type.name,
                                                   isRelevant: likely, chip: TypeChips.tint(of: type.id, in: types).color),
                                   light: PartAddress(type.id)))
        }
        let name = typed.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !names.contains(name) {
            let api = context.shape
            // Last, and highlighted while no type is called so or starts so (E3: "nothing else is called so"): a type a path's stem
            // ranks first (NewRefund for `refunds`) never takes Return from the one being named.
            let lowered = name.lowercased()
            let isDefault = !names.contains { $0.lowercased().hasPrefix(lowered) }
            items.append(.action(APIStyle.newTypeOffer(name), LineAction(step: APIStyle.newTypeStep) { context in
                make(named: name, for: api, in: context.editor).map { PartAddress($0) }
            }, isDefault: isDefault))
        }
        return items.isEmpty ? nil : LineOffers(range: range, query: typed, items: items)
    }

    /// The path of the endpoint a line is of, as it's held; "" for a row not held yet.
    static func path(of context: LineContext) -> String {
        guard let row = context.row else { return "" }
        return context.editor.document[context.shape]?.typed(as: API.self)?.props.endpoints.first { $0.id == row }?.endpoint?.path ?? ""
    }

    /// The types the API names already (a body's, a response's), as it holds them now.
    static func namedByAPI(_ api: ShapeID, _ editor: CanvasEditor, _ types: TypeIndex) -> Set<ShapeID> {
        guard let record = editor.document[api]?.typed(as: API.self) else { return [] }
        var found: Set<ShapeID> = []
        for case .endpoint(let endpoint) in record.props.endpoints {
            for ref in [endpoint.body] + endpoint.responses.map(\.type) {
                if let ref, let shape = resolved(ref, types: types) { found.insert(shape) }
            }
        }
        return found
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
        // The whole line is the type's name: it may be more than one word.
        let text = line.string as NSString
        var start = 0, end = text.length
        while start < end, CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: start)) ?? " ") { start += 1 }
        while end > start, CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: end - 1)) ?? " ") { end -= 1 }
        guard end > start else { return LineReading(row: nil) }
        var range = NSRange(location: start, length: end - start)
        var name = text.substring(with: range)
        // A leading arrow, as the card prints it, isn't part of it.
        if name.hasPrefix(EndpointGrammar.arrow) || name.hasPrefix(EndpointGrammar.typedArrow) {
            let words = ColumnGrammar.placedWords(of: line.string)
            guard words.count > 1 else { return LineReading(row: nil, spans: words.map { LineSpan($0.range, .keyword) }) }
            range = NSRange(location: words[1].range.location, length: end - words[1].range.location)
            name = text.substring(with: range)
        }
        let shape = APITypes.bound(name, at: range, in: line, near: context.shape, context.editor)
        var spans = [LineSpan(range, APITypes.look(of: shape, context.editor, onPaper: onPaper))]
        if range.location > start { spans.append(LineSpan(NSRange(location: start, length: range.location - start), .keyword)) }
        return LineReading(row: TypeRef(name, shape: shape), spans: spans)
    }

    func print(_ ref: TypeRef, in context: LineContext) -> LineText {
        let name = APITypes.printed(ref, context.editor)
        let head = onPaper ? "" : "\(EndpointGrammar.arrow) "
        let start = (head as NSString).length
        guard let shape = APITypes.resolved(ref, types: context.editor.types) else { return LineText(head + name) }
        return LineText(head + name, references: [LineReference(range: NSRange(location: start, length: (name as NSString).length), target: PartAddress(shape))])
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<TypeRef>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string).filter { $0.text != EndpointGrammar.arrow && $0.text != EndpointGrammar.typedArrow }
        // The name, as far as it's typed: from its first word to the caret, over every word it has.
        guard let first = words.first, caret >= first.range.location else {
            return APITypes.offers("", range: NSRange(location: caret, length: 0), stems: stems(context), context)
        }
        let end = max(caret, NSMaxRange(words[words.count - 1].range))
        let range = NSRange(location: first.range.location, length: end - first.range.location)
        let typed = (line.string as NSString).substring(with: NSRange(location: first.range.location, length: min(caret, end) - first.range.location))
        return APITypes.offers(typed, range: range, stems: stems(context), context)
    }

    /// What its endpoint's path speaks of.
    private func stems(_ context: LineContext) -> [String] { APITypes.stems(ofPath: APITypes.path(of: context)) }

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
        func isArrow(_ word: String) -> Bool { word == EndpointGrammar.arrow || word == EndpointGrammar.typedArrow }
        // A status, first, unless the arrow is (a type alone, `→ Order`); a lone word is a status.
        // Each head word's span runs on over the space after it, so the gap is the code's, as wide as a character, not the text's.
        func headed(_ at: Int) -> NSRange {
            let end = at + 1 < words.count ? words[at + 1].range.location : NSMaxRange(words[at].range)
            return NSRange(location: words[at].range.location, length: end - words[at].range.location)
        }
        if !isArrow(words[0].text), EndpointGrammar.isStatus(words[0].text) || words.count == 1 {
            response.status = words[0].text
            spans.append(LineSpan(headed(0), .code))
            index = 1
        }
        if index < words.count, isArrow(words[index].text) {
            spans.append(LineSpan(headed(index), .keyword))
            index += 1
        }
        if index < words.count {
            // What's left is the type's name, all of it, whatever words it has.
            let first = words[index], last = words[words.count - 1]
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let name = (line.string as NSString).substring(with: range)
            let shape = APITypes.bound(name, at: range, in: line, near: context.shape, context.editor)
            response.type = TypeRef(name, shape: shape)
            spans.append(LineSpan(range, APITypes.look(of: shape, context.editor, onPaper: false)))
        }
        return LineReading(row: response, spans: spans)
    }

    func print(_ response: EndpointResponse, in context: LineContext) -> LineText {
        guard let type = response.type, !type.words.isEmpty else { return LineText(response.status) }
        let name = APITypes.printed(type, context.editor)
        // The arrow is there with a status or without (`→ Order` is a type alone), so it reads back as it was.
        let head = response.status.isEmpty ? "\(EndpointGrammar.arrow) " : "\(response.status) \(EndpointGrammar.arrow) "
        let start = (head as NSString).length
        let references = APITypes.resolved(type, types: context.editor.types).map { [LineReference(range: NSRange(location: start, length: (name as NSString).length), target: PartAddress($0))] } ?? []
        return LineText(head + name, references: references)
    }

    func offers(at caret: Int, in line: LineText, reading: LineReading<EndpointResponse>, context: LineContext) -> LineOffers? {
        let words = ColumnGrammar.placedWords(of: line.string)
        func isArrow(_ word: String) -> Bool { word == EndpointGrammar.arrow || word == EndpointGrammar.typedArrow }
        // Where a type goes: past the status (the arrow typed or not), or past the arrow alone.
        var head = 0
        if let first = words.first {
            if isArrow(first.text) {
                head = 1
            } else if EndpointGrammar.isStatus(first.text) {
                head = words.count > 1 && isArrow(words[1].text) ? 2 : 1
            }
        }
        guard head > 0, caret > NSMaxRange(words[head - 1].range) else { return nil }
        let stems = APITypes.stems(ofPath: APITypes.path(of: context))
        guard let first = words.dropFirst(head).first, caret >= first.range.location else {
            return APITypes.offers("", range: NSRange(location: caret, length: 0), stems: stems, context)
        }
        let end = max(caret, NSMaxRange(words[words.count - 1].range))
        let range = NSRange(location: first.range.location, length: end - first.range.location)
        let typed = (line.string as NSString).substring(with: NSRange(location: first.range.location, length: min(caret, end) - first.range.location))
        guard !EndpointGrammar.isStatusPrefix(typed) else { return nil }
        return APITypes.offers(typed, range: range, stems: stems, context)
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
