import Canvas
import DrawScript
import QueryLanguage
import Topology

// What a refusal says, in the query's own terms: the words for what an attribute is and what it
// takes, "Did you mean", and the hints built from what this app has, which the language can't give
// (it knows no kind): a pseudo-class named like an attribute is that attribute in brackets, one named
// like a kind is the kind, and a near miss of any word, the language's or a plugin's, is that word.

extension QueryVocabulary {
    /// Why a pseudo-class no plugin adds and the language hasn't is refused: what people reach for
    /// (`KnownInventions`), an attribute of the compound's kinds (`:flag` is `[flag]`), a kind
    /// (`:chore` is `chore`), a near miss of a word, or nothing it resembles.
    func unknownWord(_ pseudo: PseudoClass, attributes: [String]) -> QueryError {
        if let invented = KnownInventions.error(for: pseudo) { return invented }
        let name = pseudo.name
        let message = ":\(name) isn't a pseudo-class."
        if let attribute = attributes.first(where: { asciiLowercased($0) == name }) {
            return QueryError(.unknownPseudoClass, message, hint: "Attributes are tested in brackets: [\(attribute)].", span: pseudo.span)
        }
        if let kind = kinds.first(where: { asciiLowercased($0.kind.rawValue) == name }) {
            return QueryError(.unknownPseudoClass, message, hint: "A kind starts its part of the query: \(kind.kind).", span: pseudo.span)
        }
        if let guess = Suggestions.closest(to: name, among: words.map(\.word), limit: 1).first,
           let word = words.first(where: { $0.word == guess }) {
            return QueryError(.unknownPseudoClass, message, hint: "Did you mean :\(guess)? \(word.form): \(word.summary).", span: pseudo.nameSpan)
        }
        return QueryError(.unknownPseudoClass, message, span: pseudo.nameSpan)
    }

    /// A kind as a hint names it: its id, and what the app calls it when that's something else:
    /// `chore (a Task)`.
    func called(_ kind: ShapeKind) -> String {
        guard let entry = self.kind(kind), entry.label != kind.rawValue else { return kind.rawValue }
        return "\(kind) (\(indefinite(entry.label)))"
    }

    /// Up to 3 kinds a word that isn't one was probably meant as: by their ids and by what the app
    /// calls them (`note` is a Note), each once, best first.
    func kindsLike(_ word: String) -> [ShapeKind] {
        let candidates = kinds.flatMap { [$0.kind.rawValue, $0.label] }
        let owners = kinds.flatMap { [$0.kind, $0.kind] }
        var found: [ShapeKind] = []
        for guess in Suggestions.closest(to: word, among: candidates, limit: 6) {
            for (index, candidate) in candidates.enumerated() where candidate == guess && !found.contains(owners[index]) {
                found.append(owners[index])
            }
        }
        return Array(found.prefix(3))
    }

    /// The kinds whose shapes can have shapes inside them (a board of them, or shapes on theirs), as
    /// a hint lists them; nil for none.
    var containersListed: String? {
        let holders = kinds.filter(\.holdsShapes).map(\.kind.rawValue)
        return holders.isEmpty ? nil : "The kinds that hold shapes: \(holders.joined(separator: ", "))."
    }

    /// Whether some kind has an attribute of this name (the names point's word too).
    public func isAttribute(_ name: String) -> Bool {
        kinds.contains { $0.attribute(name) != nil }
    }

    /// The attribute some kind has that a name no kind has was probably meant as; nil for none like
    /// it.
    public func attribute(like name: String) -> String? {
        Suggestions.closest(to: name, among: Set(kinds.flatMap { $0.attributes.map(\.name) }).sorted(), limit: 1).first
    }

