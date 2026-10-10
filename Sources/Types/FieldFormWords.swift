// What the form says that rows do not: the back line, the waiting line, the menu of a line, the panel's
// JSON box, and the two rows a type's note shows for named pairs.

extension FieldWords {
    /// The line at the top of a level in a card, naming where it goes back to: `‹ shipping address`.
    public static func back(_ name: String) -> String { "‹ \(name)" }
    /// The waiting line of a list, a table and a pair's name.
    public static let addLine = "add"
    /// A line's right-click menu.
    public static let remove = "Remove"
    /// Under the panel's JSON box, when what is in it does not parse.
    public static let notJSON = "Not JSON"
    /// The two rows a type's note shows for named pairs.
    public static let pairName = "name"
    public static let pairValue = "value"
}
