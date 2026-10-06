import Foundation

// Prose maps: which words of a text in plain words say which part of a text in a lower language (a
// JSON Schema, code, a query, data), as a source map says which part of what a compiler wrote came
// from which part of the source. A map is a list of links, each the words as the prose writes them
// and an address in the target, and both ends are found by what they are in the texts as they are
// now, never by a position: words typed around a link keep it, a target laid out anew keeps it, and
// a link whose words or part are gone drops. The model says the links, in a call of its own once the
// target exists, whoever wrote it (`ProseMapService`), so the map checks what made the target rather
// than restating it; nothing is saved.

/// What prose is mapped into: a language whose text says something lower level than words do (a
/// JSON Schema, code, a query, data). A type with no value (an `enum` with no cases), whose static
/// members say how the model writes a place in such a text and how one is found in a text of it.
///
/// A target is a name and a guide: its addresses are then quotes of the target's text, each found
/// where it's written exactly once. A language with an address of its own (a JSON Pointer), which
/// survives the text being laid out anew, names it as `Address`, finds it (`locate`), and may say
/// what each one leads to (`role(of:)`). Conform in an extension, where the compiler flags a near
/// miss on a defaulted requirement.
public protocol ProseTarget {
    /// Where a part of the target is, as the model writes it (`description`, `init?(_:)`) and a
    /// link keeps it: by default the target's own words, quoted.
    associatedtype Address: Hashable & Sendable & LosslessStringConvertible = String
    /// The model's word for the target ("schema", "code", "query"), which tags its block in the
    /// request too (`<schema>`).
    static var name: String { get }
    /// What the model is told of this target beside what every target is told
    /// (`ProseMapPrompt.frame`): what it is, what an address looks like, what's worth linking and
    /// what isn't, and an example.
    static var guide: String { get }
    /// Where each address is in `target`, in order; nil for one that leads nowhere in it.
    static func locate(_ addresses: [Address], in target: String) -> [Range<String.Index>?]
    /// What words that lead there say of the target (`LinkRole`).
    static func role(of address: Address) -> LinkRole
}

/// What a link's words say of the target, one legend for every target, so a color means one thing
/// wherever words are mapped: something it has (a field, a function, a column), or a rule it keeps
/// (a bound, a condition, a filter).
public enum LinkRole: Hashable, Sendable {
    case element, rule
}

extension ProseTarget {
    public static func role(of address: Address) -> LinkRole { .element }
}

extension ProseTarget where Address == String {
    /// A quote of the target: where it's written, if it's written there exactly once
    /// (`ProseMapText.find`); one written twice or not at all leads nowhere, rather than to a
    /// place it may not mean.
    public static func locate(_ addresses: [String], in target: String) -> [Range<String.Index>?] {
        addresses.map { ProseMapText.find($0, in: target) }
    }
}
