import AppKit
import Palette
import Validation

/// What LanguageRules says and draws with: the Rules tab, the Issues tab's section, the menus and the light.
@MainActor
public enum RulesStyle {
    // MARK: The Rules tab

    /// The tab's title.
    public nonisolated static let tab = "Rules"
    /// The empty box last in the tab, where a rule is added.
    public static let addRule = "add rule"
    /// The one step a rule's edit is.
    public static let changeRules = "Change Rules"
    /// A rule's box, as VoiceOver names it: "Rule 1".
    static func rule(_ number: Int) -> String { "Rule \(number)" }
    /// A rule's walk, as VoiceOver hears the band: "Rule 1 of Vote".
    static func ruleOf(_ number: Int, type: String) -> String { "\(rule(number)) of \(type)" }
    /// An inherited rule's type: "from Car".
    static func from(_ type: String) -> String { "from \(type)" }
    /// A count, as VoiceOver hears it: "flags 5".
    static func flags(_ count: Int) -> String { "flags \(count)" }
    /// An inherited rule, as VoiceOver hears it.
    static func inherited(_ says: String, from type: String) -> String { "\(says), \(from(type))" }

    // MARK: The Issues tab

    /// The line's actions, and the steps they are.
    public static let ignore = "Ignore"
    public static let showRule = "Show Rule"
    public static let stopIgnoring = "Stop Ignoring"
    public static let ignoreRule = "Ignore Rule"
    public static let stopIgnoringRule = "Stop Ignoring Rule"
    /// The section's title, and its list's.
    static let rules = "Rules"
    static let shown = "Shown"
    /// What each rule's state says, at its right.
    static func word(_ state: RuleState) -> String {
        switch state {
        case .flags: "flags"
        case .holds: "holds"
        case .unsure: "unsure"
        case .ignored: "ignored"
        case .checking: "checking"
        }
    }
    /// A line of Shown for a shape that's gone since, and a type with no title.
    static let gone = "Deleted"
    static let untitled = "Untitled"
    /// A rule's chips: a bound query's shapes as the model is told them (their kind's name, plural: "notes"; "shapes"
    /// for a type of none yet), the step a chip's answer lands in, a container's line under its rule, the most rows a
    /// line lists, and the symbol of a shape that names none.
    static func plural(_ noun: String) -> String { noun + "s" }
    static let shapes = "shapes"
    static let interpret = "Interpret"
    static func inside(_ count: Int) -> String { "\(count) inside" }
    static let foundRows = 4
    static let shapeSymbol = "square"
    /// A chip in its box: the magnifier, on the light's cyan once it has a query, gray while its words are asked about,
    /// orange where they're no query; what VoiceOver hears as Tab selects it; and what its line lights by.
    static let chipSymbol = "magnifyingglass"
    /// A type's chip on the board, before how many rules it holds.
    static let rulesChip = "Rules"
    /// A chip's query typed by hand that couldn't be written (its type is locked, or the chip is gone).
    static let notWritten = "Not written: the type can’t change"
    static func chipFill(_ look: ChipLook) -> NSColor {
        switch look {
        case .found: foundFill
        case .asking: askingFill
        case .failed: failedFill
        }
    }
    // Each made once, so a chip's highlight is the same from one reading of the text to the next, and faded as it's
    // drawn, so it follows the appearance whichever was current as the highlight was made.
    private static let foundFill = IssueWalkStyle.light.fading(to: 0.2)
    private static let askingFill = NSColor.secondaryLabelColor.fading(to: 0.15)
    private static let failedFill = NSColor.systemOrange.fading(to: 0.25)
    static func chipSpoken(_ phrase: String) -> String { "Chip, \(phrase)" }
    /// The warning on a type whose chip's query the engine can't read.
    static func unreadableChip(_ phrase: String, _ why: String) -> String { "“\(phrase)” can’t be read: \(why)" }
    static let chipLight = "rule chip"
    /// The words a chip's query has of the shape checked, as its completions offer them.
    static let scopeWords: [(word: String, summary: String)] = [
        (":scope", "the shape checked"), (":scope-start", "where the arrow checked starts"), (":scope-end", "where the arrow checked ends"),
    ]
    static let retry = "Retry"
    static let openSettings = "Open Settings…"
    /// A rule's type, after its sentence.
    static let typeSymbol = "curlybraces"

    // MARK: The menus

    /// Ignore Rule ▸ in a checked shape's menu, and Select Flagged ▸ in a type's.
    static let ignoreRuleMenu = "Ignore Rule"
    static let selectFlagged = "Select Flagged"
    /// Walk Flagged ▸ beside it: the same rules and counts, a pick beginning the rule's walk.
    static let walkFlagged = "Walk Flagged"
    /// An item of Select Flagged ▸ and Walk Flagged ▸: the rule and its count.
    static func flaggedItem(_ says: String, count: Int) -> String { "\(cut(says)) (\(count))" }
    /// The command that asks again what failed.
    static let retryRules = "Retry Rules"
    /// A rule's sentence in a menu: cut to a line.
    static func cut(_ says: String) -> String {
        says.count <= menuLength ? says : String(says.prefix(menuLength - 1)) + "…"
    }
    static let menuLength = 60
}
