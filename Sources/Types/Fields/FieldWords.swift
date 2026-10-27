// Every string a row, a card or the panel's fields say, in one place: what each says stays one wording
// across the app. The kind words (`Text`, `2 fields`) are `FieldKind.typeLabel`'s.

public enum FieldWords {
    /// A row with nothing in it: `add gift note`, faint italic.
    public static func add(_ name: String) -> String { "add \(name)" }
    /// The rows' spot of a type with no fields.
    public static let noFields = "No fields"
    public static let notSignedIn = "Not signed in"
    public static let settings = "Settings…"
    public static let retry = "Retry"
    public static let other = "Other"
    /// What a row says of a field no control suits.
    public static let editedAsJSON = "edited as JSON in the panel"
    /// The fold of the rows past the first eight: `+12 more`.
    public static func more(_ count: Int) -> String { "+\(count) more" }
    /// The fold of the rows a type builds on: `from Person`.
    public static func from(_ type: String) -> String { "from \(type)" }
    /// The same when more than one type gave them: `from 2 types`.
    public static func fromTypes(_ count: Int) -> String { "from \(count) types" }
    /// `4 fields` (`1 field`).
    public static func fields(_ count: Int) -> String { count == 1 ? "1 field" : "\(count) fields" }
    /// `2 items` (`1 item`).
    public static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
    /// What the amber dot by a field's name says to VoiceOver: a value it needs is missing.
    public static let needed = "needed"
    /// A choice left empty, last in its menu.
    public static let none = "None"
}
