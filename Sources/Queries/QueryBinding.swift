import QueryLanguage

// What a query may be bound to when it is asked, and the words that name it: `:scope`, the shape a
// request is about, and `:scope-start` and `:scope-end`, where the connection that shape carries
// starts and ends. A rule on a type has phrases whose stored query finds shapes relative to the
// shape the rule checks; many shapes are checked at once, so every phrase of every shape runs in one
// `matches` batch, each request bound to its own shape (`QueryMatchRequest.scope`).
//
// The words are the engine's own: not the language's (`Word`: `query-vocabulary` would advertise
// words `canvas query` always refuses), and not a plugin's (`QueryWords` prepares a word once for a
// whole batch, in the first request's view, while a binding is each request's own). A caller that
// binds nothing, as `canvas query`, a stored query and `--ask` don't, has them refused.

/// What a query is asked about, besides the file: a thing its words may name that the asker binds.
/// A query that uses a word bound to something the asker didn't bind is refused (`unsupported`).
public enum QueryBinding: Hashable, Sendable {
    /// A shape: `:scope` is that shape, `:scope-start` where the connection it carries starts and
    /// `:scope-end` where it ends. Each request of a batch has its own (`QueryMatchRequest.scope`).
    case scope
}

/// The words a query binds per request, written without the colon.
///
/// - `:scope` is `#<the bound id>`: that exact shape (no forwarding through a stand-in, so a pill
///   bound is the pill), and nothing if it isn't one the query ranges over.
/// - `:scope-start` is `:start-of(:scope)` and `:scope-end` is `:end-of(:scope)`, for every edge
///   type, in the request's edge view: where the bound shape's connection (the edge it carries in
///   slot "") starts and ends, and the empty set for a shape that carries none. In the resolved view
///   a stand-in at an end gives what it stands for, as `:start-of(#id)` does.
///
/// They test a compound (`:scope`, `chore:not(:scope)`, `link:starts-at(:scope-start)`) and are the
/// anchor of an edge word (`chore:connected-to(:scope)`, `:end-of(:scope)`). The plan keeps the
/// word, never the id, so one plan answers every request that carries its text.
enum ScopeWord: String, Sendable {
    case scope
    case start = "scope-start"
    case end = "scope-end"

    /// As a query writes it.
    var written: String { ":\(rawValue)" }

    /// What the asker must bind for the word to mean anything.
    var needs: QueryBinding { .scope }

    /// Whether it reads the connection ends (Topology's edges, which a stand-in may still be
    /// answering), as an edge word does; `:scope` reads the bound id alone.
    var readsEdges: Bool { self != .scope }
}

/// A use of a word bound per request in a query: which, and where.
struct PlanScopeUse: Sendable, Equatable {
    let word: ScopeWord
    let span: QuerySpan
}

extension QueryPlan {
    /// Whether it uses `:scope`, `:scope-start` or `:scope-end`, which a request answers only with a
    /// shape bound to it (`QueryMatchRequest.scope`, `QueryBinding.scope`). The words read only the
    /// file and the bound id: they are no `editorWords`, `readsOnlyTheFile` holds, and only the
    /// connection ends (`:scope-start`, `:scope-end`) make it `readsEdges`.
    public var usesScope: Bool { !uses.scope.isEmpty }

    /// Why it can't be asked with `binding`: each use of a word that needs something else bound,
    /// in the order the query writes them, refused `unsupported` where it stands. Nil when nothing
    /// it uses is unbound, and for a query that uses no such word.
    func unbound(by binding: QueryBinding?) -> QueryError? {
        let missing = uses.scope.filter { $0.word.needs != binding }.sorted { $0.span.offset < $1.span.offset }
        guard !missing.isEmpty else { return nil }
        return QueryError(collecting: missing.map { QueryError.unbound($0.word, span: $0.span) })
    }
}

extension QueryError {
    /// A word bound per request, used in a query asked with nothing bound to it: what `check` and
    /// `run` (so `canvas query`) say of `:scope`. As a stored query's word that reads the editor is
    /// refused (`unsupported`, `cantBeUsed`), with the word's own place.
    static func unbound(_ word: ScopeWord, span: QuerySpan) -> QueryError {
        QueryError(.unsupported, cantBeUsed(word.written),
                   hint: "`:scope` is the shape a query is asked about, and this one is asked about none.", span: span)
    }
}

extension QueryMatchRequest {
    /// What the request binds: its scope, if it has one.
    var binding: QueryBinding? { scope == nil ? nil : .scope }
}
