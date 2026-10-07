/// Pseudo-classes people and models reach for that the language doesn't have, and what to write
/// instead: containment's X-of words (the shape data-canvas measured models confusing), CSS's
/// structural and user-action words, data-canvas's old words, a design's that wasn't taken and the
/// language's own old `:neighbor-of`, and the spatial words, planned. Data, for the caller's
/// refusal of a word no plugin adds (the parser refuses `:nth-*` itself), and for its check that no
/// plugin adds one of them.
///
/// No word here is a plugin's id, and no hint names a kind or an attribute but `[text]`: a hint
/// built from what an app has (`:locked` read as `[locked]`, a word named like a kind, a near miss)
/// is the caller's, made at run time.
public enum KnownInventions {
    /// What an invented word is, and what to write.
    public struct Invention: Sendable, Equatable {
        public let reason: QueryError.Reason
        public let message: String
        /// What to write instead, `…` standing for the word's argument; nil when nothing says it.
        public let write: String?
        /// Whether `write` puts the argument where a container goes (`:inside(…)`, `… > *`), so the
        /// hint holds only where what it names can hold shapes.
        public var holding = false

        /// The hint: `write` with the argument put in its place, or `…` left for one without.
        public func hint(argument: String?) -> String? {
            guard let write else { return nil }
            guard let argument, !argument.isEmpty else { return write }
            return write.split(separator: "…", omittingEmptySubsequences: false).joined(separator: argument)
        }
    }

    /// Every invented word, lowercase and without its colon.
    public static let words: [String: Invention] = Dictionary(uniqueKeysWithValues: [
        // Containment: "parent" and "ancestor" are :has, "inside" is :inside.
        unknown("parent-of", "A parent has it directly inside: :has(> …)."),
        unknown("child-of", "Directly inside it: … > *; at any depth: :inside(…).", holding: true),
        unknown("ancestor-of", "An ancestor has it inside, at any depth: :has(…)."),
        unknown("descendant-of", "Inside it, at any depth: :inside(…).", holding: true),
        unknown("in", "Inside it, at any depth: :inside(…).", holding: true),
        unknown("on-page", "Shapes inside a board's owner: … *.", holding: true),
        unknown("current-page", "The board the file's window shows: :current-board."),
        // Edges: data-canvas's old words, a design's that wasn't taken, and the language's own old
        // name for an edge either way, which is :connected-to, as people say it.
        unknown("source-of", "The result has an edge to it: :edge-to(…)."),
        unknown("target-of", "The result has an edge from it: :edge-from(…)."),
        unknown("connected-by", "An edge of that type, either way: :connected-to(*, …)."),
        unknown("edge-with", "An edge either way: :connected-to(…)."),
        unknown("neighbor-of", "An edge to or from it: :connected-to(…)."),
        unknown("reachable-from", "Reached from it by edges followed forward: :downstream-of(…)."),
        unknown("matches", "CSS's old name for :is: :is(…)."),
        ("minimized", Invention(reason: .unknownPseudoClass, message: ":minimized isn't a pseudo-class: shapes here aren't minimized.", write: nil)),
        // CSS with no meaning here.
        meaningless("root", "no shape is the file's root", "Shapes inside nothing, on the file's top board: :top-level."),
        meaningless("empty", "it could mean nothing inside or no text", "Nothing inside it: :not(:has(*)); no text: :not([text])."),
        unordered("first-child"), unordered("last-child"), unordered("only-child"),
        unordered("first-of-type"), unordered("last-of-type"), unordered("only-of-type"),
        unordered("nth-child"), unordered("nth-last-child"), unordered("nth-of-type"), unordered("nth-last-of-type"),
        unordered("nth-col"), unordered("nth-last-col"),
        meaningless("hover", "a query doesn't see the pointer"),
        meaningless("focus", "a query doesn't see the keyboard"),
        meaningless("active", "a query doesn't see the pointer"),
        // Where shapes sit: planned.
        spatial("within", "Inside it, at any depth: :inside(…).", holding: true),
        spatial("near"), spatial("left-of"), spatial("right-of"), spatial("above"), spatial("below"), spatial("overlaps"),
    ])

    /// The word's invention, if it's one; every `nth-` word is, as CSS's are.
    public static func invention(for word: String) -> Invention? {
        if let invention = words[word] { return invention }
        return word.hasPrefix("nth-") ? unordered(word).1 : nil
    }

    /// The refusal of a pseudo-class that's a known invention, where it is, its argument (canonical
    /// when it reads as shapes) put into the hint; nil for any other. A hint that puts shapes where
    /// a container goes waits for the caller's word that they can hold shapes (`HintPremise`): a
    /// word for being inside, given a rectangle, would be refused `cannot_contain`; given what isn't
    /// shapes (`:within(100px)`), it's the form alone, `…` in the argument's place.
    public static func error(for pseudo: PseudoClass) -> QueryError? {
        guard let invention = invention(for: pseudo.name) else { return nil }
        var argument: String?, shapes: SelectorList?
        if case .raw(let text, let span) = pseudo.argument {
            argument = Printer.raw(text, at: span)
            shapes = try? SelectorList.reading(raw: text, at: span.offset)
        }
        if invention.holding, let argument, !argument.isEmpty {
            guard let shapes else { return QueryError(invention.reason, invention.message, hint: invention.hint(argument: nil), span: pseudo.span) }
            let containers = shapes.selectors.compactMap(\.compounds.last)
            return QueryError(invention.reason, invention.message, premise: HintPremise(.holdShapes(containers), hint: invention.hint(argument: argument)),
                              span: pseudo.span)
        }
        return QueryError(invention.reason, invention.message, hint: invention.hint(argument: argument), span: pseudo.span)
    }

    private static func unknown(_ word: String, _ write: String, holding: Bool = false) -> (String, Invention) {
        (word, Invention(reason: .unknownPseudoClass, message: ":\(word) isn't a pseudo-class.", write: write, holding: holding))
    }

    private static func meaningless(_ word: String, _ why: String, _ write: String? = nil) -> (String, Invention) {
        (word, Invention(reason: .unsupported, message: ":\(word) has no meaning here: \(why).", write: write))
    }

    private static func unordered(_ word: String) -> (String, Invention) {
        meaningless(word, "shapes on a board have no order a query can count")
    }

    private static func spatial(_ word: String, _ write: String? = nil, holding: Bool = false) -> (String, Invention) {
        (word, Invention(reason: .notBuilt,
                         message: ":\(word) isn't in the language yet: where shapes sit on the canvas isn't something a query can ask.",
                         write: write, holding: holding))
    }
}
