import Foundation

// QueryLanguage: the language `canvas query` reads, a CSS-like selector over a file's shapes.
//
// CSS where CSS has a meaning, with CSS's meaning: a compound is AND (`card[rank>3]:inside("A")`),
// a comma OR, a space "inside" and `>` "directly inside"; `:not`, `:is`, `:where` and `:has` as in
// Selectors 4, `[a]`, `[a=v]`, `^= $= *= ~= |=`, the `i` and `s` flags and `/* */` comments. A
// compound starts with at most one head: a kind (`card`), `*`, a title in quotes (as `draw` names
// shapes), a kind with a title right after it (`card"Payments"`, as CSS writes `div#id`) or an id
// (`#` and a UUID). What CSS has that the canvas has no counterpart for (siblings, columns,
// pseudo-elements, namespaces, `:nth-*`, nesting) is refused, never approximated.
//
// This module reads the text into a tree (`SelectorList(parsing:)`), prints it back in its
// canonical form (`canonical`), and says what's wrong with it (`QueryError`: a reason, a message, a
// hint and where; and a better hint that holds only if the kinds allow, `HintPremise`, for the caller
// to settle). It knows no canvas, registry, kind or plugin: kinds, attributes, titles, ids and
// edge types are left as written for the caller (Queries) to resolve, and a pseudo-class it doesn't
// know keeps its argument's text (`PseudoArgument.raw`), since a plugin may add the word. What it
// refuses is what's visible from the text alone: syntax, a stray space, the limits, CSS with no
// meaning here, and the language's own words given the wrong argument. `KnownInventions` holds
// what to write instead of the words people and models reach for, for the caller's refusals.
//
// Its own words are enums with raw values (`Word`, `Keyword`, `Operator`, `CaseFlag`), never free
// string literals, and none of them is a plugin's id.

/// How much a query may say. Constants read off the main actor, so they live on a nonisolated type.
public enum QueryLimits {
    /// Characters in a query (`too_long`).
    public static let characters = 8_192
    /// Levels of parentheses (`too_complex`).
    public static let depth = 32
    /// Compounds, in its arguments too (`too_complex`).
    public static let compounds = 256
    /// Errors reported at once (`QueryError.errors`).
    public static let errors = 20
    /// Characters in a quoted string, escapes undone (`too_long`).
    public static let stringCharacters = 1_024
}
