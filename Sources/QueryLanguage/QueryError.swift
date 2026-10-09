/// Why a query can't be answered: a reason to branch on, a message in the query's own terms, a hint
/// when there's a fix (usually the query to write), and where in the query it is. The message is
/// the problem; the hint, what to write instead.
public struct QueryError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Every reason a query can be refused, as the command line reports it. This module gives the
    /// syntactic ones (`emptyQuery` through `notBuilt`, `notAnID`, and `badArgument` for the
    /// language's own words); the caller the rest.
    public enum Reason: String, Sendable, CaseIterable {
        case emptyQuery = "empty_query"
        case syntax
        case straySpace = "stray_space"
        case tooLong = "too_long"
        case tooComplex = "too_complex"
        case unsupported
        case notBuilt = "not_built"
        case unknownKind = "unknown_kind"
        case unknownAttribute = "unknown_attribute"
        case unknownPseudoClass = "unknown_pseudo_class"
        case unknownEdgeType = "unknown_edge_type"
        case unknownTitle = "unknown_title"
        case unknownID = "unknown_id"
        case notAnID = "not_an_id"
        case invalidValue = "invalid_value"
        case unsupportedOperator = "unsupported_operator"
        case badArgument = "bad_argument"
        case cannotContain = "cannot_contain"
        case noNames = "no_names"
        case noTopology = "no_topology"
        case tooSlow = "too_slow"
        case cancelled
        case boardClosed = "board_closed"
    }

    public var reason: Reason
    public var message: String
    /// What's safe to say without knowing what only the app can say (`premise`).
    public var hint: String?
    /// A better hint than `hint`, which holds only if something the language can't tell does: the
    /// caller, which knows the kinds and the file, settles it (`settled(by:)`). Nil for none, and
    /// once settled.
    public var premise: HintPremise?
    /// Where in the query it is; nil for what's about no part of it (an empty query, a timeout).
    public var span: QuerySpan?
    /// Several at once, this one first; empty when it's alone. Reading stops at the first syntax
    /// error; resolution collects every problem that doesn't depend on another.
    public var errors: [QueryError]

    public init(_ reason: Reason, _ message: String, hint: String? = nil, premise: HintPremise? = nil, span: QuerySpan? = nil) {
        self.reason = reason
        self.message = message
        self.hint = hint
        self.premise = premise
        self.span = span
        self.errors = []
    }

    /// Several problems as one error: the first leads, and `errors` holds them all (each alone, up
    /// to `QueryLimits.errors`), in the order given. One is itself. Never empty.
    public init(collecting problems: [QueryError]) {
        precondition(!problems.isEmpty, "a collected error has at least one problem")
        let alone = problems.flatMap { $0.errors.isEmpty ? [$0] : $0.errors }.prefix(QueryLimits.errors).map { problem in
            var problem = problem
            problem.errors = []
            return problem
        }
        self = alone[0]
        if alone.count > 1 { errors = Array(alone) }
    }

    /// Where the span is in `text` (the query it's about, as sent): its line from 1; the line as
    /// written, without its line break (`statement`); and the span's column in it from 1, in
    /// Characters, and its length there, so a caret under `statement` fits it. A line longer than
    /// `quoting` characters is quoted in part: that many of its characters, a quarter of them
    /// before the span's start (its last ones, when that would run past its end), with "…" where
    /// it's cut, the column and length in what's quoted. So a caret under it still lands on what's
    /// wrong, and a query of 10,000 characters on a line is neither quoted whole nor marked with
    /// thousands of carets. Nil without a span, or with one outside the text.
    public func located(in text: String, quoting most: Int = .max) -> (line: Int, column: Int, length: Int, statement: String)? {
        guard let span, span.offset >= 0, span.length >= 0 else { return nil }
        let characters = Array(text)
        guard span.offset <= characters.count else { return nil }
        var line = 1
        var lineStart = 0
        for index in 0..<span.offset where characters[index].isNewline {
            line += 1
            lineStart = index + 1
        }
        var lineEnd = span.offset
        while lineEnd < characters.count, !characters[lineEnd].isNewline { lineEnd += 1 }
        // What's quoted, which holds the span's start.
        var start = lineStart, end = lineEnd
        if most > 0, lineEnd - lineStart > most {
            start = max(lineStart, min(span.offset - most / 4, lineEnd - most))
            end = start + most
        }
        let cutBefore = start > lineStart, cutAfter = end < lineEnd
        let statement = (cutBefore ? "…" : "") + String(characters[start..<end]) + (cutAfter ? "…" : "")
        return (line, span.offset - start + 1 + (cutBefore ? 1 : 0), min(span.length, end - span.offset), statement)
    }

    public var description: String {
        "\(reason.rawValue): \(message)" + (hint.map { " (\($0))" } ?? "")
    }

    /// The refusal, and each of `errors`, with its premise settled by what `holds` says of its
    /// claim: its hint the premise's where the claim holds, as it was where it doesn't, and the
    /// premise kept where `holds` can't say (nil).
    public func settled(by holds: (HintPremise.Claim) -> Bool?) -> QueryError {
        var settled = settledAlone(by: holds)
        settled.errors = errors.map { $0.settledAlone(by: holds) }
        return settled
    }

    private func settledAlone(by holds: (HintPremise.Claim) -> Bool?) -> QueryError {
        guard let premise, let verdict = holds(premise.claim) else { return self }
        var settled = self
        settled.premise = nil
        if verdict { settled.hint = premise.hint }
        return settled
    }
}

/// A hint that holds only if something only the app can say does: that shapes the hint puts where a
/// container goes can hold shapes (a stray space's form for a shape inside, a combinator in `:has()`
/// written as a `:has` of its own, a word people invent for `:inside`), that a shape is titled so (a
/// word that isn't a kind, which may be a title without its quotes; `#` or `@` before a word), or
/// that a kind's shapes can have titles (a kind and a title written the other way round), or that the
/// app has a word for a type's shapes (`.Task`). A hint
/// that is a query is never one the app would refuse for a reason the query it mends didn't have,
/// so one that could be waits for the caller's word (`QueryError.settled(by:)`).
public struct HintPremise: Sendable, Equatable {
    /// What the hint takes for granted.
    public enum Claim: Sendable, Equatable {
        /// Each of these can hold shapes: some shape it matches is of a kind that holds shapes (a
        /// board of them, or shapes on its own).
        case holdShapes([Compound])
        /// Some shape the query ranges over is titled this, as written.
        case titled(String)
        /// The shapes of the kind named so can have titles (a word that isn't a kind is the query's
        /// own, and its refusal the query's).
        case namedKind(String)
        /// The word, as written after a dot (`.Task`), names a type: the app declares a word that
        /// finds the shapes of a type (a relation declared `namesTypes`), so the hint is that word
        /// with the name as its argument. The premise's `hint` is nil: the caller writes it, since
        /// only it knows the word.
        case typeWord(String)
    }

    public var claim: Claim
    /// The hint once the claim holds.
    public var hint: String?

    public init(_ claim: Claim, hint: String?) {
        self.claim = claim
        self.hint = hint
    }
}
