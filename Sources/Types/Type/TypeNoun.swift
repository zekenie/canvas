/// A type's name as a noun in a sentence: what the sections of its Rules tab are headed with ("Each sprint", "Inside each
/// sprint") and what the questions of its rules call a shape of it ("does this car meet them?"). Types'
/// own, for both of the plugins that say it (LanguageRules and Constraints' holder in `TypeConstraintsPlugin`).
public enum TypeNoun {
    /// A type's name as a noun: its first letter lower-case unless the name reads as an acronym or is written so ("PR",
    /// "iPhone"); a name that doesn't start with an upper-case letter as it is.
    public static func of(_ name: String) -> String {
        let letters = Array(name)
        guard let first = letters.first, first.isUppercase else { return name }
        if letters.count > 1, letters[1].isUppercase { return name }
        return first.lowercased() + String(letters.dropFirst())
    }
}