    /// Edge types as a query writes them, exactly: a type whose every type under it is among them by
    /// its name alone, which takes those in, and one without them all as `only` it (a relation's
    /// types are only those it names); in the tree's order, then those nobody declares. Each with
    /// its type, for the words that name it.
    func written(_ types: Set<EdgeTypeID>) -> [(term: String, type: EdgeTypeID)] {
        var terms: [(term: String, type: EdgeTypeID)] = [], covered: Set<EdgeTypeID> = []
        for type in edgeTypes.map(\.type) where types.contains(type) && !covered.contains(type) {
            let under = edgeTree.descendants(of: type)
            if under.allSatisfy(types.contains) {
                terms.append((type.rawValue, type))
                covered.formUnion(under)
            } else {
                terms.append(("\(Keyword.only.rawValue) \(type.rawValue)", type))
            }
        }
        let undeclared = types.filter { !edgeTree.isDeclared($0) }.sorted { $0.rawValue < $1.rawValue }
        return terms + undeclared.map { ($0.rawValue, $0) }
    }

    // MARK: Hints that wait on what the app has

    /// A refusal whose hints wait on what only the app can say (`HintPremise`), settled as far as
    /// the kinds, the shapes the app has now by id (`kindOf`) and, once read, the titles (`titled`:
    /// the kinds of the shapes each folded title names; nil before they're read) say. A `:has()`
    /// combinator's form, whose shapes can hold none, leaves its hint to the kinds that can.
    func settled(_ error: QueryError, kindOf: (ShapeID) -> ShapeKind?, titled: [String: Set<ShapeKind>]?) -> QueryError {
        func one(_ problem: QueryError) -> QueryError {
            guard let premise = problem.premise, let verdict = holds(premise.claim, kindOf: kindOf, titled: titled) else { return problem }
            var settled = problem.settled { _ in verdict }
            if verdict, case .typeWord(let name) = premise.claim, let word = typeWord { settled.hint = ":\(word)(\(quoted(name)))" }
            if !verdict, settled.hint == nil, case .holdShapes = premise.claim { settled.hint = containersListed }
            return settled
        }
        var settled = one(error)
        settled.errors = error.errors.map(one)
        return settled
    }

    /// The titles, folded, whose shapes a refusal's hints wait on.
    func titlesAwaited(by error: QueryError) -> Set<String> {
        var titles: Set<String> = []
        for problem in [error] + error.errors {
            switch problem.premise?.claim {
            case .titled(let title)?:
                titles.insert(fold(title))
            case .holdShapes(let compounds)?:
                for compound in compounds { if case .title(let title, _)? = compound.head { titles.insert(fold(title)) } }
            case .typeWord(let name)? where typeWord != nil && naming != nil:
                titles.insert(fold(name))
            case .typeWord?, .namedKind?, nil:
                break
            }
        }
        return titles
    }

    /// Whether a claim holds: nil where only what isn't known yet could say.
    private func holds(_ claim: HintPremise.Claim, kindOf: (ShapeID) -> ShapeKind?, titled: [String: Set<ShapeKind>]?) -> Bool? {
        switch claim {
        case .titled(let title):
            return titled.map { !($0[fold(title)] ?? []).isEmpty }
        case .holdShapes(let compounds):
            var verdict: Bool? = true
            for compound in compounds {
                switch holdsShapes(compound, kindOf: kindOf, titled: titled) {
                case false?: return false
                case nil: verdict = nil
                case true?: break
                }
            }
            return verdict
        case .namedKind(let name):
            guard let entry = kind(ShapeKind(rawValue: name)) else { return true }
            return naming != nil && entry.names != QueryNameSource.none
        case .typeWord(let name):
            // A word that finds a type's shapes, and a shape titled so for it to name.
            guard typeWord != nil, naming != nil else { return false }
            return titled.map { !($0[fold(name)] ?? []).isEmpty }
        }
    }

    /// The word that names types (the relation declared `namesTypes`), if the app has one: what
    /// `.Task` is written as, `:is-a("Task")`.
    var typeWord: String? {
        contributedWords.values.first { declared in
            if case .fileRelation(let relation) = declared.meaning { relation.namesTypes } else { false }
        }?.word
    }

