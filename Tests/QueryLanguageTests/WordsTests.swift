import QueryLanguage
import TestKit

/// A known invention's refusal of the query's last filter, if it's one.
private func refused(_ query: String) throws -> QueryError? {
    let filters = try parse(query).selectors[0].compounds[0].filters
    guard case .pseudo(let pseudo) = filters.last else { return nil }
    return KnownInventions.error(for: pseudo)
}

/// The shapes a refusal's better hint takes to hold shapes, as written canonically.
private func holding(_ error: QueryError?) -> [String]? {
    if case .holdShapes(let compounds)? = error?.premise?.claim { compounds.map(\.canonical) } else { nil }
}

@MainActor let wordsTests = Suite("Words", [
    test("the language's words, pinned: a new one changes the language") {
        expectEqual(Word.allCases.map(\.rawValue), [
            "not", "is", "where", "has", "inside", "top-level", "current-board",
            "edge-to", "edge-from", "connected-to", "downstream-of", "upstream-of", "component-of", "starts-at", "ends-at",
            "between", "dangling", "contains",
        ])
        expectEqual(Keyword.only.rawValue, "only")
        expectEqual(Operator.allCases.map(\.rawValue), ["=", "!=", "^=", "$=", "*=", "~=", "|=", "<", "<=", ">", ">="])
        expectEqual(CaseFlag.allCases.map(\.rawValue), ["i", "s"])
    },
    test("each word's signature") {
        let signatures: [Word: Word.Signature] = [
            .not: .selectors, .is: .selectors, .where: .selectors, .inside: .selectors, .has: .has,
            .topLevel: .none, .currentBoard: .none,
            .edgeTo: .anchor, .edgeFrom: .anchor, .connectedTo: .anchor, .downstreamOf: .anchor, .upstreamOf: .anchor, .componentOf: .anchor,
            .startsAt: .anchor, .endsAt: .anchor, .between: .twoAnchors, .dangling: .types(optional: true), .contains: .text,
        ]
        expectEqual(signatures.count, Word.allCases.count)
        for word in Word.allCases { expectEqual(word.signature, signatures[word], word.rawValue) }
    },
    test("every reason, pinned, as the command line reports them") {
        expectEqual(QueryError.Reason.allCases.map(\.rawValue), [
            "empty_query", "syntax", "stray_space", "too_long", "too_complex", "unsupported", "not_built",
            "unknown_kind", "unknown_attribute", "unknown_pseudo_class", "unknown_edge_type", "unknown_title", "unknown_id", "not_an_id",
            "invalid_value", "unsupported_operator", "bad_argument", "cannot_contain", "no_names", "no_topology", "too_slow", "cancelled",
            "board_closed",
        ])
    },
    test("the known inventions, pinned; none is one of the language's words") {
        expectEqual(KnownInventions.words.keys.sorted(), [
            "above", "active", "ancestor-of", "below", "child-of", "connected-by", "current-page", "descendant-of", "edge-with",
            "empty", "end-of", "first-child", "first-of-type", "focus", "hover", "in", "last-child", "last-of-type", "left-of", "matches",
            "minimized", "near", "neighbor-of", "nth-child", "nth-col", "nth-last-child", "nth-last-col", "nth-last-of-type", "nth-of-type", "on-page",
            "only-child", "only-of-type", "overlaps", "parent-of", "reachable-from", "right-of", "root", "source-of", "target-of", "within",
        ])
        for word in Word.allCases { expect(KnownInventions.invention(for: word.rawValue) == nil, word.rawValue) }
        expect(KnownInventions.invention(for: "nth-anything")?.reason == .unsupported, "every nth- word is CSS's")
        expect(KnownInventions.invention(for: "glows") == nil)
        let reasons = Set(KnownInventions.words.values.map(\.reason))
        expectEqual(reasons, [.unknownPseudoClass, .unsupported, .notBuilt])
    },
    test("an invention's refusal: where it is, and what to write, its argument put in; where a container goes, once it can hold shapes") {
        expectEqual(try refused(#"card:parent-of("B")"#),
                    QueryError(.unknownPseudoClass, ":parent-of isn't a pseudo-class.", hint: #"A parent has it directly on its board: :has(> "B")."#, span: at(4, 15)))
        expectEqual(try refused(":parent-of")?.hint, "A parent has it directly on its board: :has(> …).")
        let childOf = try require(try refused(":child-of( 'A' )"))
        expectEqual(childOf.hint, nil)
        expectEqual(childOf.premise?.hint, #"Directly on its board: "A" > *; at any depth: :inside("A")."#)
        expectEqual(holding(childOf), [#""A""#], "what the hint takes to hold shapes")
        expectEqual(try refused(#":ancestor-of("B")"#)?.hint, #"An ancestor has it inside, at any depth: :has("B")."#)
        expectEqual(try refused(#":descendant-of("A")"#)?.premise?.hint, #"Inside it, at any depth: :inside("A")."#)
        let within = try refused(#":in(card, "B" > box)"#)
        expectEqual(within?.premise?.hint, #"Inside it, at any depth: :inside(card, "B" > box)."#)
        expectEqual(holding(within), ["card", "box"], "each shape the argument names")
        expectEqual(try refused(":in")?.hint, "Inside it, at any depth: :inside(…).", "no argument: no query to offer")
        expectEqual(try refused(":in")?.premise, nil)
        // An argument that isn't shapes has nothing to put where a container goes: the form alone.
        let distance = try refused(":within(100px)")
        expectEqual(distance?.hint, "Inside it, at any depth: :inside(…).")
        expectEqual(distance?.premise, nil)
        expectEqual(try refused(#":source-of("A")"#)?.hint, #"The result has an edge to it: :edge-to("A")."#)
        expectEqual(try refused(#":target-of("A")"#)?.hint, #"The result has an edge from it: :edge-from("A")."#)
        expectEqual(try refused(":connected-by(wire)")?.hint, "An edge of that type, either way: :connected-to(*, wire).")
        expectEqual(try refused(#":neighbor-of("A")"#), QueryError(.unknownPseudoClass, ":neighbor-of isn't a pseudo-class.",
                                                                  hint: #"An edge to or from it: :connected-to("A")."#, span: at(0, 17)))
        expectEqual(try refused(":edge-with(card)")?.hint, "An edge either way: :connected-to(card).")
        expectEqual(try refused(#":on-page("Payments")"#)?.premise?.hint, #"Shapes inside a board's owner: "Payments" *."#)
        expectEqual(try refused(":current-page")?.hint, "The board the file's window shows: :current-board.")
        expectEqual(try refused(":root"), QueryError(.unsupported, ":root has no meaning here: no shape is the file's root.",
                                                     hint: "Shapes on the file's top board: :top-level.", span: at(0, 5)))
        expectEqual(try refused(":empty")?.hint, "Nothing inside it: :not(:has(*)); no text: :not([text]).")
        expectEqual(try refused(":first-child"), QueryError(.unsupported, ":first-child has no meaning here: shapes on a board have no order a query can count.",
                                                            span: at(0, 12)))
        expectEqual(try refused(":hover")?.message, ":hover has no meaning here: a query doesn't see the pointer.")
        expectEqual(try refused(#":near("A")"#),
                    QueryError(.notBuilt, ":near isn't in the language yet: where shapes sit on the canvas isn't something a query can ask.", span: at(0, 10)))
        expectEqual(try refused(#":within("A")"#)?.hint, nil, "a spatial word: :inside only where A holds a board")
        expectEqual(try refused(#":within("A")"#)?.premise?.hint, #"Inside it, at any depth: :inside("A")."#)
        expectEqual(try refused(":minimized"), QueryError(.unknownPseudoClass, ":minimized isn't a pseudo-class: shapes here aren't minimized.", span: at(0, 10)))
        expect(try refused(":glows") == nil, "a word nobody invented is the caller's to judge")
        expect(try refused(":not(card)") == nil)
    },
])
