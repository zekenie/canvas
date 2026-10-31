import Canvas

/// The rules a shape is not checked against, by their sentences: a rule a person ignores for this shape (Ignore), whose
/// warning goes and stays gone while the rule says the same thing. An ignore lapses when its sentence changes, since
/// the sentence is what's kept. Added to the kinds whose shapes rules check (`checkedByRules()`): the kinds that hold it
/// are the ones checked. LanguageRules' own, so no language lists it (`unlisted()`).
public enum IgnoredRulesProperty {}

extension IgnoredRulesProperty: ShapeProperty {
    public static let key: PropertyKey = "ignoredRules"
    public static var defaultValue: [String]? { nil }
    public static var keywords: PropertyKeywords<[String]> {
        PropertyKeywords().description("The rules of its types the shape is not checked against, by their sentences.").unlisted()
    }
    public static func isNone(_ value: [String]) -> Bool { value.isEmpty }
}

extension ShapeRegistrar {
    /// The kind's shapes are checked against the rules their types carry, in English, by the decision model: they hold
    /// the rules they ignore (`IgnoredRulesProperty`). A note's and an arrow's are.
    public mutating func checkedByRules() {
        optIn(to: IgnoredRulesProperty.self)
    }
}