    /// Whether a compound can hold shapes, by its head: a kind that holds shapes (with a title or
    /// not), a shape of one by its id, a title some shape of one has; `*` or none can't be known, so
    /// it may. Nil for a kind or an id that isn't one, whose own refusal is the query's, and a title
    /// before the titles are read, or that no shape has.
    private func holdsShapes(_ compound: Compound, kindOf: (ShapeID) -> ShapeKind?, titled: [String: Set<ShapeKind>]?) -> Bool? {
        switch compound.head {
        case .kind(let name, _)?, .kindTitle(let name, _, _, _)?:
            let kind = ShapeKind(rawValue: name)
            return self.kind(kind) == nil ? nil : containerKinds.contains(kind)
        case .id(let id, _)?:
            return kindOf(ShapeID(id)).flatMap { self.kind($0) == nil ? nil : containerKinds.contains($0) }
        case .title(let title, _)?:
            guard let kinds = titled?[fold(title)], !kinds.isEmpty else { return nil }
            return !kinds.isDisjoint(with: containerKinds)
        case .any?, nil:
            return true
        }
    }

    /// A title as names are matched: folded by the names point.
    private func fold(_ title: String) -> String { naming?.fold(title) ?? title }
}

/// Why a shape of a kind that holds no shapes contains nothing, whatever's drawn over it.
let notDrawnWithin = "Being drawn within its bounds isn't something a query can ask yet."

// MARK: Attributes' types

extension KindSchema.PropertyShape {
    /// What an attribute is, after "is": `text`, `a number`, `one of todo|doing|blocked|done`.
    func what(compactType: String) -> String {
        switch self {
        case .string(let format, _, let choices):
            if choices != nil { return "one of \(compactType)" }
            return format == KindSchema.dateTime ? "a date" : "text"
        case .number(let integer): return integer ? "a whole number" : "a number"
        case .boolean: return "true or false"
        case .array: return "a list"
        case .object: return "an object"
        case .json: return "any JSON"
        }
    }
}

/// What a property takes, as a hint says it after "takes": `a number`, `an integer ≥ 0`, `text
/// (≤ 80)`, `true|false`, from its compact type.
func takes(_ compactType: String) -> String {
    for word in ["number", "integer", "date"] where compactType.hasPrefix(word) {
        return indefinite(compactType)
    }
    return compactType
}

// MARK: Words

/// `a` or `an`, and the word.
func indefinite(_ word: String) -> String {
    (word.first.map { "aeiouAEIOU".contains($0) } ?? false ? "an " : "a ") + word
}

/// `a`, `a or b`, `a, b or c` (or `and`).
func listed(_ items: [String], or: Bool = true) -> String {
    guard let last = items.last else { return "" }
    return items.count == 1 ? last : "\(items.dropLast().joined(separator: ", ")) \(or ? "or" : "and") \(last)"
}

/// "Did you mean a or b?", or nil for no guesses.
func didYouMean(_ guesses: [String]) -> String? {
    guesses.isEmpty ? nil : "Did you mean \(listed(guesses))?"
}

/// In double quotes, as the language writes a string: `"`, `\` and line breaks escaped.
func quoted(_ text: String) -> String {
    var out = "\""
    for character in text {
        switch character {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        default: out.append(character)
        }
    }
    return out + "\""
}

/// Lowercased, ASCII letters only, as the language folds its own words.
func asciiLowercased(_ text: String) -> String {
    String(text.map { $0.isASCII ? Character($0.lowercased()) : $0 })
}

/// Joined by spaces, when both say something.
func sentences(_ parts: String?...) -> String? {
    let said = parts.compactMap { $0 }.filter { !$0.isEmpty }
    return said.isEmpty ? nil : said.joined(separator: " ")
}
